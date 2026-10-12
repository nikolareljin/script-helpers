#!/usr/bin/env bash
# SCRIPT: setup-hooks.sh
# DESCRIPTION: Configure git to use shared or repository-local hook scripts, and install the Claude Code security hook.
# USAGE: bash scripts/setup-hooks.sh [--global|--claude|--all|--managed] [--uninstall] | --status | --doctor | --install-gitleaks
# PARAMETERS:
#   (none)        Point this repository's core.hooksPath at the shared hooks.
#   --global      Install the git hooks machine-wide: copy them, with their own copy of
#                 the check scripts, to <data>/script-helpers/git-hooks and set the
#                 GLOBAL core.hooksPath there, after printing the old value and saving it.
#   --claude      Install the Claude Code PreToolUse hook for this user: copy it to
#                 <data>/script-helpers/claude-hooks and add one entry to
#                 ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json (matcher Bash, timeout
#                 60 s, shell bash). Every other key and hook in the file is kept; an
#                 older entry for the same hook is replaced; a backup is written first.
#   --all         --global and --claude.
#   --managed     Install the Claude hook into the OS managed settings file instead,
#                 which no user or project setting can turn off. Needs admin rights;
#                 refuses (exit 2) without write access, and never runs sudo itself.
#                   Linux    /etc/claude-code/managed-settings.json
#                   macOS    /Library/Application Support/ClaudeCode/managed-settings.json
#                   Windows  C:\Program Files\ClaudeCode\managed-settings.json
#                 The hook copy goes to script-helpers/ next to that file.
#   --uninstall   With --global, --claude, --all or --managed: undo that install.
#                 Other settings and hooks are left as they are.
#   --status      Show what is installed, and the prerequisites.
#   --doctor      The prerequisites, then two probes through the installed Claude
#                 hook: a known-bad command (must exit 2) and a harmless one (must
#                 exit 0), with the time each took. Exit 1 when a probe fails.
#   --install-gitleaks  Download the pinned gitleaks (SHA-256 checked) into the cache.
#   <data> is %LOCALAPPDATA% on Windows (Git Bash), else ${XDG_DATA_HOME:-~/.local/share}.
#   Installing refuses (exit 2) until owners are configured:
#     git config --global script-helpers.owners <user-or-org>[,<another>]
#   Only those owners' github.com repositories are checked; every other repository
#   runs only its own hooks. See docs/security-gates.md.
#   Hook directory priority (no option):
#     1. .githooks/  (repo-local overrides with both pre-commit and pre-push)
#     2. git-hooks/ next to this script: the hooks bundled with this copy of
#        script-helpers, wherever it is vendored (scripts/script-helpers,
#        vendor/script-helpers, ...) or script-helpers' own scripts/git-hooks
#     3. scripts/script-helpers/scripts/git-hooks/, then scripts/git-hooks/
#   The shared pre-push hands over to .githooks/pre-push when a repository has
#   one (for example the protected-refs guard), so a repository with only
#   .githooks/pre-push gets the shared hooks and still runs its own.
# EXIT_CODES:
#   0 done; 1 failed (or a --doctor probe failed); 2 refused (no owners, no
#   Python 3, no write access, bad arguments); 3 settings.json is not valid JSON
# ----------------------------------------------------
# After running, hooks are active for all subsequent git operations in this repo.
set -euo pipefail

GLOBAL=false; CLAUDE=false; MANAGED=false; UNINSTALL=false; STATUS=false; DOCTOR=false; GITLEAKS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --global) GLOBAL=true ;;
    --claude) CLAUDE=true ;;
    --all) GLOBAL=true; CLAUDE=true ;;
    --managed) MANAGED=true ;;
    --uninstall) UNINSTALL=true ;;
    --status) STATUS=true ;;
    --doctor) DOCTOR=true ;;
    --install-gitleaks) GITLEAKS=true ;;
    -h|--help) sed -n '2,/^# ------/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[setup-hooks] unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ "$UNINSTALL" == true && "$GLOBAL" != true && "$CLAUDE" != true && "$MANAGED" != true ]]; then
  echo "[setup-hooks] --uninstall goes with --global, --claude, --all or --managed" >&2; exit 2
