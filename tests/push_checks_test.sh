#!/usr/bin/env bash
# SCRIPT: push_checks_test.sh
# DESCRIPTION: Tests scripts/push_checks.sh (hygiene and lint of what a push changes) and that pre-push runs it and no tests.
# USAGE: bash tests/push_checks_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/push_checks_test.sh
# ----------------------------------------------------
# Each check is fed input it must refuse and input it must pass: a check that
# fires on correct input gets switched off.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT_DIR/scripts/git-hooks/pre-push"
failures=0
note()  { echo "[push_checks_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[push_checks_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# Hermetic git: no user or system config, an identity per command.
export HOME="$tmp/home" GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE SCRIPT_HELPERS_SSH_NOTE_SHOWN
g() { git -c user.email=t@localhost -c user.name=t -c commit.gpgsign=false "$@"; }

zeroes="$(printf '0%.0s' $(seq 1 40))"
lt="$(printf '<%.0s' 1 2 3 4 5 6 7)"; gt="$(printf '>%.0s' 1 2 3 4 5 6 7)"

git init -q --bare "$tmp/origin.git"
repo="$tmp/repo"
git -c init.defaultBranch=main init -q "$repo"
cd "$repo" || exit 1
git remote add origin "$tmp/origin.git"
printf '#!/usr/bin/env bash\necho base\n' > base.sh
g add base.sh && g commit -qm base && git push -q origin main 2>/dev/null

# run_checks [refs-line] [url]: push_checks on HEAD against origin/main.
run_checks() {
  local line="${1:-refs/heads/main $(git rev-parse HEAD) refs/heads/main $(git rev-parse origin/main)}"
  printf '%s\n' "$line" > "$tmp/refs"
  ( source "$ROOT_DIR/scripts/push_checks.sh" && push_checks "$tmp/refs" origin "${2:-$tmp/origin.git}" ) 2>&1
}
# expect <label> <rc> <text> [refs-line] [url]
expect() {
  local label="$1" want="$2" text="$3" out rc
  out="$(run_checks "${4:-}" "${5:-}")"; rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    error "$label: exit $rc, expected $want: $(printf '%s' "$out" | grep -E 'REFUSED|refused' | head -3)"
  elif [[ -n "$text" ]] && ! grep -qF -- "$text" <<<"$out"; then
    error "$label: output lacks '$text': $(printf '%s' "$out" | head -5)"
  else
    ok "$label"
  fi
}
# commit <message> <file> <content> [more file/content pairs]: one new commit.
commit() {
  local msg="$1"; shift
  while [[ $# -ge 2 ]]; do mkdir -p -- "$(dirname -- "$1")"; printf '%s' "$2" > "$1"; g add -- "$1"; shift 2; done
  g commit -qm "$msg"
}
reset_main() { g reset -q --hard origin/main; git clean -qfdx; }

# --- hygiene
commit "clean" ok.sh $'#!/usr/bin/env bash\necho ok\n'
expect "a clean shell change passes" 0 "hygiene: 1 changed file(s)"
reset_main

commit "conflict" a.txt "one
$lt HEAD
two
=======
three
$gt branch
"
expect "a conflict marker is refused" 1 "a.txt has merge conflict markers (line 2"
reset_main

commit "heading" doc.md $'Title\n=======\n\ntext\n'
expect "a markdown heading underline is not a conflict marker" 0 ""
reset_main

g config script-helpers.max-file-mb 1
head -c 2097152 /dev/zero | tr '\0' 'a' > big.txt; g add big.txt; g commit -qm big
expect "a file over the size limit is refused" 1 "big.txt is 2 MB, over 1 MB"
commit "allow it" .script-helpers-push-allow $'# fixtures\nbig.txt\n'
expect "the allow file exempts it" 0 ""
g config --unset script-helpers.max-file-mb
reset_main

commit "env" .env "TOKEN=x"
expect ".env is refused" 1 ".env looks like a secret file"
reset_main
commit "examples" .env.example "NAME=" id_ed25519.pub "a public key"
expect ".env.example and a public key pass" 0 ""
reset_main
commit "pem" certs/server.pem "x"
expect "a .pem file is refused" 1 "certs/server.pem looks like a secret file"
reset_main
commit "key" id_rsa "x"
expect "a private key file is refused" 1 "id_rsa looks like a secret file"
reset_main

# --- AI trailers: the owners' repositories only
printf '[script-helpers]\n\towners = testowner\n' > "$GIT_CONFIG_GLOBAL"
commit "feat: x

Co-Authored-By: Claude <noreply@anthropic.com>" x.txt "x"
expect "an AI trailer is refused in an owner's repository" 1 "names an AI tool" "" "git@github.com:testowner/x.git"
expect "and allowed in another owner's repository" 0 "" "" "git@github.com:someone/x.git"
out="$(run_checks "" "git@github.com:testowner/x.git")"
grep -q "commit $(git rev-parse --short HEAD) names an AI tool" <<<"$out" \
  && ok "and the finding names that commit" || error "wrong commit named: $(grep 'AI tool' <<<"$out")"
g reset -q --hard origin/main
commit "feat: y

abc123 is the issue this fixes

Co-Authored-By: Claude <noreply@anthropic.com>" y.txt "y"
out="$(run_checks "" "git@github.com:testowner/x.git")"
grep -q "commit $(git rev-parse --short HEAD) names an AI tool" <<<"$out" \
  && ok "a message line that starts with a hex word does not change the commit named" \
  || error "a hex-looking message line was taken for the commit: $(grep 'AI tool' <<<"$out")"
g config script-helpers.ai-trailers allow
expect "and allowed where the repository turned it off" 0 "" "" "git@github.com:testowner/x.git"
g config --unset script-helpers.ai-trailers
: > "$GIT_CONFIG_GLOBAL"
expect "and not checked with no owners configured" 0 "" "" "git@github.com:testowner/x.git"
reset_main

# Plain ASCII commit messages, where a repository asks for them.
commit "fix: a $(printf '\342\200\224') b" z.txt "z"
expect "a non-ASCII message passes by default" 0 ""
g config script-helpers.ascii-commits true
expect "and is refused with script-helpers.ascii-commits" 1 "non-ASCII characters in its message"
g reset -q --hard origin/main
commit "fix: plain" z.txt "z"
expect "a plain ASCII message passes it" 0 ""
g config --unset script-helpers.ascii-commits
reset_main
commit "tf" infra/terraform.tfstate "{}"
expect "a Terraform state file is refused" 1 "terraform.tfstate looks like a secret file"
reset_main

# --- release branches
rel() {   # rel <changelog-heading> <version-file>: a commit on release/1.2.3
  g checkout -q -B release/1.2.3 origin/main
  commit "release" CHANGELOG.md "$1
- a change
" VERSION "$2
"
  printf 'refs/heads/release/1.2.3 %s refs/heads/release/1.2.3 %s' "$(git rev-parse HEAD)" "$zeroes"
}
line="$(rel '## 2026-10-13 - v1.2.3' 1.2.3)"
expect "a release heading with a hyphen is refused" 1 "CHANGELOG heading" "$line"
line="$(rel '## 2026-10-13 — v1.2.3' 1.2.3)"
expect "the em-dash heading with a matching VERSION passes" 0 "" "$line"
line="$(rel '## 2026-10-13 — v1.2.3' 1.2.4)"
expect "a VERSION that does not match the branch is refused" 1 "VERSION says '1.2.4'" "$line"
line="$(rel '## 2026-10-13 — v1.2.2' 1.2.3)"
expect "a newest release that is not the branch's is refused" 1 "is '1.2.2', not 1.2.3" "$line"
g checkout -q main; reset_main
# Another changelog style is not this check's to judge.
g checkout -q -B release/1.2.3 origin/main
commit "release" CHANGELOG.md $'# Changelog\n\n## [1.2.3] - 2026-10-13\n- x\n'
expect "a release branch with another changelog style is not judged" 0 "" \
  "refs/heads/release/1.2.3 $(git rev-parse HEAD) refs/heads/release/1.2.3 $zeroes"
g checkout -q main; reset_main

# --- lint
commit "syntax" broken.sh $'#!/usr/bin/env bash\nif then\n'
expect "a shell syntax error is refused" 1 "broken.sh"
reset_main
commit "spaces" "dir with space/my script.sh" $'#!/usr/bin/env bash\nif then\n'
expect "a path with spaces is checked and named" 1 "my script.sh"
reset_main
commit "shebang only" tool $'#!/bin/sh\nif then\n'
expect "an extensionless shell script is found by its shebang" 1 "tool"
reset_main
commit "dotted dir" v1.2/tool $'#!/usr/bin/env bash\nif then\n'
expect "and in a directory with a dot in its name" 1 "v1.2/tool"
reset_main
# A link is pushed as its target's name; the file it points at is not pushed.
printf '#!/usr/bin/env bash\nif then\n' > "$tmp/outside.sh"
ln -s "$tmp/outside.sh" link.sh && g add link.sh && g commit -qm link
expect "a symbolic link is not linted through to its target" 0 ""
# From a commit the link's blob is its target's name; named "if then" it would
# fail bash -n if it were linted as a file.
ln -s 'if then' link2.sh && g add link2.sh && g commit -qm link2
g checkout -q -b linkbranch && g checkout -q main && g reset -q --hard origin/main
expect "nor when the link is read from a commit" 0 "" "refs/heads/linkbranch $(git rev-parse linkbranch) refs/heads/linkbranch $(git rev-parse origin/main)"
g reset -q --hard origin/main; g branch -q -D linkbranch
if command -v shellcheck >/dev/null 2>&1; then
  commit "sc" warn.sh $'#!/usr/bin/env bash\nx=$1\nrm -rf $x/*\n'
  expect "a shellcheck warning is refused" 1 "shellcheck"
  reset_main
else
  note "SKIP: shellcheck not installed"
fi

# Without shellcheck and ruff: bash -n and the Python parse still catch syntax,
# and the missing tools are named. A PATH of links to everything but those two.
nobin="$tmp/nobin"; mkdir -p "$nobin"
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  for f in "$d"/*; do
    n="${f##*/}"
    [[ -x "$f" && ! -e "$nobin/$n" && "$n" != shellcheck && "$n" != ruff ]] && ln -s "$f" "$nobin/$n" 2>/dev/null
  done
done
commit "syntax" broken.sh $'#!/usr/bin/env bash\nif then\n'
out="$(PATH="$nobin" run_checks)"; rc=$?
[[ $rc -eq 1 ]] && grep -q 'broken.sh' <<<"$out" && grep -q 'shellcheck not installed' <<<"$out" \
  && ok "without shellcheck, bash -n refuses a syntax error and the tool is named" \
  || error "without shellcheck: exit $rc: $(grep -E 'REFUSED|lint' <<<"$out" | head -3)"
reset_main
if PATH="$nobin" bash -c 'command -v python3 || command -v python' >/dev/null 2>&1; then
  commit "py" bad.py $'def f(:\n    pass\n'
  out="$(PATH="$nobin" run_checks)"; rc=$?
  [[ $rc -eq 1 ]] && grep -q 'bad.py' <<<"$out" && ok "without ruff, the Python parse refuses a syntax error" \
    || error "without ruff: exit $rc: $(grep -E 'REFUSED|lint' <<<"$out" | head -3)"
  reset_main
fi

if command -v ruff >/dev/null 2>&1; then
  commit "excluded" pyproject.toml $'[tool.ruff]\nextend-exclude = ["vendored"]\n' vendored/bad.py $'import os\n'
  expect "ruff honours the repository's exclusions" 0 ""
  reset_main
fi

# The commit is checked, not the work tree: an uncommitted fix does not hide a
# bad commit, an uncommitted break does not refuse a good one, and a clean file
# in the work tree does not stand in for a bad one on another branch.
commit "bad" w.sh $'#!/usr/bin/env bash\nif then\n'
printf '#!/usr/bin/env bash\necho fixed\n' > w.sh
expect "a bad commit is refused though the work tree is fixed" 1 "w.sh"
reset_main
commit "good" w.sh $'#!/usr/bin/env bash\necho ok\n'
printf '#!/usr/bin/env bash\nif then\n' > w.sh
expect "a good commit passes though the work tree is broken" 0 ""
reset_main
g checkout -q -b samepath origin/main
commit "bad here" same.sh $'#!/usr/bin/env bash\nif then\n'
bad="$(git rev-parse HEAD)"
g checkout -q main
commit "good on main" same.sh $'#!/usr/bin/env bash\necho ok\n'
expect "a branch not checked out is read from its commit, not the work tree's same path" 1 "same.sh" \
  "refs/heads/samepath $bad refs/heads/samepath $zeroes"
reset_main

# A bad file already on the remote is not this push's business.
commit "old bad" legacy.sh $'#!/usr/bin/env bash\nif then\n'
git push -q origin main 2>/dev/null
commit "unrelated" new.txt "fine"
expect "an unchanged bad file is not checked" 0 ""
g reset -q --hard HEAD~1

py_ok=false; for p in python3 python; do command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(sys.version_info[0] != 3)' 2>/dev/null && py_ok=true && break; done
if [[ "$py_ok" == true ]]; then
  commit "py" bad.py $'def f(:\n    pass\n'
  expect "a python syntax error is refused" 1 "bad.py"
  reset_main
  commit "json" bad.json '{"a": 1,}'
  expect "invalid JSON is refused" 1 "bad.json"
  reset_main
  commit "jsonc" tsconfig.json $'{\n  // comments are allowed here\n  "compilerOptions": {}\n}\n'
  expect "tsconfig.json with comments is not parsed as JSON" 0 ""
  reset_main
  if "$p" -c 'import yaml' 2>/dev/null; then
    commit "yaml" bad.yml $'a: [1, 2\nb: 3\n'
    expect "invalid YAML is refused" 1 "bad.yml"
    reset_main
    mkdir -p "$tmp/noyaml" && printf 'raise ImportError("no yaml here")\n' > "$tmp/noyaml/yaml.py"
    commit "yaml" bad.yml $'a: [1, 2\nb: 3\n'
    out="$(PYTHONPATH="$tmp/noyaml" run_checks)"; rc=$?
    [[ $rc -eq 0 ]] && grep -q 'PyYAML not installed' <<<"$out" && ok "without PyYAML, YAML is named as not checked" \
      || error "without PyYAML: exit $rc: $(grep -iE 'yaml|REFUSED' <<<"$out" | head -3)"
    reset_main
    commit "tags" cfn.yml $'Resources:\n  B:\n    Value: !Ref Thing\n'
    expect "YAML with custom tags passes" 0 ""
    reset_main
    commit "workflow" .github/workflows/ci.yml $'on: push\njobs:\n  a:\n    runs-on: ${{ matrix.os }}\n    steps: [\n'
    expect "a broken workflow is parsed, \${{ }} notwithstanding" 1 "ci.yml"
    reset_main
    commit "helm" chart/templates/d.yaml $'kind: {{ .Values.kind }}\n  bad: [\n'
    expect "a Helm template is not parsed as YAML" 0 ""
    reset_main
  else
    note "SKIP: PyYAML not installed"
  fi
else
  note "SKIP: no Python 3"
fi

# The content pushed, not the work tree: a branch that is not checked out.
g checkout -q -b other origin/main
commit "bad on other" other.sh $'#!/usr/bin/env bash\nif then\n'
other="$(git rev-parse HEAD)"
g checkout -q main
out="$(run_checks "refs/heads/other $other refs/heads/other $zeroes")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q 'other.sh' <<<"$out" && ! grep -q "$tmp" <<<"$out"; then
  ok "a ref that is not checked out is checked from its commit, paths shown plainly"
else
  error "branch not checked out: exit $rc: $(grep -E 'REFUSED|other' <<<"$out" | head -3)"
fi
# A new branch sends only what the remote lacks: legacy.sh is on origin already.
g checkout -q -b fresh origin/main
commit "fresh" fresh.txt "fine"
expect "a new branch is checked only for what the remote lacks" 0 "1 changed file(s)" \
  "refs/heads/fresh $(git rev-parse HEAD) refs/heads/fresh $zeroes"
g checkout -q main; reset_main

# Many files: the checks are per push, not per file process storms.
for i in $(seq 1 20); do printf '#!/usr/bin/env bash\necho %s\n' "$i" > "f$i.sh"; done
g add . && g commit -qm many
start=$SECONDS
expect "20 changed shell files pass" 0 "20 changed file(s)"
[[ $((SECONDS - start)) -le 10 ]] && ok "and take at most 10 s ($((SECONDS - start)) s)" \
  || error "20 files took $((SECONDS - start)) s"
reset_main

# --- the repository's code runs only when the hook is the repository's own
lc="lint-changed:"$'\n\t'"@touch \"$tmp/lint-ran\""$'\n'
commit "lint target" Makefile "$lc" x.sh $'#!/usr/bin/env bash\necho x\n'
rm -f "$tmp/lint-ran"
out="$(run_checks)"
[[ ! -e "$tmp/lint-ran" ]] && grep -q 'lint-changed not run' <<<"$out" \
  && ok "an install outside the repository runs no lint-changed target" \
  || error "an outside install ran the repository's make target"
# Inside the work tree but untracked (a repository whose work tree is \$HOME).
mkdir -p tools && cp "$ROOT_DIR/scripts/push_checks.sh" "$ROOT_DIR/scripts/security_hooks.sh" "$ROOT_DIR/scripts/owner_scope.sh" tools/
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)" > "$tmp/refs"
rm -f "$tmp/lint-ran"
( source tools/push_checks.sh && push_checks "$tmp/refs" origin "$tmp/origin.git" ) >/dev/null 2>&1
[[ ! -e "$tmp/lint-ran" ]] && ok "an untracked copy inside the work tree is not trusted" \
  || error "an untracked copy inside the work tree ran the repository's make target"
# Tracked by the repository: its own hook, so its own target runs.
g add tools && g commit -qm "vendored checks"
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)" > "$tmp/refs"
rm -f "$tmp/lint-ran"
out="$( source tools/push_checks.sh && push_checks "$tmp/refs" origin "$tmp/origin.git" 2>&1 )"
[[ -e "$tmp/lint-ran" ]] && ok "a copy the repository tracks runs its lint-changed target" \
  || error "the repository's own copy did not run lint-changed: $(grep -E 'lint|REFUSED' <<<"$out" | head -3)"
