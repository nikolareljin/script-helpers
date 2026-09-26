#!/usr/bin/env bash
# SCRIPT: pre_push_shell_repo_test.sh
# DESCRIPTION: Tests that scripts/git-hooks/pre-push runs, and gates on, a shell repo's tests.
# USAGE: bash tests/pre_push_shell_repo_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/pre_push_shell_repo_test.sh
# ----------------------------------------------------
#
# A repo with no manifest file matched no stack, so the hook printed "No test
# runner detected" and exited 0. Both shared libraries here are shell repos, so
# a push with a red suite reported success (#84).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT_DIR/scripts/git-hooks/pre-push"
failures=0
note()  { echo "[pre_push_shell_repo_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[pre_push_shell_repo_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@localhost -c user.name=t commit -q --allow-empty -m init

zeroes="$(printf '0%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
                          21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"

# The hook reads its refs on stdin. A non-deletion line is required or it takes
# the deletions-only shortcut and never reaches a test runner at all.
hook_run() {
  local sha; sha="$(git -C "$repo" rev-parse HEAD)"
  ( cd "$repo" && printf 'refs/heads/main %s refs/heads/main %s\n' "$sha" "$zeroes" \
      | bash "$HOOK" origin git@example.invalid:x.git 2>&1 )
}

case_is() {   # <label> <expect-rc> <expect-text>
  local label="$1" want_rc="$2" want="$3" out rc
  out="$(hook_run)"; rc=$?
  if [[ "$rc" -ne "$want_rc" ]]; then
    error "${label}: exit ${rc}, expected ${want_rc}"
  elif ! grep -q -- "$want" <<<"$out"; then
    error "${label}: output did not contain '${want}'"
  else
    ok "$label"
  fi
}

reset_repo() { rm -f "$repo/Makefile" "$repo/package.json"; rm -rf "$repo/tests"; }

# 1. A Makefile test target is run, and a failure refuses the push.
reset_repo
printf 'test:\n\t@exit 1\n' > "$repo/Makefile"
case_is "a failing make test refuses the push" 2 "tests failed"

reset_repo
printf 'test:\n\t@exit 0\n' > "$repo/Makefile"
case_is "a passing make test allows it" 0 "All checks passed"

# A Makefile without a test target must not be treated as a test runner.
reset_repo
printf 'build:\n\t@exit 1\n' > "$repo/Makefile"
case_is "a Makefile with no test target is not run" 0 "No test runner detected"

# 2. tests/*_test.sh, the convention this library uses for itself.
reset_repo
mkdir -p "$repo/tests"
printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/tests/x_test.sh"
case_is "a failing tests/*_test.sh refuses the push" 1 "tests failed"

reset_repo
mkdir -p "$repo/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tests/x_test.sh"
case_is "a passing tests/*_test.sh allows it" 0 "All checks passed"

# 3. Nothing to run is still allowed, or every docs repo becomes unpushable.
reset_repo
case_is "a repo with no tests is still allowed" 0 "No test runner detected"

# 4. The guard that matters most: calling run_tests in a `||` context disables
#    set -e inside it, so a failing runner returned 0 and the push went through.
#    A node repo covers the branches that existed before the shell one.
reset_repo
printf '{"name":"x","private":true,"scripts":{"test":"exit 1"}}\n' > "$repo/package.json"
if command -v npm >/dev/null 2>&1; then
  case_is "a failing npm test refuses the push" 1 "tests failed"
else
  note "SKIP: npm not installed, the node branch was not exercised"
fi

if [[ $failures -gt 0 ]]; then
  echo "[pre_push_shell_repo_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