fi
if [[ "$MANAGED" == true && "$CLAUDE" == true ]]; then
  echo "[setup-hooks] --managed is an alternative to --claude/--all, not an addition" >&2; exit 2
fi

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"    # this script-helpers copy

ON_WINDOWS=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=true ;; esac

# unix_path <path>: a Windows path (C:\x) as Git Bash sees it; others unchanged.
unix_path() {
  if [[ "$ON_WINDOWS" == true ]] && command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}
# native_path <path>: the form a Windows program reads (C:/x); others unchanged.
native_path() {
  if [[ "$ON_WINDOWS" == true ]] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

if [[ "$ON_WINDOWS" == true && -n "${LOCALAPPDATA:-}" ]]; then
  data_base="$(unix_path "$LOCALAPPDATA")"
else
  data_base="${XDG_DATA_HOME:-${HOME:-}/.local/share}"
fi
global_dir="${SCRIPT_HELPERS_HOOKS_HOME:-$data_base/script-helpers/git-hooks}"
global_hooks="$(native_path "$global_dir/hooks")"   # as git stores it (C:/... on Windows)
backup_file="$global_dir/previous-hooksPath"
claude_settings="$(unix_path "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}")/settings.json"
claude_home="$data_base/script-helpers/claude-hooks"
if [[ -n "${SCRIPT_HELPERS_MANAGED_SETTINGS:-}" ]]; then
  managed_settings="$(unix_path "$SCRIPT_HELPERS_MANAGED_SETTINGS")"
else
  case "$(uname -s)" in
    Darwin) managed_settings="/Library/Application Support/ClaudeCode/managed-settings.json" ;;
    MINGW*|MSYS*|CYGWIN*) managed_settings="$(unix_path 'C:\Program Files\ClaudeCode')/managed-settings.json" ;;
    *) managed_settings="/etc/claude-code/managed-settings.json" ;;
  esac
fi
managed_home="$(dirname "$managed_settings")/script-helpers"
HOOK_REL="scripts/claude-hooks/pretooluse_private_names.sh"
MERGE_REL="scripts/claude-hooks/merge_settings.py"
# Every hook git runs from core.hooksPath: with a global hooksPath set, git no
# longer reads .git/hooks, so each one needs a wrapper that chains to it.
GLOBAL_HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite push-to-checkout pre-auto-gc sendemail-validate reference-transaction post-index-change"

configured_owners() {
  printf '%s' "${SCRIPT_HELPERS_OWNERS:-$(git config --global --get script-helpers.owners 2>/dev/null || true)}"
}

require_owners() {
  if [[ -z "$(configured_owners)" ]]; then
    echo "[setup-hooks] ERROR: no owners configured, so the hooks would check nothing." >&2
    echo "[setup-hooks] Set your GitHub user or org first, then run this again:" >&2
    echo "[setup-hooks]   git config --global script-helpers.owners <user-or-org>[,<another>]" >&2
    exit 2
  fi
}

# python3, else a "python" that is 3.x (Windows names it python.exe; its
# "python3" may be a store stub that does not run).
PY=""
for _c in python3 python; do
  if command -v "$_c" >/dev/null 2>&1 && "$_c" -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
    PY="$_c"; break
  fi
done

version_stamp() {
  printf '%s %s\n' "$(git -C "$src_root" describe --tags --always 2>/dev/null || cat "$src_root/VERSION" 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%d)"
}

# stage_and_swap <dest> <stage>: move the staged scripts/, lib/, hooks/ (when
# present), helpers.sh and VERSION into <dest>. Stage, then swap: a half-copied
# install must never be what runs.
stage_and_swap() {
  local dest="$1" stage="$2" name
  rm -rf "$dest/scripts.old" "$dest/hooks.old" "$dest/lib.old"
  for name in scripts hooks lib; do
    [[ -e "$stage/$name" ]] || continue
    [[ -e "$dest/$name" ]] && mv "$dest/$name" "$dest/$name.old"
    mv "$stage/$name" "$dest/$name"
  done
  mv -f "$stage/helpers.sh" "$dest/helpers.sh"; mv -f "$stage/VERSION" "$dest/VERSION"
  rm -rf "$stage" "$dest/scripts.old" "$dest/hooks.old" "$dest/lib.old"
}

