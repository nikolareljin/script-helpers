#!/usr/bin/env bash
# SCRIPT: push_checks.sh
# DESCRIPTION: Sourced by the pre-push hook and the hook dispatcher: hygiene and lint of what a push changes; blocks on any finding.
# USAGE: source scripts/push_checks.sh; push_checks <refs-file> <remote-name> [<url>]
# PARAMETERS:
#   <refs-file>    The ref lines git gave pre-push, saved to a file.
#   <remote-name>  git's first pre-push argument.
#   <url>          git's second pre-push argument.
# EXAMPLE: push_checks "$refs" origin git@github.com:owner/repo.git
# ----------------------------------------------------
# Checks the content being pushed (each ref's tip), not the work tree, and only
# the files the push adds or changes. Every check runs to the end; a large push
# takes longer. Tests are not run here: `make test` or `./dev test`.
#
# Hygiene (always):
#   - conflict markers (<<<<<<< or >>>>>>> at the start of a line)
#   - files over script-helpers.max-file-mb (default 5) MB
#   - secret-looking file names (.env, *.pem, *.key, id_rsa, *.p12, ...)
#   - on release/X.Y.Z: the CHANGELOG release heading and VERSION match X.Y.Z
#   - in a repository of the configured owners (script-helpers.owners): commit
#     trailers or "Generated with" lines naming an AI tool
#     (git config script-helpers.ai-trailers allow turns that off for a repo)
# .script-helpers-push-allow (one glob per line, # comments) exempts paths from
# the name and size checks.
#
# Lint (each tool only when installed; a missing one is named, not fatal):
#   shell: bash -n, shellcheck -S warning      python: ruff (repo config, else
#   fatal rules only), or a syntax parse       js/ts: the repo's eslint, when
#   installed under node_modules               go: gofmt -l -e
#   rust: rustfmt --check, when the repo has a rustfmt config
#   workflows: actionlint   json, yaml: parse   powershell: pwsh parse
# A Makefile target `lint-changed` replaces all of it; it gets the changed
# files, one per line, in CHANGED_FILES.

PC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pc_say()  { printf '[pre-push] %s\n' "$*"; }
pc_find() { printf '[pre-push] REFUSED (%s): %s\n' "$1" "$2" >&2; PC_FINDINGS=$((PC_FINDINGS + 1)); }

# pc_python: a working Python 3, or return 1 (Windows has a python3 stub that
# only opens the store).
pc_python() {
  local p
  for p in python3 python; do
    command -v "$p" >/dev/null 2>&1 && ( cd / && "$p" -c 'import sys; sys.exit(sys.version_info[0] != 3)' ) 2>/dev/null \
      && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# pc_repo_code_ok: 0 when this file lives inside the repository being pushed,
# so the hook is the repository's own code already. An install outside it (the
# chained setup, the global dispatcher) never runs code the repository supplies:
# a `lint-changed` target, node_modules/.bin/eslint and its JS config.
# Inside is not enough: a repository whose work tree is $HOME contains the
# installed copy too. This file must be tracked, by the repository or by a
# submodule of it (script-helpers vendored).
pc_repo_code_ok() {
  local top own super
  top="$(pwd -P)"
  case "$(cd "$PC_DIR" && pwd -P)/" in "$top"/*) ;; *) return 1 ;; esac
  git -C "$PC_DIR" ls-files --error-unmatch -- push_checks.sh >/dev/null 2>&1 || return 1
  own="$(cd "$(git -C "$PC_DIR" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  [[ "$own" == "$top" ]] && return 0
  super="$(git -C "$own" rev-parse --show-superproject-working-tree 2>/dev/null)"
  [[ -n "$super" && "$(cd "$super" && pwd -P)" == "$top" ]]
}

# pc_abs <path>: the path from /, for tools run outside the repository.
pc_abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd -P)" "$1" ;; esac; }

# pc_allowed <path>: 0 when .script-helpers-push-allow (at the pushed tip) lists it.
pc_allowed() {
  local pat
  [[ -s "$PC_TMP/allow" ]] || return 1
  while IFS= read -r pat; do
    pat="${pat%%#*}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -n "$pat" ]] || continue
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ "$1" == $pat || "${1##*/}" == $pat ]] && return 0
  done < "$PC_TMP/allow"
  return 1
}

