#!/usr/bin/env bash
# SCRIPT: git_branches_test.sh
# DESCRIPTION: Tests for lib/git_branches.sh and scripts/prune_branches.sh.
# USAGE: ./tests/git_branches_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/git_branches_test.sh
# ----------------------------------------------------
#
# The case worth writing a fixture for is case 3: a branch that was
# squash-merged and then received another commit. Every other case is a branch
# that is obviously safe or obviously not; that one looks safe to any check
# that asks "are these changes in the base?" and is not.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[git_branches_test] $*"; }
error() { echo "[git_branches_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import git_branches

for fn in git_branches_default_branch git_branches_merge_state \
          git_branches_has_unpushed git_branches_worktree_of \
          git_branches_is_protected; do
  if declare -f "$fn" >/dev/null 2>&1; then ok "$fn is defined"; else error "$fn is NOT defined"; fi
done

# Bad arguments return 2 rather than guessing.
set +e
git_branches_merge_state >/dev/null 2>&1;   [[ $? -eq 2 ]] || error "merge_state with no args did not return 2"
git_branches_has_unpushed >/dev/null 2>&1;  [[ $? -eq 2 ]] || error "has_unpushed with no args did not return 2"
git_branches_is_protected >/dev/null 2>&1;  [[ $? -eq 2 ]] || error "is_protected with no args did not return 2"
set -e
ok "bad arguments return 2"

for name in main master trunk develop production release/0.24.0 hotfix/urgent; do
  git_branches_is_protected "$name" || error "$name should be protected"
done
git_branches_is_protected feature/x && error "feature/x should not be protected by default"
git_branches_is_protected feature/x 'feature/*' || error "feature/x should be protected by an extra pattern"
ok "protected-name matching"

# The fixture commits, so it needs an identity. This deliberately does not set
# one: configuring a name and address, even in a throwaway repo, is how a
# commit ends up attributed to something nobody chose. Without an identity the
# fixture is skipped and says so, rather than inventing one.
if ! git config --get user.email >/dev/null 2>&1 && [[ -z "${GIT_AUTHOR_EMAIL:-}" ]]; then
  note "SKIP: no git identity configured; fixture tests need one to commit"
  exit "$(( failures > 0 ? 1 : 0 ))"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

git init --quiet -b main .
commit() { echo "$2" > "$1"; git add "$1"; git commit --quiet -m "$2"; }
commit base.txt "base"

# 1) merged by a merge commit
git checkout --quiet -b merged-by-merge
commit a.txt "a"
git checkout --quiet main
git merge --quiet --no-ff -m "merge a" merged-by-merge

# 2) squash-merged: the change is in main under a different sha
git checkout --quiet -b squashed-clean main
commit b.txt "b"
git checkout --quiet main
git merge --quiet --squash squashed-clean
git commit --quiet -m "squashed b"

# 3) THE CASE: squash-merged, then a new commit on the branch afterwards
git checkout --quiet -b squashed-then-more main
commit c.txt "c"
git checkout --quiet main
git merge --quiet --squash squashed-then-more
git commit --quiet -m "squashed c"
git checkout --quiet squashed-then-more
commit c2.txt "c2 — added after the merge"

# 4) never merged
git checkout --quiet -b never-merged main
commit d.txt "d"

# 5) unrelated history
git checkout --quiet --orphan stranger
git rm -rq --cached . 2>/dev/null || true
rm -f ./*.txt
commit z.txt "z"

git checkout --quiet main

expect_state() {
  local branch="$1" want="$2" got
  got="$(git_branches_merge_state main "$branch")"
  if [[ "$got" == "$want" ]]; then ok "$branch is $got"
  else error "$branch: expected $want, got $got"; fi
}

expect_state merged-by-merge     merged
expect_state squashed-clean      squashed
expect_state squashed-then-more  unmerged   # the whole point of this file
expect_state never-merged        unmerged
expect_state stranger            unrelated

# The base itself is an ancestor of itself; callers must exclude it by name,
# and prune_branches.sh does. Asserted so nobody "fixes" that as redundant.
if [[ "$(git_branches_merge_state main main)" == "merged" ]]; then
  ok "the base classifies as merged against itself (callers must exclude it)"
else
  error "unexpected self-classification"
fi

# End to end: the script must delete exactly the two landed branches.
out="$(bash "$root_dir/scripts/prune_branches.sh" --no-fetch --base main --apply 2>&1)" || {
  echo "$out"; error "prune_branches.sh --apply failed"
}

remaining="$(git for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ')"
expected="main never-merged squashed-then-more stranger "
if [[ "$remaining" == "$expected" ]]; then
  ok "after --apply the surviving branches are exactly: $remaining"
else
  error "expected [$expected] but got [$remaining]"
fi

# And the dry run must delete nothing at all.
git checkout --quiet -b throwaway main
git checkout --quiet main
before="$(git for-each-ref --format='%(refname:short)' refs/heads/ | sort)"
bash "$root_dir/scripts/prune_branches.sh" --no-fetch --base main >/dev/null 2>&1
after="$(git for-each-ref --format='%(refname:short)' refs/heads/ | sort)"
if [[ "$before" == "$after" ]]; then ok "a dry run deletes nothing"; else error "the dry run deleted something"; fi

cd "$root_dir"
if [[ "$failures" -gt 0 ]]; then
  echo "[git_branches_test] $failures failure(s)" >&2
  exit 1
fi
note "all checks passed"