# stage_common <dest>: a new stage directory with helpers.sh, lib/ and the check
# scripts every hook runs. Prints its path.
stage_common() {
  local stage name
  mkdir -p "$1" || return 1
  stage="$(mktemp -d "$1/.stage.XXXXXX")" || return 1
  mkdir -p "$stage/scripts" || return 1
  cp "$src_root/helpers.sh" "$stage/" && cp -R "$src_root/lib" "$stage/lib" || { rm -rf "$stage"; return 1; }
  for name in owner_scope.sh check_sensitive.sh check_private_names.sh refresh_private_names.sh; do
    cp "$src_root/scripts/$name" "$stage/scripts/$name" || { rm -rf "$stage"; return 1; }
  done
  version_stamp > "$stage/VERSION"
  printf '%s\n' "$stage"
}

gitleaks_found() {
  command -v gitleaks >/dev/null 2>&1 && return 0
  ( # shellcheck source=/dev/null
    source "$src_root/helpers.sh" && shlib_import logging foxguard gitleaks >/dev/null 2>&1 && gitleaks_bin >/dev/null 2>&1 )
}

install_gitleaks() {
  # shellcheck source=/dev/null
  ( source "$src_root/helpers.sh" && shlib_import logging foxguard gitleaks && gitleaks_install )
}

# offer_gitleaks: asked on a terminal, printed otherwise; never installed silently.
offer_gitleaks() {
  local answer=""
  gitleaks_found && return 0
  echo "[setup-hooks] gitleaks is missing. Without it the hook refuses publishing commands in your repositories."
  if [[ -t 0 && -t 1 ]]; then
    printf '[setup-hooks] Install the pinned gitleaks now (download, SHA-256 checked)? [y/N] '
    read -r answer || answer=""
  fi
  case "$answer" in
    y|Y|yes) install_gitleaks || echo "[setup-hooks] gitleaks install failed; see above." >&2 ;;
    *) echo "[setup-hooks] To install it later: bash $src_root/scripts/setup-hooks.sh --install-gitleaks" ;;
  esac
}

file_age_days() {  # <date YYYY-MM-DD>: days since then, or nothing
  [[ -n "$PY" ]] || return 0
  "$PY" -c 'import datetime,sys
try:
    d = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d").date()
    print((datetime.date.today() - d).days)
except ValueError:
    pass' "$1" 2>/dev/null || true
}

# prereqs: one line per prerequisite. Returns the number of missing required ones.
prereqs() {
  local missing=0 list terms stamp age perms owners
  echo "[setup-hooks] prerequisites:"
  printf '  bash      ok (%s)\n' "${BASH_VERSION:-?}"
  if [[ -n "$PY" ]]; then
    printf '  python    ok (%s: %s)\n' "$PY" "$("$PY" --version 2>&1)"
  else
    echo "  python    MISSING: install Python 3 (python3, or python on Windows)"; missing=$((missing+1))
  fi
  if command -v git >/dev/null 2>&1; then
    printf '  git       ok (%s)\n' "$(git --version 2>/dev/null)"
  else
    echo "  git       MISSING: install git"; missing=$((missing+1))
  fi
  if gitleaks_found; then
    echo "  gitleaks  ok"
  else
    echo "  gitleaks  missing: publishing commands in your repositories are refused until it is installed;"
    echo "            bash $src_root/scripts/setup-hooks.sh --install-gitleaks"
  fi
  owners="$(configured_owners)"
  if [[ -n "$owners" ]]; then
    echo "  owners    ok ($owners)"
  else
    echo "  owners    MISSING: git config --global script-helpers.owners <user-or-org>"; missing=$((missing+1))
  fi
  list="${PRIVATE_NAMES_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names.tsv}"
  if [[ -s "$list" ]]; then
    stamp="$(sed -n 's/^# generated: \([0-9-]*\).*/\1/p' "$list" | head -1)"
    age="$(file_age_days "$stamp")"
    echo "  names     ok ($list, generated ${stamp:-at an unknown date}${age:+, $age days ago})"
  else
    echo "  names     not found ($list): private repository names are not checked; see refresh_private_names.sh"
  fi
  terms="${SENSITIVE_TERMS_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/sensitive-terms.txt}"
  if [[ -f "$terms" ]]; then
    perms="$(ls -ld "$terms" | cut -c5-10)"
    if [[ "$perms" == "------" ]]; then
      echo "  terms     ok ($terms, readable by you only)"
    else
      echo "  terms     WARN: $terms is readable by others; chmod 600 it"
    fi
  else
    echo "  terms     none ($terms): only built-in patterns are checked"
  fi
  return "$missing"
}

