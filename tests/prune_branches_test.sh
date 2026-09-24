#!/usr/bin/env bash
# SCRIPT: prune_branches_test.sh
# DESCRIPTION: Tests that scripts/prune_branches.sh never deletes a remote branch from stale refs.
# USAGE: bash tests/prune_branches_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/prune_branches_test.sh
# ----------------------------------------------------
#
# The remote case: a branch merged, then someone pushed another commit to it.
# A pruner whose remote-tracking ref predates that push still sees "merged".
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[prune_branches_test] $*"; }
error() { echo "[prune_branches_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

PRUNE="$root_dir/scripts/prune_branches.sh"
git_t() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }

# remote.git: main, plus feature merged into main with a merge commit.
setup() {
  rm -rf "$tmp/remote.git" "$tmp/author" "$tmp/pruner"
  git_t init -q --bare "$tmp/remote.git"
  git --git-dir="$tmp/remote.git" symbolic-ref HEAD refs/heads/main
  git_t clone -q "$tmp/remote.git" "$tmp/author" 2>/dev/null
  (
    cd "$tmp/author" || exit 1
    git_t checkout -q -b main
    echo base > f; git_t add f; git_t commit -q -m base
    git_t checkout -q -b feature
    echo feat > g; git_t add g; git_t commit -q -m feat
    git_t checkout -q main
    git_t merge -q --no-ff -m merge feature
    git_t push -q origin main feature
  ) || error "fixture setup failed"
  git_t clone -q "$tmp/remote.git" "$tmp/pruner" 2>/dev/null
}

# The author pushes a new commit to the already-merged branch.
push_after_merge() {
  (
    cd "$tmp/author" || exit 1
    git_t checkout -q feature
    echo more > h; git_t add h; git_t commit -q -m "after merge"
    git_t push -q origin feature
  ) || error "push after merge failed"
}

remote_has_feature() { git --git-dir="$tmp/remote.git" show-ref --verify --quiet refs/heads/feature; }

# --- --remote --apply --no-fetch is refused ---------------------------------
setup
push_after_merge
rc=0
out="$(bash "$PRUNE" --repo "$tmp/pruner" --base main --remote --apply --no-fetch 2>&1)" || rc=$?
if [[ $rc -ne 0 ]] && remote_has_feature; then
  note "--remote --apply --no-fetch refused (exit $rc), branch kept"
else
  error "--remote --apply --no-fetch: rc=$rc, branch present: $(remote_has_feature && echo yes || echo no); out=$out"
fi

# The report is still available from stale refs.
rc=0
out="$(bash "$PRUNE" --repo "$tmp/pruner" --base main --remote --no-fetch 2>&1)" || rc=$?
if [[ $rc -eq 0 && "$out" == *"dry run"* ]]; then
  note "--remote --no-fetch dry run still reports"
else
  error "--remote --no-fetch dry run: rc=$rc out=$out"
fi

# --- a failed fetch is refused too ------------------------------------------
git -C "$tmp/pruner" remote set-url origin "$tmp/does-not-exist.git"
rc=0
out="$(bash "$PRUNE" --repo "$tmp/pruner" --base main --remote --apply 2>&1)" || rc=$?
if [[ $rc -ne 0 && "$out" == *"refusing"* ]]; then
  note "failed fetch with --remote --apply refused (exit $rc)"
else
  error "failed fetch: rc=$rc out=$out"
fi

# --- a ref the fetch did not refresh: the lease keeps the branch ------------
# The pruner fetches only main, so its origin/feature stays at the merged tip
# even though the fetch itself succeeds.
setup
git -C "$tmp/pruner" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
push_after_merge
rc=0
out="$(bash "$PRUNE" --repo "$tmp/pruner" --base main --remote --apply 2>&1)" || rc=$?
if remote_has_feature; then
  note "branch that moved after classification was not deleted (exit $rc)"
else
  error "remote branch with a post-merge commit was deleted from a stale ref: $out"
fi
if [[ $rc -ne 0 ]]; then
  note "a refused deletion is reported as a failure"
else
  error "refused deletion exited 0: $out"
fi

# --- a branch that really is merged is still deleted -------------------------
setup
rc=0
out="$(bash "$PRUNE" --repo "$tmp/pruner" --base main --remote --apply 2>&1)" || rc=$?
if [[ $rc -eq 0 ]] && ! remote_has_feature; then
  note "merged remote branch deleted"
else
  error "merged remote branch not deleted: rc=$rc out=$out"
fi

if [[ $failures -gt 0 ]]; then
  echo "[prune_branches_test] FAILED with $failures error(s)" >&2
  exit 1
fi
echo "[prune_branches_test] OK"
