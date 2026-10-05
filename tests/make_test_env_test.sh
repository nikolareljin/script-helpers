#!/usr/bin/env bash
# SCRIPT: make_test_env_test.sh
# DESCRIPTION: `make test` runs the suite without the variables git exports to a hook.
# USAGE: ./tests/make_test_env_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/make_test_env_test.sh
# ----------------------------------------------------
#
# Why `make test` clears them: the pre-push hook runs it, and git gives a hook
# GIT_DIR (and related variables) for the repository being pushed. GIT_DIR
# overrides the current directory, so a test that creates its own temporary
# repository would act on the pushed one. Such tests failed only inside the
# hook, and a push from a worktree was refused.
#
# How it is checked: the real Makefile is copied next to one test file that
# fails if it sees any of git's variables, and `make test` is run there with
# all of them set.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[make_test_env_test] $*"; }
error() { echo "[make_test_env_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[make_test_env_test]   ok  $*"; }

command -v make >/dev/null 2>&1 || { note "SKIP: make not available"; exit 0; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/repo/tests"
cp Makefile "$tmp/repo/Makefile"
# The one test file. It asks git for the variable names instead of listing
# them, so a later git that adds one does not break this test. The six a hook
# always gets are named for the run below that has no git.
cat >"$tmp/repo/tests/sees_test.sh" <<'T'
#!/usr/bin/env bash
seen=""
for name in $(git rev-parse --local-env-vars 2>/dev/null) \
            GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; do
  case " $seen " in *" $name "*) continue ;; esac
  [[ -z "${!name+x}" ]] || seen="$seen $name"
done
echo "seen:[$seen ] kept:[${KEPT_FOR_THE_SUITE:-}]"
[[ -z "$seen" ]]
T

# Run `make test` with the 15 variables git lists today set, each to a value
# git accepts, and with one unrelated variable that must not be cleared.
run() {
  GIT_DIR=/nonexistent/.git GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent/index \
  GIT_PREFIX=sub/ GIT_COMMON_DIR=/nonexistent/.git GIT_OBJECT_DIRECTORY=/nonexistent/objects \
  GIT_SHALLOW_FILE=/nonexistent/shallow GIT_ALTERNATE_OBJECT_DIRECTORIES=/nonexistent/alt \
  GIT_CONFIG_PARAMETERS="'a.b=c'" GIT_CONFIG_COUNT=0 GIT_GRAFT_FILE=/nonexistent/grafts \
  GIT_NO_REPLACE_OBJECTS=1 GIT_REPLACE_REF_BASE=refs/replace/ GIT_IMPLICIT_WORK_TREE=0 GIT_CONFIG=/nonexistent/config \
  KEPT_FOR_THE_SUITE=yes make -C "$tmp/repo" test 2>&1
}

out="$(run)"; rc=$?
if [[ "$rc" -eq 0 ]]; then ok "the suite does not see the variables git exports to a hook"; else error "make test let them through (exit $rc): $out"; fi
if grep -q 'seen:\[ \]' <<<"$out"; then ok "none of the variables git lists, not only the six a hook always gets"; else error "some were seen: $out"; fi
if grep -q 'kept:\[yes\]' <<<"$out"; then ok "and the rest of the environment is left alone"; else error "another variable was dropped: $out"; fi

# No git on the PATH: the Makefile cannot ask for the list, and must still
# clear the six it names. This PATH holds only the tools the run needs.
mkdir -p "$tmp/no-git"
for tool in make bash sh env grep sed cat ls printf dirname basename; do
  path="$(command -v "$tool" 2>/dev/null)" && [[ -x "$path" ]] && ln -sf "$path" "$tmp/no-git/$tool"
done
out="$(GIT_DIR=/nonexistent/.git GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent/index GIT_PREFIX=sub/ \
  GIT_COMMON_DIR=/nonexistent/.git GIT_OBJECT_DIRECTORY=/nonexistent/objects PATH="$tmp/no-git" make -C "$tmp/repo" test 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'seen:\[ \]' <<<"$out"; then ok "with no git on the PATH, the six a hook always sets are still dropped"; else error "without git (exit $rc): $out"; fi

# Control: run directly, not through `make test`, the same test file sees the
# variable and fails. So the passes above are the Makefile's doing.
if GIT_DIR=/nonexistent/.git bash "$tmp/repo/tests/sees_test.sh" >/dev/null 2>&1; then
  error "the one-line suite passes with GIT_DIR set, so it proves nothing"
else
  ok "(the one-line suite does fail when it can see one)"
fi

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