show_global_status() {
  local cur local_path
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  echo "[setup-hooks] global core.hooksPath: ${cur:-(unset)}"
  if [[ -n "$cur" && "$cur" == "$global_hooks" ]]; then
    echo "[setup-hooks] global hooks: installed at $global_dir ($(cat "$global_dir/VERSION" 2>/dev/null || echo unknown version))"
    echo "[setup-hooks] previous global value: $(cat "$backup_file" 2>/dev/null || echo '(none saved)')"
  else
    echo "[setup-hooks] global hooks: not active"
  fi
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local_path="$(git config --local --get core.hooksPath 2>/dev/null || true)"
    if [[ -n "$local_path" ]]; then
      echo "[setup-hooks] this repository: core.hooksPath = $local_path (overrides the global one; its hooks run the checks unconditionally)"
    else
      echo "[setup-hooks] this repository: no local core.hooksPath; the global value applies"
    fi
  fi
}

# claude_supports_onfailure: 0 when the installed claude is 2.1.295 or newer,
# which honours "onFailure": "block" (a timeout or crash blocks, not passes).
ONFAILURE_MIN="2.1.295"
claude_supports_onfailure() {
  local v
  command -v claude >/dev/null 2>&1 && [[ -n "$PY" ]] || return 1
  v="$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [[ -n "$v" ]] || return 1
  "$PY" -c 'import sys
a = [int(x) for x in sys.argv[1].split(".")]; b = [int(x) for x in sys.argv[2].split(".")]
sys.exit(0 if a >= b else 1)' "$v" "$ONFAILURE_MIN"
}

# claude_onfailure <settings>: the onFailure value of our entry, or nothing.
claude_onfailure() {
  [[ -n "$PY" && -f "$1" ]] || return 0
  "$PY" "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$1")" 2>/dev/null \
    | sed -n 's/^onFailure=//p' | head -1 || true
}

# claude_entry <settings>: the hook command in that file, or nothing.
claude_entry() {
  [[ -n "$PY" && -f "$1" ]] || return 0
  "$PY" "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$1")" 2>/dev/null | head -1 || true
}

show_claude_status() {
  local entry pair kind file home
  for pair in "user|$claude_settings|$claude_home" "managed|$managed_settings|$managed_home"; do
    IFS='|' read -r kind file home <<<"$pair"
    entry="$(claude_entry "$file")"
    if [[ -n "$entry" ]]; then
      echo "[setup-hooks] claude hook ($kind): $file -> $entry"
      echo "[setup-hooks]   installed copy: $home ($(cat "$home/VERSION" 2>/dev/null || echo 'MISSING: the hook cannot run'))"
      if [[ "$(claude_onfailure "$file")" == block ]]; then
        echo "[setup-hooks]   onFailure: block (a timeout or crash blocks the command)"
      else
        echo "[setup-hooks]   WARN: no onFailure: a timeout or crash lets the command run. Claude Code $ONFAILURE_MIN or newer supports it; update it, then run --claude again."
      fi
    elif [[ "$kind" == user ]]; then
      echo "[setup-hooks] claude hook ($kind): not in $file"
    fi
  done
}