reset_main

# A committed json.py must not be imported by the JSON check.
if [[ "$py_ok" == true ]]; then
  commit "shadow" json.py "open('$tmp/shadowed', 'w').write('x')
" bad.json '{"a": 1,}'
  rm -f "$tmp/shadowed"
  expect "invalid JSON is refused with a json.py in the repository" 1 "bad.json"
  [[ ! -e "$tmp/shadowed" ]] && ok "and the repository's json.py was not imported" \
    || error "the JSON check imported the repository's json.py"
  reset_main
fi

# A crafted tree naming ../ must not make the check write outside its directory.
blob="$(printf 'x\n' | git hash-object -w --stdin)"
sub="$(printf '100644 blob %s\tescaped.sh\n' "$blob" | git mktree)"
evil="$(printf '040000 tree %s\t..\n' "$sub" | git hash-object -t tree -w --literally --stdin 2>/dev/null || true)"
if [[ -n "$evil" ]] && evil_c="$(g commit-tree "$evil" -p "$(git rev-parse HEAD)" -m evil 2>/dev/null)"; then
  rm -f "$tmp"/escaped.sh
  run_checks "refs/heads/evil $evil_c refs/heads/evil $zeroes" >/dev/null 2>&1
  if find "$tmp" -maxdepth 3 -name escaped.sh -newer "$tmp/refs" -not -path "*/.git/*" | grep -q .; then
    error "a ../ path in a crafted tree was written outside the check's directory"
  else
    ok "a ../ path in a crafted tree is not written outside the check's directory"
  fi
