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

# A tests-only escape, so a suite that needs services this machine has not got
# does not leave --no-verify as the only way to push. --no-verify would skip
# the private-name check too.
reset_repo
printf 'test:\n\t@exit 1\n' > "$repo/Makefile"
out="$( cd "$repo" && printf 'refs/heads/main %s refs/heads/main %s\n' \
        "$(git -C "$repo" rev-parse HEAD)" "$zeroes" \
        | PRE_PUSH_SKIP_TESTS=1 bash "$HOOK" origin git@example.invalid:x.git 2>&1 )"; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'tests skipped' <<<"$out"; then
  ok "PRE_PUSH_SKIP_TESTS=1 skips a failing suite"
else
  error "PRE_PUSH_SKIP_TESTS=1 did not skip the tests (exit $rc)"
fi

# and the refusal has to name it, or nobody knows it exists
reset_repo
printf 'test:\n\t@exit 1\n' > "$repo/Makefile"
out="$(hook_run)"
grep -q 'PRE_PUSH_SKIP_TESTS=1 git push' <<<"$out" \
  && ok "the refusal names the tests-only escape" \
  || error "the refusal did not name the tests-only escape"

# The hook must not pass git's hook variables to the tests it runs. Git gives
# a hook GIT_DIR (and related variables) for the repository being pushed,
# absolute from a linked worktree. A test that creates its own repository
# then acted on the pushed one, failed only inside the hook, and the push was
# refused.
#
# The test file below is such a test: its fresh repository must have 0
# commits, and it must see none of git's variables.
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
# as_git <dir>: run the hook in <dir> as git does, with its pre-push
# variables set, plus one unrelated variable that must survive.
as_git() {
  local dir="$1"; shift
  ( cd "$dir" && printf 'refs/heads/linked %s refs/heads/linked %s\n' "$(git rev-parse HEAD)" "$zeroes" \
      | env GIT_DIR="$(git rev-parse --absolute-git-dir)" GIT_PREFIX="" GIT_CONFIG_PARAMETERS="'a.b=c'" \
            KEPT_FOR_THE_SUITE=yes "$@" bash "$HOOK" origin git@example.invalid:x.git 2>&1 )
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
[[ $rc -eq 0 ]] && ok "and from the main checkout" || error "main checkout, as git runs the hook: exit $rc"
# Control: run with GIT_DIR set and no hook to clear it, the same test file
# fails. So the passes above are the hook's doing.
if ( cd "$tmp/linked" && GIT_DIR="$(git rev-parse --absolute-git-dir)" bash tests/own_repo_test.sh >/dev/null 2>&1 ); then
  error "the suite passes with GIT_DIR set, so it proves nothing"
else
  ok "(the suite does fail when it can see GIT_DIR)"
fi
# The variables are kept when clearing them would lose the right place
# (`git --git-dir=... --work-tree=... push`). Three cases.
# 1. The directory is no repository: GIT_DIR is the only pointer to one.
mkdir -p "$tmp/bare-tree/tests"
printf '#!/usr/bin/env bash\necho "git-dir=[${GIT_DIR:-}]"\n' > "$tmp/bare-tree/tests/says_test.sh"
out="$( cd "$tmp/bare-tree" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$repo" rev-parse HEAD)" "$zeroes" \
        | GIT_DIR="$repo/.git" GIT_WORK_TREE="$tmp/bare-tree" GIT_CEILING_DIRECTORIES="$tmp" bash "$HOOK" origin git@example.invalid:x.git 2>&1 )"
grep -qF "git-dir=[$repo/.git]" <<<"$out" && ok "a work tree that is found only through GIT_DIR keeps it" \
  || error "GIT_DIR was dropped where nothing else finds the repository: $(grep -E 'git-dir|fatal' <<<"$out" | head -3)"
# 2. The directory is a different repository: cleared, the tests would run
#    against that one.
git -c init.defaultBranch=main init -q "$tmp/bare-tree"
out="$( cd "$tmp/bare-tree" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$repo" rev-parse HEAD)" "$zeroes" \
        | GIT_DIR="$repo/.git" GIT_WORK_TREE="$tmp/bare-tree" bash "$HOOK" origin git@example.invalid:x.git 2>&1 )"
grep -qF "git-dir=[$repo/.git]" <<<"$out" && ok "nor is it dropped where the directory is another repository" \
  || error "GIT_DIR was dropped though the directory finds a different repository: $(grep -E 'git-dir|fatal' <<<"$out" | head -3)"

# 3. The same repository, but GIT_WORK_TREE names another work tree (here a
#    subdirectory): cleared, the tests would see the checkout's root instead.
reset_repo
mkdir -p "$repo/sub-tree/tests"
cp "$tmp/bare-tree/tests/says_test.sh" "$repo/sub-tree/tests/says_test.sh"
out="$( cd "$repo/sub-tree" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$repo" rev-parse HEAD)" "$zeroes" \
        | GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo/sub-tree" bash "$HOOK" origin git@example.invalid:x.git 2>&1 )"
grep -qF "git-dir=[$repo/.git]" <<<"$out" && ok "nor where GIT_WORK_TREE names another work tree of the same repository" \
  || error "GIT_DIR was dropped though the work tree differs without it: $(grep -E 'git-dir|fatal' <<<"$out" | head -3)"
rm -rf "$repo/sub-tree"

if [[ $failures -gt 0 ]]; then
  echo "[pre_push_shell_repo_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