# install_claude <settings> <copy dir>
install_claude() {
  local settings="$1" home="$2" stage cmd onfailure rc=0
  require_owners
  if [[ -z "$PY" ]]; then
    echo "[setup-hooks] ERROR: Python 3 is needed (python3, or python on Windows): the hook and this installer use it." >&2
    exit 2
  fi
  if [[ "$ON_WINDOWS" == true ]] && ! command -v cygpath >/dev/null 2>&1; then
    echo "[setup-hooks] ERROR: run this from Git Bash (Git for Windows); Claude Code runs the hook there." >&2
    exit 2
  fi
  # Validate first: nothing is copied for a settings file that cannot be merged.
  "$PY" "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$settings")" >/dev/null || rc=$?
  [[ "$rc" -le 1 ]] || exit "$rc"

  stage="$(stage_common "$home")" || { echo "[setup-hooks] ERROR: could not stage $home" >&2; exit 1; }
  mkdir -p "$stage/scripts/claude-hooks" \
    && cp "$src_root/$HOOK_REL" "$stage/$HOOK_REL" \
    && cp "$src_root/$MERGE_REL" "$stage/$MERGE_REL" \
    || { rm -rf "$stage"; echo "[setup-hooks] ERROR: could not copy the hook" >&2; exit 1; }
  stage_and_swap "$home" "$stage"
  echo "[setup-hooks] hook copied to $home ($(cat "$home/VERSION"))"

  cmd="bash \"$(native_path "$home")/$HOOK_REL\""
  onfailure=""
  if claude_supports_onfailure; then onfailure=block; fi
  rc=0
  "$PY" "$(native_path "$home/$MERGE_REL")" install "$(native_path "$settings")" "$cmd" 60 $onfailure || rc=$?
  [[ "$rc" -eq 0 ]] || exit "$rc"
  echo "[setup-hooks] PreToolUse hook (matcher Bash, timeout 60 s, shell bash${onfailure:+, onFailure block}): $cmd"
  if [[ -z "$onfailure" ]]; then
    echo "[setup-hooks] WARN: Claude Code older than $ONFAILURE_MIN (or not found): a hook timeout or crash lets the command run."
  fi
  echo "[setup-hooks] New Claude Code sessions use it; /hooks lists it. Check it with: bash $src_root/scripts/setup-hooks.sh --doctor"
  offer_gitleaks
}

uninstall_claude() {
  local settings="$1" home="$2" rc=0
  if [[ -f "$settings" ]]; then
    [[ -n "$PY" ]] || { echo "[setup-hooks] ERROR: Python 3 is needed to edit $settings" >&2; exit 2; }
    "$PY" "$(native_path "$src_root/$MERGE_REL")" uninstall "$(native_path "$settings")" || rc=$?
    [[ "$rc" -eq 0 ]] || exit "$rc"
  fi
  rm -rf "${home:?}/scripts" "${home:?}/lib" "${home:?}/helpers.sh" "${home:?}/VERSION"
  rmdir "$home" 2>/dev/null || true
  echo "[setup-hooks] claude hook removed from $settings and $home"
}

# require_managed_access: the managed file, or its folder, must be writable by
# this user. No sudo here: the person runs this as admin, knowingly.
require_managed_access() {
  local dir probe
  dir="$(dirname "$managed_settings")"
  probe="$dir"
  while [[ ! -d "$probe" && "$probe" != "/" && "$probe" != "." ]]; do probe="$(dirname "$probe")"; done
  if { [[ -e "$managed_settings" ]] && [[ ! -w "$managed_settings" ]]; } || [[ ! -w "$probe" ]] \
     || { [[ -d "$dir" && ! -w "$dir" ]]; }; then
    echo "[setup-hooks] ERROR: no write access to $managed_settings. --managed needs an admin:" >&2
    if [[ "$ON_WINDOWS" == true ]]; then
      echo "[setup-hooks]   run Git Bash or PowerShell as Administrator, then setup-hooks --managed" >&2
    else
      echo "[setup-hooks]   sudo bash $src_root/scripts/setup-hooks.sh --managed" >&2
    fi
    exit 2
  fi
}

install_global() {
  local cur owners name stage
  require_owners
  owners="$(configured_owners)"
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  echo "[setup-hooks] current global core.hooksPath: ${cur:-(unset)}"
  mkdir -p "$global_dir" || exit 1
  if [[ "$cur" != "$global_hooks" ]]; then
    printf '%s\n' "${cur:-(unset)}" > "$backup_file"
    echo "[setup-hooks] saved it to $backup_file; --global --uninstall restores it"
  fi

  stage="$(stage_common "$global_dir")" || exit 1
  mkdir -p "$stage/scripts/global-hooks" "$stage/hooks" || { rm -rf "$stage"; exit 1; }
  cp "$src_root/scripts/security_hooks.sh" "$stage/scripts/" \
    && cp "$src_root/scripts/global-hooks/dispatch.sh" "$stage/scripts/global-hooks/" || { rm -rf "$stage"; exit 1; }
  for name in $GLOBAL_HOOK_NAMES; do
    printf '#!/usr/bin/env bash\nexec bash "%s/scripts/global-hooks/dispatch.sh" %s "$@"\n' "$global_dir" "$name" > "$stage/hooks/$name"
    chmod +x "$stage/hooks/$name"
  done
  stage_and_swap "$global_dir" "$stage"

  git config --global core.hooksPath "$global_hooks"
  echo "[setup-hooks] global core.hooksPath = $global_hooks"
  echo "[setup-hooks] Checked: github.com repositories of: $owners. Others run only their own hooks."
  echo "[setup-hooks] A repository with its own core.hooksPath ignores this; run setup-hooks.sh in it."
}

