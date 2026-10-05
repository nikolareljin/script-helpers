#!/usr/bin/env bash
# SCRIPT: make_test_env_test.sh
# DESCRIPTION: `make test` runs the suite without the variables git exports to a hook.
# USAGE: ./tests/make_test_env_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/make_test_env_test.sh
# ----------------------------------------------------
#
# Background: the pre-push hook runs `make test`, and git gives a hook GIT_DIR
# (and related variables) pointing at the repository being pushed. GIT_DIR
# wins over the current directory, so a test that creates its own temporary
# repository would still act on the pushed one. Such tests failed inside the
# hook and nowhere else, and a push from a worktree was refused. `make test`
# therefore clears those variables first.
#
# How this checks it: the real Makefile is copied into a temporary directory
# next to a single test file that fails if it can see any of git's variables.
# `make test` is then run there with all of them set.
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
# The single test file. It looks for every variable git itself lists, plus
# the six a hook always gets (for the run below that has no git). The names
# are asked of git rather than typed here, so this test does not start
# failing when a later git adds one.
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

# Without git on the PATH the Makefile cannot ask for the list. The six
# variables a hook always gets are written out in it and must still be
# cleared. The PATH below holds only the tools the run needs, and no git.
mkdir -p "$tmp/no-git"
for tool in make bash sh env grep sed cat ls printf dirname basename; do
  path="$(command -v "$tool" 2>/dev/null)" && [[ -x "$path" ]] && ln -sf "$path" "$tmp/no-git/$tool"
done
out="$(GIT_DIR=/nonexistent/.git GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent/index GIT_PREFIX=sub/ \
  GIT_COMMON_DIR=/nonexistent/.git GIT_OBJECT_DIRECTORY=/nonexistent/objects PATH="$tmp/no-git" make -C "$tmp/repo" test 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'seen:\[ \]' <<<"$out"; then ok "with no git on the PATH, the six a hook always sets are still dropped"; else error "without git (exit $rc): $out"; fi

# Control: the same test file, run directly instead of through `make test`,
# does see the variable and fails. Without this, the cases above could pass
# because the test file never fails.
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
