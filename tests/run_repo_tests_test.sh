#!/usr/bin/env bash
# SCRIPT: run_repo_tests_test.sh
# DESCRIPTION: Tests that scripts/run_repo_tests.sh finds and gates on a repository's tests, shell repositories included.
# USAGE: bash tests/run_repo_tests_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/run_repo_tests_test.sh
# ----------------------------------------------------
#
# This was the pre-push test stage; a push no longer runs tests. A repo with no
# manifest file matched no stack, so it printed "No test runner detected" and
# exited 0. Both shared libraries here are shell repos, so a red suite reported
# success (#84).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/scripts/run_repo_tests.sh"
failures=0
note()  { echo "[run_repo_tests_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[run_repo_tests_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@localhost -c user.name=t commit -q --allow-empty -m init

hook_run() { ( cd "$repo" && bash "$RUNNER" ${RUNNER_ARGS:-} 2>&1 ); }

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
case_is "a failing make test fails the run" 2 "tests failed"

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
case_is "a failing tests/*_test.sh fails the run" 1 "tests failed"

reset_repo
mkdir -p "$repo/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tests/x_test.sh"
case_is "a passing tests/*_test.sh allows it" 0 "All checks passed"

# 3. Nothing to run is not a failure.
reset_repo
case_is "a repo with no tests is still allowed" 0 "No test runner detected"
# --require (the push's opt-in tests): nothing to run is exit 4, not a pass.
RUNNER_ARGS=--require case_is "--require: a repo with no tests exits 4" 4 "no tests found"
printf 'test:\n\t@exit 0\n' > "$repo/Makefile"
RUNNER_ARGS=--require case_is "--require: a passing suite still exits 0" 0 "All checks passed"
reset_repo
RUNNER_ARGS=--bogus case_is "an unknown option is a usage error (2)" 2 "unknown option"
RUNNER_ARGS=--help case_is "--help prints the header, exit codes included, and exits 0" 0 "EXIT_CODES"

# 4. The guard that matters most: calling run_tests in a `||` context disables
#    set -e inside it, so a failing runner returned 0 and the run passed.
#    A node repo covers the branches that existed before the shell one.
reset_repo
printf '{"name":"x","private":true,"scripts":{"test":"exit 1"}}\n' > "$repo/package.json"
if command -v npm >/dev/null 2>&1; then
  case_is "a failing npm test fails the run" 1 "tests failed"
else
  note "SKIP: npm not installed, the node branch was not exercised"
fi

# The runner must not pass git's hook variables to the tests it runs (a repo's
# own .githooks/pre-push may call it). Git sets GIT_DIR for a hook, pointing at
# the repository being pushed (an absolute path in a linked worktree). A test
# that makes its own repository then used the pushed one and failed.
#
# The test file below does that: its new repository must have 0 commits, and
# it must see none of git's variables.
reset_repo
mkdir -p "$repo/tests"
cat > "$repo/tests/own_repo_test.sh" <<'T'
#!/usr/bin/env bash
fresh="$(mktemp -d)"
git init -q "$fresh/r" && cd "$fresh/r" || exit 9
commits="$(git rev-list --count --all 2>/dev/null)"
seen=""
for name in $(git rev-parse --local-env-vars); do [[ -z "${!name+x}" ]] || seen="$seen $name"; done
echo "fresh-commits=[$commits] seen=[$seen ] kept=[${KEPT_FOR_THE_SUITE:-}]"
cd / && rm -rf "$fresh"
[[ "$commits" == 0 && -z "$seen" ]]
T
git -C "$repo" -c user.email=t@localhost -c user.name=t add tests
git -C "$repo" -c user.email=t@localhost -c user.name=t commit -q -m "a suite that builds its own repository"
git -C "$repo" worktree add -q "$tmp/linked" -b linked
# as_git <dir>: run the runner in <dir> the way a hook would, with git's
# variables set. KEPT_FOR_THE_SUITE is not git's and must reach the tests.
as_git() {
  local dir="$1"; shift
  ( cd "$dir" && env GIT_DIR="$(git rev-parse --absolute-git-dir)" GIT_PREFIX="" GIT_CONFIG_PARAMETERS="'a.b=c'" \
            KEPT_FOR_THE_SUITE=yes "$@" bash "$RUNNER" 2>&1 )
}
out="$(as_git "$tmp/linked")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'fresh-commits=\[0\] seen=\[ \]' <<<"$out"; then
  ok "from a linked worktree, a suite that builds its own repository reads its own"
else
  error "the suite saw the repository being pushed (exit $rc): $(grep -E 'fresh-commits|refused' <<<"$out")"
fi
grep -q 'kept=\[yes\]' <<<"$out" && ok "the rest of the environment reaches the suite" \
  || error "a variable that is not git's was dropped: $(grep fresh-commits <<<"$out")"
out="$(as_git "$repo")"; rc=$?
[[ $rc -eq 0 ]] && ok "and from the main checkout" || error "main checkout, as a hook runs it: exit $rc"
# Control: without the hook, the same test file fails when GIT_DIR is set.
# So the passes above come from the runner.
if ( cd "$tmp/linked" && GIT_DIR="$(git rev-parse --absolute-git-dir)" bash tests/own_repo_test.sh >/dev/null 2>&1 ); then
  error "the suite passes with GIT_DIR set, so it proves nothing"
else
  ok "(the suite does fail when it can see GIT_DIR)"
fi
# The variables must stay when the push used `git --git-dir=...
# --work-tree=...`: unsetting them would lose the right place. Three cases.
# 1. The directory is not a repository. Only GIT_DIR points at one.
mkdir -p "$tmp/bare-tree/tests"
printf '#!/usr/bin/env bash\necho "git-dir=[${GIT_DIR:-}]"\n' > "$tmp/bare-tree/tests/says_test.sh"
out="$( cd "$tmp/bare-tree" && GIT_DIR="$repo/.git" GIT_WORK_TREE="$tmp/bare-tree" GIT_CEILING_DIRECTORIES="$tmp" bash "$RUNNER" 2>&1 )"
grep -qF "git-dir=[$repo/.git]" <<<"$out" && ok "a work tree that is found only through GIT_DIR keeps it" \
  || error "GIT_DIR was dropped where nothing else finds the repository: $(grep -E 'git-dir|fatal' <<<"$out" | head -3)"
# 2. The directory is a different repository. Unset, the tests would run
#    against that one.
git -c init.defaultBranch=main init -q "$tmp/bare-tree"
out="$( cd "$tmp/bare-tree" && GIT_DIR="$repo/.git" GIT_WORK_TREE="$tmp/bare-tree" bash "$RUNNER" 2>&1 )"
grep -qF "git-dir=[$repo/.git]" <<<"$out" && ok "nor is it dropped where the directory is another repository" \
  || error "GIT_DIR was dropped though the directory finds a different repository: $(grep -E 'git-dir|fatal' <<<"$out" | head -3)"

# 3. Same repository, but GIT_WORK_TREE is another work tree (a subdirectory
#    here). Unset, the tests would see the checkout's root instead.
reset_repo
mkdir -p "$repo/sub-tree/tests"
cp "$tmp/bare-tree/tests/says_test.sh" "$repo/sub-tree/tests/says_test.sh"
out="$( cd "$repo/sub-tree" && GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo/sub-tree" bash "$RUNNER" 2>&1 )"
grep -qF "git-dir=[$repo/.git]" <<<"$out" && ok "nor where GIT_WORK_TREE names another work tree of the same repository" \
  || error "GIT_DIR was dropped though the work tree differs without it: $(grep -E 'git-dir|fatal' <<<"$out" | head -3)"
rm -rf "$repo/sub-tree"

if [[ $failures -gt 0 ]]; then
  echo "[run_repo_tests_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