uninstall_global() {
  local cur prev
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  if [[ "$cur" != "$global_hooks" ]]; then
    echo "[setup-hooks] global core.hooksPath is '${cur:-(unset)}', not $global_hooks; left as is." >&2
  else
    prev="$(cat "$backup_file" 2>/dev/null || echo '(unset)')"
    if [[ "$prev" == "(unset)" || -z "$prev" ]]; then
      git config --global --unset core.hooksPath
      echo "[setup-hooks] global core.hooksPath unset (as before --global)"
    else
      git config --global core.hooksPath "$prev"
      echo "[setup-hooks] global core.hooksPath restored to $prev"
    fi
  fi
  rm -rf "${global_dir:?}/hooks" "${global_dir:?}/scripts" "${global_dir:?}/lib" "${global_dir:?}/helpers.sh" "${global_dir:?}/VERSION" "$backup_file"
  rmdir "$global_dir" 2>/dev/null || true
  echo "[setup-hooks] global hooks removed"
}

now_ms() { "$PY" -c 'import time; print(int(time.time() * 1000))'; }

# probe <want rc> <label> <json payload> <hook>: run the hook once from an empty
# directory. Returns 0 when the exit code is the expected one.
probe() {
  local want="$1" label="$2" payload="$3" hook="$4" dir t0 t1 rc=0
  dir="$(mktemp -d)"
  # The hook acts only in a repository whose origin is under an owner: probe
  # from a throwaway one. Claude Code sends the session directory as cwd.
  git init -q "$dir" 2>/dev/null \
    && git -C "$dir" remote add origin "https://github.com/$(configured_owners | cut -d, -f1 | tr -d ' ')/doctor-probe.git"
  payload="{\"cwd\":\"$(native_path "$dir")\",${payload#\{}"
  t0="$(now_ms)"
  printf '%s' "$payload" | (cd "$dir" && bash "$hook" >/dev/null 2>&1) || rc=$?
  t1="$(now_ms)"
  rm -rf "$dir"
  if [[ "$rc" == "$want" ]]; then
    printf '  ok    %-40s exit %s in %s ms\n' "$label" "$rc" "$((t1 - t0))"
  else
    printf '  FAIL  %-40s exit %s (want %s) in %s ms\n' "$label" "$rc" "$want" "$((t1 - t0))"
    return 1
  fi
}

doctor() {
  local entry hook failed=0
  prereqs || failed=1
  show_claude_status
  entry="$(claude_entry "$claude_settings")"
  [[ -n "$entry" ]] || entry="$(claude_entry "$managed_settings")"
  if [[ -z "$entry" || -z "$PY" ]]; then
    echo "[setup-hooks] no Claude hook installed; run: bash $src_root/scripts/setup-hooks.sh --claude" >&2
    return 1
  fi
  hook="${entry#bash }"; hook="${hook#\"}"; hook="${hook%\"}"; hook="$(unix_path "$hook")"
  if [[ ! -f "$hook" ]]; then
    echo "[setup-hooks] the hook in settings does not exist: $hook (it would fail open); run --claude again" >&2
    return 1
  fi
  echo "[setup-hooks] probes through $hook (a timeout lets the command run, so each must be well under 60 s):"
  probe 2 "git push --no-verify (must be refused)" \
    '{"tool_name":"Bash","tool_input":{"command":"git push --no-verify origin main"}}' "$hook" || failed=1
  probe 0 "ls (must pass)" '{"tool_name":"Bash","tool_input":{"command":"ls"}}' "$hook" || failed=1
  return "$failed"
}