else
  note "SKIP: this git would not build a tree naming .."
fi

# A path is data: a file named like an option is a file.
commit "dash" -x.sh $'#!/usr/bin/env bash\nif then\n'
expect "a file named like an option is checked, not read as one" 1 "syntax error"
reset_main
# --- the hook: checks run, tests do not
export SECURITY_GATE_ALLOW_UNCHECKED=1 PRIVATE_NAMES_AUTO_REFRESH=false
export PRIVATE_NAMES_FILE=/nonexistent/private-names.tsv
hook() {
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)" \
    | bash "$HOOK" origin "$tmp/origin.git" 2>&1
}
commit "suite" Makefile $'test:\n\t@echo SUITE-RAN; exit 1\n'
out="$(hook)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'Tests are not run on push' <<<"$out" && ! grep -q SUITE-RAN <<<"$out"; then
  ok "pre-push runs no tests: a failing make test does not refuse the push"
else
  error "pre-push and tests: exit $rc: $(tail -3 <<<"$out")"
fi
commit "conflict" c.txt "$lt HEAD
"
out="$(hook)"; rc=$?
[[ $rc -eq 1 ]] && grep -q 'merge conflict markers' <<<"$out" && ok "pre-push refuses on a push check" \
  || error "pre-push did not refuse a conflict marker: exit $rc"
reset_main

if [[ $failures -gt 0 ]]; then
  echo "[push_checks_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