# pc_prepare <refs> <remote>: $PC_TMP/files, one "<tip><TAB><path><TAB><check-path>"
# per changed blob. <check-path> is the file in the work tree when it holds the
# pushed content, else a copy under $PC_TMP/t/<tip>/.
pc_prepare() {
  local head tip path dest size type
  head="$(git rev-parse -q --verify HEAD 2>/dev/null || true)"
  git diff --no-ext-diff --name-only -z HEAD 2>/dev/null | tr '\0' '\n' > "$PC_TMP/dirty" || true
  sec_changed_files "$1" "${2:-}" > "$PC_TMP/changed"
  : > "$PC_TMP/files"; : > "$PC_TMP/sizes"
  [[ -s "$PC_TMP/changed" ]] || return 0
  sed "s/$(printf '\t')/:/" "$PC_TMP/changed" | git cat-file --batch-check='%(objectsize) %(objecttype)' > "$PC_TMP/types" 2>/dev/null
  while IFS=$'\t' read -r tip path && IFS=' ' read -r size type <&3; do
    [[ "$type" == blob ]] || continue      # a submodule commit has no content here
    # A crafted tree can name ../ or an absolute path; never write outside $PC_TMP.
    case "/$path/" in */../*|*/./*|//*) continue ;; esac
    if [[ "$tip" == "$head" && -f "$path" ]] && ! LC_ALL=C grep -qxF -- "$path" "$PC_TMP/dirty"; then
      dest="$path"
    else
      dest="$PC_TMP/t/$tip/$path"
      mkdir -p "$(dirname "$dest")" && git cat-file blob "$tip:$path" > "$dest" 2>/dev/null || continue
    fi
    printf '%s\t%s\t%s\n' "$tip" "$path" "$dest" >> "$PC_TMP/files"
    printf '%s\t%s\n' "$size" "$path" >> "$PC_TMP/sizes"
  done < "$PC_TMP/changed" 3< "$PC_TMP/types"
  # Extracted copies get the repository's lint configs, so they lint as in place.
  for tip in $(cut -f1 "$PC_TMP/files" | LC_ALL=C sort -u); do
    [[ -d "$PC_TMP/t/$tip" ]] || continue
    for path in .shellcheckrc pyproject.toml ruff.toml .ruff.toml rustfmt.toml .rustfmt.toml; do
      git cat-file -e "$tip:$path" 2>/dev/null && [[ ! -e "$PC_TMP/t/$tip/$path" ]] \
        && git cat-file blob "$tip:$path" > "$PC_TMP/t/$tip/$path" 2>/dev/null
    done
  done
  return 0
}

# pc_show <text>: tool output with the copies' directory removed from paths.
pc_show() { printf '%s\n' "$1" | sed -e "s|$PC_TMP/t/[0-9a-f]*/||g" -e "s|$(pwd -P)/||g" -e '/^[[:space:]]*$/d'; }

# --------------------------------------------------------------- hygiene
pc_hygiene() {
  local refs="$1" remote="${2:-}" url="${3:-}" max_mb max tip path dest size hits lref lsha rref rsha v top revs out
  max_mb="$(git config --get script-helpers.max-file-mb 2>/dev/null || true)"
  [[ "$max_mb" =~ ^[0-9]+$ ]] || max_mb=5
  max=$((max_mb * 1024 * 1024))
  while IFS=$'\t' read -r size path; do
    pc_allowed "$path" && continue
    [[ "$size" -gt "$max" ]] && pc_find hygiene "$path is $((size / 1024 / 1024)) MB, over $max_mb MB (git config script-helpers.max-file-mb, or list it in .script-helpers-push-allow)"
  done < "$PC_TMP/sizes"
  while IFS=$'\t' read -r tip path dest; do
    if ! pc_allowed "$path"; then
      case "${path##*/}" in
        .env.example|.env.sample|.env.template|.env.dist|*.pub) ;;
        .env|.env.*|*.pem|*.key|id_rsa|id_rsa.*|id_dsa|id_ecdsa|id_ecdsa.*|id_ed25519|id_ed25519.*|*.p12|*.pfx|*.jks|*.keystore)
          pc_find hygiene "$path looks like a secret file (list it in .script-helpers-push-allow if it is not)" ;;
      esac
    fi
    hits="$(LC_ALL=C grep -I -n -E '^(<{7}|>{7})( |$)' -- "$dest" 2>/dev/null | head -3 | cut -d: -f1 | tr '\n' ' ' || true)"
    [[ -n "$hits" ]] && pc_find hygiene "$path has merge conflict markers (line ${hits% })"
  done < "$PC_TMP/files"

  # Commit messages: AI attribution, in the owners' repositories only.
  if pc_ai_scope "$url"; then
    while IFS= read -r revs; do
      # shellcheck disable=SC2086
      git log --format='%h %B' $revs 2>/dev/null | awk '
        /^[0-9a-f]+ / && NF { c = $1 }
        { l = tolower($0) }
        l ~ /(co-authored-by|signed-off-by):.*(claude|anthropic|copilot|chatgpt|openai|gemini|cursor|codex)/ ||
        l ~ /generated (with|by).*(claude|copilot|chatgpt|gemini|cursor|codex)/ { print c }' | LC_ALL=C sort -u
    done < <(sec_revs "$refs" "$remote") | while IFS= read -r v; do
      printf '%s\n' "$v"
    done > "$PC_TMP/ai"
    while IFS= read -r v; do
      pc_find hygiene "commit $v names an AI tool in a trailer or a \"Generated with\" line (git commit --amend, or git rebase to reword it)"
    done < "$PC_TMP/ai"
  fi

  # release/X.Y.Z: the release heading and VERSION at the pushed tip.
  # shellcheck disable=SC2034
  while read -r lref lsha rref rsha; do
    [[ -n "${lsha:-}" && ! "$lsha" =~ ^0+$ ]] || continue
    v="${rref#refs/heads/release/}"
    [[ "$v" != "$rref" && "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    # Only where the repository keeps dated release headings ("## YYYY-MM-DD ...");
    # another changelog style is not this check's to judge.
    mkdir -p "$PC_TMP/rel" && git cat-file blob "$lsha:CHANGELOG.md" > "$PC_TMP/rel/CHANGELOG.md" 2>/dev/null || continue
    grep -qE '^##[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]' "$PC_TMP/rel/CHANGELOG.md" || continue
    if [[ -f "$PC_DIR/../lib/changelog.sh" ]]; then
      out="$( cd "$PC_DIR/.." && source ./lib/logging.sh 2>/dev/null && source ./lib/changelog.sh && changelog_check_header "$PC_TMP/rel/CHANGELOG.md" 2>&1 )" \
        || pc_find hygiene "release/$v CHANGELOG heading: $(printf '%s' "$out" | tr -d '\033' | sed 's/\[[0-9;]*m//g' | tr '\n' ' ')"
    fi
    top="$(grep -m1 -E '^##[[:space:]]+[0-9]{4}-' "$PC_TMP/rel/CHANGELOG.md" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    [[ "$top" == "$v" ]] || pc_find hygiene "release/$v: the newest CHANGELOG release is '${top:-none}', not $v"
    if git cat-file -e "$lsha:VERSION" 2>/dev/null; then
      top="$(git cat-file blob "$lsha:VERSION" | tr -d '[:space:]' | sed 's/^v//')"
      [[ "$top" == "$v" ]] || pc_find hygiene "release/$v: VERSION says '$top'"
    fi
  done < "$refs"
}

# pc_ai_scope <url>: 0 when the AI-trailer check applies: a repository of the
# configured owners, not turned off with script-helpers.ai-trailers allow.
pc_ai_scope() {
  local owners urls=() u
  [[ "$(git config --get script-helpers.ai-trailers 2>/dev/null || true)" == allow ]] && return 1
  declare -F scope_in_scope >/dev/null || { [[ -f "$PC_DIR/owner_scope.sh" ]] && source "$PC_DIR/owner_scope.sh"; } || return 1
  owners="$(scope_owners 2>/dev/null)" && [[ -n "$owners" ]] || return 1
  [[ -n "${1:-}" ]] && urls+=("$1")
  while IFS= read -r u; do [[ -n "$u" ]] && urls+=("$u"); done < <(scope_repo_urls 2>/dev/null || true)
  scope_in_scope "$owners" "${urls[@]+"${urls[@]}"}"
}

# ------------------------------------------------------------------ lint
pc_missing() { pc_say "lint: $1 not installed; $2 not checked."; }

pc_lint() {
  local tip path dest py out f mk="" sh=() pyf=() js=() gof=() rs=() wf=() json=() yml=() ps=() extracted=0
  for f in Makefile makefile GNUmakefile; do [[ -f "$f" ]] && { mk="$f"; break; }; done
  if [[ -n "$mk" ]] && grep -qE '^lint-changed[[:space:]]*:' "$mk"; then
    if ! pc_repo_code_ok; then
      pc_say "lint: make lint-changed not run: this hook is installed outside the repository, and runs none of its code."
    else
    pc_say "lint: make lint-changed"
    CHANGED_FILES="$(cut -f2 "$PC_TMP/files")" make lint-changed >&2 \
      || pc_find lint "make lint-changed failed"
    return 0
    fi
  fi
  while IFS=$'\t' read -r tip path dest; do
    [[ "$dest" == "$PC_TMP"/* ]] && extracted=1
    case "$path" in
      .github/workflows/*.yml|.github/workflows/*.yaml) wf+=("$dest"); yml+=("$dest") ;;
      *.sh|*.bash) sh+=("$dest") ;;
      *.py) pyf+=("$dest") ;;
      *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs) [[ "$dest" == "$path" ]] && js+=("$dest") ;;
      *.go) gof+=("$dest") ;;
      *.rs) rs+=("$dest") ;;
      *.jsonc|tsconfig*.json|jsconfig*.json|*/tsconfig*.json|*/jsconfig*.json|.vscode/*|*/.vscode/*|*devcontainer.json|.eslintrc.json|*/.eslintrc.json|tslint.json) ;;
      *.json) json+=("$dest") ;;
      *.yml|*.yaml) yml+=("$dest") ;;
      *.ps1|*.psm1) ps+=("$dest") ;;
      */*.*|*.*) ;;
      *) head -n1 "$dest" 2>/dev/null | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)' && sh+=("$dest") ;;
    esac
  done < "$PC_TMP/files"

  if [[ ${#sh[@]} -gt 0 ]]; then
    for f in "${sh[@]}"; do
      out="$(bash -n "$f" 2>&1)" || pc_find lint "$(pc_show "$out")"
    done
    if command -v shellcheck >/dev/null 2>&1; then
      out="$(shellcheck -S warning -- "${sh[@]}" 2>&1)" || pc_find lint "shellcheck:
$(pc_show "$out")"
    else
      pc_missing shellcheck "${#sh[@]} shell file(s)"
    fi
  fi

  if [[ ${#pyf[@]} -gt 0 ]]; then
    if command -v ruff >/dev/null 2>&1; then
      local sel=()
      [[ -f pyproject.toml ]] && grep -q '^\[tool\.ruff' pyproject.toml || [[ -f ruff.toml || -f .ruff.toml ]] \
        || sel=(--select 'E9,F63,F7,F82')
      out="$(ruff check --quiet --no-cache --force-exclude "${sel[@]+"${sel[@]}"}" -- "${pyf[@]}" 2>&1)" || pc_find lint "ruff:
$(pc_show "$out")"
    elif py="$(pc_python)"; then
      for f in "${!pyf[@]}"; do pyf[$f]="$(pc_abs "${pyf[$f]}")"; done
      out="$(cd "$PC_TMP" && "$py" - "${pyf[@]}" 2>&1 <<'PY'
import ast, sys
bad = 0
for f in sys.argv[1:]:
    try:
        ast.parse(open(f, 'rb').read(), f)
    except SyntaxError as e:
        print("%s:%s: %s" % (f, e.lineno, e.msg)); bad = 1
sys.exit(bad)
PY
)" || pc_find lint "python syntax:
$(pc_show "$out")"
    else
      pc_missing "ruff or python" "${#pyf[@]} python file(s)"
    fi
  fi

  if [[ ${#js[@]} -gt 0 ]]; then
    local has_cfg=false
    for f in eslint.config.* .eslintrc*; do [[ -e "$f" ]] && { has_cfg=true; break; }; done
    if [[ -x node_modules/.bin/eslint && "$has_cfg" == true ]] && ! pc_repo_code_ok; then
      pc_say "lint: eslint not run: it and its config are the repository's code, and this hook is installed outside it."
    elif [[ -x node_modules/.bin/eslint && "$has_cfg" == true ]]; then
      out="$(node_modules/.bin/eslint -- "${js[@]}" 2>&1)" || pc_find lint "eslint:
$(pc_show "$out")"
    fi
  fi
  [[ "$extracted" == 1 ]] && grep -qE '\.(js|jsx|ts|tsx|mjs|cjs)$' <(cut -f2 "$PC_TMP/files") \
    && pc_say "lint: eslint runs only on the checked-out branch's files."

  if [[ ${#gof[@]} -gt 0 ]]; then
    if command -v gofmt >/dev/null 2>&1; then
      out="$(gofmt -l -e -- "${gof[@]}" 2>&1)"
      [[ -z "$out" ]] || pc_find lint "gofmt (run gofmt -w):
$(pc_show "$out")"
    else
      pc_missing gofmt "${#gof[@]} go file(s)"
    fi
  fi

  if [[ ${#rs[@]} -gt 0 && ( -f rustfmt.toml || -f .rustfmt.toml ) ]]; then
    if command -v rustfmt >/dev/null 2>&1; then
      out="$(rustfmt --check -- "${rs[@]}" 2>&1)" || pc_find lint "rustfmt --check:
$(pc_show "$out")"
    else
      pc_missing rustfmt "${#rs[@]} rust file(s)"
    fi
  fi

  if [[ ${#wf[@]} -gt 0 ]]; then
    if command -v actionlint >/dev/null 2>&1; then
      out="$(actionlint -no-color -- "${wf[@]}" 2>&1)" || pc_find lint "actionlint:
$(pc_show "$out")"
    else
      pc_missing actionlint "${#wf[@]} workflow file(s)"
    fi
  fi

  if [[ ${#json[@]} -gt 0 || ${#yml[@]} -gt 0 ]] && py="$(pc_python)"; then
    for f in "${!json[@]}"; do json[$f]="$(pc_abs "${json[$f]}")"; done
    for f in "${!yml[@]}"; do yml[$f]="$(pc_abs "${yml[$f]}")"; done
    if [[ ${#json[@]} -gt 0 ]]; then
      out="$(cd "$PC_TMP" && "$py" - "${json[@]}" 2>&1 <<'PY'
import json, sys
bad = 0
for f in sys.argv[1:]:
    try:
        json.load(open(f, encoding='utf-8-sig'))
    except Exception as e:
        print("%s: %s" % (f, e)); bad = 1
sys.exit(bad)
PY
)" || pc_find lint "json:
$(pc_show "$out")"
    fi
    if [[ ${#yml[@]} -gt 0 ]]; then
      out="$(cd "$PC_TMP" && "$py" - "${yml[@]}" 2>&1 <<'PY'
import re, sys
try:
    import yaml
except ImportError:
    sys.exit(0)
class L(yaml.SafeLoader):
    pass
# Custom tags (!Ref, !reference) are valid YAML; only the structure is checked.
L.add_multi_constructor('', lambda loader, suffix, node: None)
bad = 0
for f in sys.argv[1:]:
    text = open(f, encoding='utf-8-sig').read()
    if re.search(r'(?<!\$)\{\{|\{%', text):
        continue   # a template (Helm, Jinja), not YAML until rendered; ${{ }} is not one
    try:
        list(yaml.load_all(text, Loader=L))
    except yaml.YAMLError as e:
        print("%s: %s" % (f, str(e).replace('\n', ' '))); bad = 1
sys.exit(bad)
PY
)" || pc_find lint "yaml:
$(pc_show "$out")"
    fi
  fi

  if [[ ${#ps[@]} -gt 0 ]] && command -v pwsh >/dev/null 2>&1; then
    for f in "${ps[@]}"; do
      out="$(pwsh -NoProfile -NonInteractive -Command '$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$t,[ref]$e); $e | ForEach-Object { "{0}:{1}: {2}" -f $args[0],$_.Extent.StartLineNumber,$_.Message }; exit [int]($e.Count -gt 0)' "$f" 2>&1)" \
        || pc_find lint "powershell:
$(pc_show "$out")"
    done
  fi
  return 0
}

# push_checks <refs-file> <remote-name> [<url>]: 0 = clean, 1 = refused.
push_checks() {
  local refs="$1" remote="${2:-}" url="${3:-}" t0 tip
  PC_FINDINGS=0
  declare -F sec_changed_files >/dev/null || source "$PC_DIR/security_hooks.sh" || return 1
  PC_TMP="$(mktemp -d 2>/dev/null)" && [[ -n "$PC_TMP" && -d "$PC_TMP" && ! -L "$PC_TMP" ]] || {
    echo "[pre-push] could not create a private temp directory; refused." >&2; return 1; }
  chmod 700 "$PC_TMP" 2>/dev/null || true
  t0=$SECONDS
  pc_prepare "$refs" "$remote"
  : > "$PC_TMP/allow"
  for tip in $(cut -f1 "$PC_TMP/files" | LC_ALL=C sort -u); do
    git cat-file blob "$tip:.script-helpers-push-allow" >> "$PC_TMP/allow" 2>/dev/null || true
  done
  pc_hygiene "$refs" "$remote" "$url"
  pc_say "hygiene: $(wc -l < "$PC_TMP/files" | tr -d ' ') changed file(s) checked ($((SECONDS - t0)) s)"
  t0=$SECONDS
  pc_lint
  pc_say "lint: done ($((SECONDS - t0)) s)"
  rm -rf "$PC_TMP"
  if [[ "$PC_FINDINGS" -gt 0 ]]; then
    echo "[pre-push] push refused: $PC_FINDINGS finding(s) above. Fix them, commit, and push again." >&2
    return 1
  fi
  return 0
}