if [[ "$GITLEAKS" == true ]]; then install_gitleaks; exit $?; fi
if [[ "$DOCTOR" == true ]]; then
  rc=0; doctor || rc=$?
  exit "$rc"
fi
if [[ "$STATUS" == true ]]; then
  show_global_status
  show_claude_status
  prereqs || true
  exit 0
fi
if [[ "$GLOBAL" == true || "$CLAUDE" == true || "$MANAGED" == true ]]; then
  if [[ "$UNINSTALL" == true ]]; then
    [[ "$GLOBAL" == true ]] && uninstall_global
    [[ "$CLAUDE" == true ]] && uninstall_claude "$claude_settings" "$claude_home"
    [[ "$MANAGED" == true ]] && { require_managed_access; uninstall_claude "$managed_settings" "$managed_home"; }
  else
    [[ "$GLOBAL" == true ]] && install_global
    [[ "$CLAUDE" == true ]] && install_claude "$claude_settings" "$claude_home"
    [[ "$MANAGED" == true ]] && { require_managed_access; install_claude "$managed_settings" "$managed_home"; }
  fi
  exit 0
fi

# This script's directory, both as the caller reached it and physically. Taken
# before the cd below: a relative path in BASH_SOURCE is relative to the
# caller's cwd.
script_dir_logical="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "[setup-hooks] ERROR: Run this script inside a Git worktree." >&2
  exit 1
fi
# The top as the caller sees it, symlinks kept: a vendored copy that is a symlink
# to a checkout elsewhere is inside the repository only in this view.
repo_root_logical="$(cd "./$(git rev-parse --show-cdup)" && pwd)"
cd "$repo_root"
repo_root="$(pwd -P)"

# bundled_under <script dir> <repository top>: the hooks next to this script as a
# repo-relative path, when that directory is inside the repository.
bundled_under() {
  if [[ "$1" == "$2"/* ]] && has_required_hooks "$1/git-hooks"; then
    echo "${1#"$2"/}/git-hooks"
  fi
}

# The bundled hooks next to this script, as a repo-relative path, or nothing:
# first as the caller reached them, then physically.
bundled_hooks() {
  local found
  found="$(bundled_under "$script_dir_logical" "$repo_root_logical")"
  [[ -n "$found" ]] || found="$(bundled_under "$script_dir" "$repo_root")"
  [[ -z "$found" ]] || echo "$found"
}

has_required_hooks() {
  local dir="$1"
  [[ -f "$dir/pre-commit" ]] && [[ -f "$dir/pre-push" ]]
}

resolve_hooks_dir() {
  # Returns a repo-relative path for git config storage; uses absolute paths for existence checks.
  if has_required_hooks "$repo_root/.githooks"; then
    echo ".githooks"
  elif [[ -n "$(bundled_hooks)" ]]; then
    bundled_hooks
  elif has_required_hooks "$repo_root/scripts/script-helpers/scripts/git-hooks"; then
    echo "scripts/script-helpers/scripts/git-hooks"
  elif has_required_hooks "$repo_root/scripts/git-hooks"; then
    echo "scripts/git-hooks"
  else
    echo ""
  fi
}

hooks_dir="$(resolve_hooks_dir)"   # relative — portable across clones
hooks_dir_abs="$repo_root/$hooks_dir"

if [[ -z "$hooks_dir" ]]; then
  echo "[setup-hooks] ERROR: No hooks directory found. Looked for pre-commit and pre-push in:" >&2
  echo "  .githooks/" >&2
  echo "  ${script_dir_logical}/git-hooks/  (next to this script)" >&2
  echo "  scripts/script-helpers/scripts/git-hooks/" >&2
  echo "  scripts/git-hooks/" >&2
  exit 1
fi

# Make all hook files executable
while IFS= read -r -d '' hook; do
  chmod +x "$hook"
done < <(find "$hooks_dir_abs" -maxdepth 1 -type f -print0)

git config core.hooksPath "$hooks_dir"
# This clone opted in: if the machine-wide hooks ever run here (no local
# core.hooksPath), they may chain to this repository's committed hooks.
git config --local script-helpers.trust-repo-hooks true
echo "[setup-hooks] core.hooksPath = $hooks_dir"
echo "[setup-hooks] Done. Hooks active for this repo, security checks included"
echo "[setup-hooks] (they run in every repository set up this way, whoever owns it)."
