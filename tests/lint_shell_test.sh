#!/usr/bin/env bash
# SCRIPT: lint_shell_test.sh
# DESCRIPTION: scripts/lint_shell.sh fails on a ShellCheck error, and CI runs it without `|| true`.
# USAGE: ./tests/lint_shell_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/lint_shell_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[lint_shell_test] $*"; }
error() { echo "[lint_shell_test][ERROR] $*" >&2; failures=$((failures+1)); }

lint="$root_dir/scripts/lint_shell.sh"
[[ -f "$lint" ]] || { echo "[lint_shell_test][ERROR] scripts/lint_shell.sh is missing" >&2; exit 1; }

# 1) CI calls the gate and does not swallow its exit code.
# (`shellcheck --version ... || true` only prints the version and is allowed.)
swallowed="$(grep -E 'shellcheck.*\|\|[[:space:]]*true' .github/workflows/ci.yml | grep -v -- '--version' || true)"
if [[ -n "$swallowed" ]]; then
  error "ci.yml still runs shellcheck with '|| true'"
fi
grep -q 'make lint-shell' .github/workflows/ci.yml || error "ci.yml does not run 'make lint-shell'"

# The bash 3.2 image and the macOS runner have no shellcheck. ci.yml installs
# it and runs `make lint-shell`, which exits 2 without it, so the gate holds.
if ! command -v shellcheck >/dev/null 2>&1; then
  if [[ "$failures" -gt 0 ]]; then
    echo "[lint_shell_test] FAILED: $failures check(s)" >&2
    exit 1
  fi
  note "shellcheck not installed: skipping the behaviour checks (not a failure)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
repo="$tmp/repo"
mkdir -p "$repo/bin"
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid

run_lint() { ( cd "$repo" && bash "$lint" ) >"$tmp/out" 2>&1; }
run_list() { ( cd "$repo" && bash "$lint" --list ) >"$tmp/out" 2>&1; }

# 2) A clean tree passes.
printf '#!/usr/bin/env bash\necho "ok"\n' > "$repo/good.sh"
git -C "$repo" add -A
if run_lint; then note "clean tree passes"; else error "clean tree failed: $(cat "$tmp/out")"; fi

# 3) An error-level finding in a *.sh file fails (SC1073-class parse error).
printf '#!/usr/bin/env bash\nif true; then\n  echo x\n' > "$repo/bad.sh"
git -C "$repo" add -A
if run_lint; then error "parse error in bad.sh did not fail"; else note "error in *.sh fails"; fi
git -C "$repo" rm -q -f bad.sh

# 4) A shell file without the .sh suffix is checked too (hooks, bin/).
printf '#!/bin/sh\nif true; then\n  echo x\n' > "$repo/bin/tool"
git -C "$repo" add -A
run_list
grep -qx 'bin/tool' "$tmp/out" || error "bin/tool (sh shebang, no suffix) is not listed"
if run_lint; then error "error in bin/tool did not fail"; else note "error in suffixless shell file fails"; fi
git -C "$repo" rm -q -f bin/tool

# 5) A non-shell script is not checked.
mkdir -p "$repo/bin"
printf '#!/usr/bin/env python3\nprint(1)\n' > "$repo/bin/py"
printf '#!/usr/bin/env bashful\n' > "$repo/bin/notsh"
git -C "$repo" add -A
run_list
if grep -qx -e 'bin/py' -e 'bin/notsh' "$tmp/out"; then error "non-shell file listed: $(cat "$tmp/out")"; else note "non-shell files skipped"; fi

# 5b) Shebang variants a shell file is written with are all listed: env with
# flags, CRLF line ends, dash and ksh (ShellCheck dialects), a space in the name.
printf '#!/usr/bin/env bash -e\necho x\n' > "$repo/bin/envflag"
printf '#!/bin/bash\r\necho x\r\n' > "$repo/bin/crlf"
printf '#!/bin/dash\necho x\n' > "$repo/bin/dashy"
printf '#!/bin/ksh\necho x\n' > "$repo/bin/kshy"
printf '#!/bin/sh\necho x\n' > "$repo/bin/with space"
printf '#!/usr/bin/env zsh\necho x\n' > "$repo/bin/zshy"
git -C "$repo" add -A
run_list
for f in bin/envflag bin/crlf bin/dashy bin/kshy "bin/with space"; do
  grep -qxF "$f" "$tmp/out" || error "$f is not listed: $(cat "$tmp/out")"
done
grep -qx 'bin/zshy' "$tmp/out" && error "zsh file listed; ShellCheck does not support zsh"
git -C "$repo" rm -q -f bin/envflag bin/crlf bin/dashy bin/kshy "bin/with space" bin/zshy

# 6) Warnings fail at the default severity and pass at SHELLCHECK_SEVERITY=error.
printf '#!/usr/bin/env bash\nunused=1\n' > "$repo/warn.sh"
git -C "$repo" add -A
if run_lint; then error "warning passed at default severity"; else note "warning fails at default severity"; fi
if SHELLCHECK_SEVERITY=error run_lint; then note "warning passes at severity error"; else error "warning failed at severity error"; fi

# 7) An unknown severity is refused, not ignored.
rc=0; SHELLCHECK_SEVERITY=bogus run_lint || rc=$?
[[ "$rc" -eq 2 ]] || error "bogus severity returned $rc, want 2"

# 8) An unknown argument and a directory outside git are refused, not passed.
rc=0; ( cd "$repo" && bash "$lint" --lst ) >"$tmp/out" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || error "unknown argument returned $rc, want 2"
rc=0; ( cd "$repo" && bash "$lint" --list extra ) >"$tmp/out" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || error "extra argument returned $rc, want 2"

# 9) Run from a subdirectory, the whole tree is still checked.
( cd "$repo/bin" && bash "$lint" --list ) >"$tmp/out" 2>&1 || true
grep -qx 'warn.sh' "$tmp/out" || error "run from bin/ did not list top-level warn.sh: $(cat "$tmp/out")"

mkdir -p "$tmp/nogit"
rc=0; ( cd "$tmp/nogit" && GIT_CEILING_DIRECTORIES="$tmp" bash "$lint" ) >"$tmp/out" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || error "outside a work tree returned $rc, want 2"

if [[ "$failures" -gt 0 ]]; then
  echo "[lint_shell_test] FAILED: $failures check(s)" >&2
  exit 1
fi
note "all checks passed"
