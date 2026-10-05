#!/usr/bin/env bash
# SCRIPT: make_test_env_test.sh
# DESCRIPTION: `make test` runs the suite without the variables git exports to a hook.
# USAGE: ./tests/make_test_env_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/make_test_env_test.sh
# ----------------------------------------------------
#
# The pre-push hook runs `make test`, and git has exported GIT_DIR to the hook.
# A test that builds a temporary repository and changes into it then still
# reads the repository being pushed: tests failed inside the hook that pass
# everywhere else, and a push from a worktree was refused.
#
# The real Makefile is copied beside a one-line suite that fails when it can
# see any of those variables, and `make test` is run there with all of them set.
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
cat >"$tmp/repo/tests/sees_test.sh" <<'T'
#!/usr/bin/env bash
seen=""
for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; do
  [[ -z "${!name+x}" ]] || seen="$seen $name"
done
echo "seen:[$seen ] kept:[${KEPT_FOR_THE_SUITE:-}]"
[[ -z "$seen" ]]
T

run() { # the variables a hook would have, and one that is nobody's business to remove
  GIT_DIR=/nonexistent/.git GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent/index \
  GIT_PREFIX=sub/ GIT_COMMON_DIR=/nonexistent/.git GIT_OBJECT_DIRECTORY=/nonexistent/objects \
  KEPT_FOR_THE_SUITE=yes make -C "$tmp/repo" test 2>&1
}

out="$(run)"; rc=$?
if [[ "$rc" -eq 0 ]]; then ok "the suite does not see the variables git exports to a hook"; else error "make test let them through (exit $rc): $out"; fi
if grep -q 'seen:\[ \]' <<<"$out"; then ok "none of the six"; else error "some were seen: $out"; fi
if grep -q 'kept:\[yes\]' <<<"$out"; then ok "and the rest of the environment is left alone"; else error "another variable was dropped: $out"; fi

# The test can fail: the same suite, run without make, sees them.
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
