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

# The fixture commits, so it needs an identity, and it supplies its own with
# `git -c` per command (see git_t below). Nothing is written to any
# repository's configuration and the identity cannot outlive the command it is
# passed to, so no commit is ever attributed to something nobody chose.
#
# It is injected rather than required, so the fixture always runs -- including
# in CI, which has no identity of its own.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# The fixture supplies its own identity per invocation with `git -c`, the same
# way tests/hub_test.sh already does. Two reasons it is not `git config`:
# nothing is written to any repository's configuration, and the identity cannot
# outlive the command it is passed to.
#
# It is passed rather than required because the previous version skipped when
# the environment had no identity -- and CI has none, so every fixture check
# below, including the base-branch regression, never ran there while the run
# reported success. A check that reads as a pass when it did not execute is
# worse than no check.
git_t() { git -c user.name='script-helpers tests' -c user.email='tests@localhost' "$@"; }

git init --quiet -b main .
commit() { echo "$2" > "$1"; git add "$1"; git_t commit --quiet -m "$2"; }
commit base.txt "base"

# 1) merged by a merge commit
git checkout --quiet -b merged-by-merge
commit a.txt "a"
git checkout --quiet main
git_t merge --quiet --no-ff -m "merge a" merged-by-merge

# 2) squash-merged: the change is in main under a different sha
git checkout --quiet -b squashed-clean main
commit b.txt "b"
git checkout --quiet main
git merge --quiet --squash squashed-clean
git_t commit --quiet -m "squashed b"

# 3) THE CASE: squash-merged, then a new commit on the branch afterwards
git checkout --quiet -b squashed-then-more main
commit c.txt "c"
git checkout --quiet main
git merge --quiet --squash squashed-then-more
git_t commit --quiet -m "squashed c"
git checkout --quiet squashed-then-more
commit c2.txt "c2 — added after the merge"

# 3b) squash-merged, then a WHITESPACE-ONLY commit afterwards. `git cherry`
# ignores whitespace, so without a byte-exact confirmation this came back
# `squashed` and was deleted -- with a re-indent that, in Python, moves a call
# out of an `if`.
git checkout --quiet -b squashed-then-reindent main
printf 'def f(x):\n    if x:\n        launch()\n    audit()\n' > f.py
git add f.py; git_t commit --quiet -m "add f"
git checkout --quiet main
git merge --quiet --squash squashed-then-reindent
git_t commit --quiet -m "squashed f"
git checkout --quiet squashed-then-reindent
printf 'def f(x):\n    if x:\n        launch()\n        audit()\n' > f.py
git add f.py; git_t commit --quiet -m "only audit when launched"

# 3c) squash-merged, touching names with a space, a newline and pathspec
# magic characters. The byte-exact check limits its search to the paths the
# branch touches, so those names must reach git as themselves.
git checkout --quiet -b squashed-odd-names main
printf 'one\n' > 'with space.txt'
printf 'two\n' > "$(printf 'new\nline.txt')"
printf 'three\n' > ':(glob)*.txt'
git add -A; git_t commit --quiet -m "odd names"
git checkout --quiet main
git merge --quiet --squash squashed-odd-names
git_t commit --quiet -m "squashed odd names"
# Base moves on, so the trees differ and the patch comparison is what decides.
commit after-odd.txt "base moves"

# 4) never merged
git checkout --quiet -b never-merged main
commit d.txt "d"

# 5) unrelated history
git checkout --quiet --orphan stranger
git rm -rq --cached . 2>/dev/null || true
rm -f ./*.txt ./*.py "$(printf 'new\nline.txt')"
commit z.txt "z"

git checkout --quiet main

expect_state() {
  local branch="$1" want="$2" got
  got="$(git_branches_merge_state main "$branch")"
  if [[ "$got" == "$want" ]]; then ok "$branch is $got"
  else error "$branch: expected $want, got $got"; fi
}

# Whether this git can confirm a `git cherry` match byte for byte, with
# `patch-id --verbatim` or the diff-hash fallback. When it cannot, every such
# branch is `unknown` by design, and the checks that need a confirmed match
# are skipped -- reported, not passed.
#
# Probed here rather than by asking the library, so a library that wrongly
# believes it cannot verify fails these checks instead of skipping them.
can_verify=0
if git patch-id --verbatim </dev/null >/dev/null 2>&1 \
   || printf '' | git hash-object --stdin >/dev/null 2>&1; then
  can_verify=1
fi
skip() { note "SKIP: $* (this git can confirm no patch byte for byte)"; }

expect_state merged-by-merge     merged
if (( can_verify )); then
  expect_state squashed-clean      squashed
  expect_state squashed-odd-names  squashed
else
  skip "squashed-clean / squashed-odd-names are squashed"
fi
expect_state squashed-then-more  unmerged   # the whole point of this file
# Whitespace is content. `git cherry` matches the patch, the byte-exact check
# does not: that is `unknown`, not `unmerged` -- the branch is kept, without
# claiming it carries work the base lacks.
expect_state squashed-then-reindent unknown
expect_state never-merged        unmerged
expect_state stranger            unrelated

# The base itself is an ancestor of itself; callers must exclude it by name,
# and prune_branches.sh does. Asserted so nobody "fixes" that as redundant.
if [[ "$(git_branches_merge_state main main)" == "merged" ]]; then
  ok "the base classifies as merged against itself (callers must exclude it)"
else
  error "unexpected self-classification"
fi

# The squash probe must work where there is no git identity at all.
#
# `git commit-tree` refuses to run without an author and a committer, and CI
# has neither. Before this was fixed the probe failed, the error was swallowed,
# and every squash-merged branch came back `unmerged` -- so the check that
# justifies this whole module reported a confident wrong answer, and only in
# the environment nobody watches. This test failed in CI while passing on a
# developer machine, which is the failure mode it now guards.
#
# GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM are pointed at /dev/null rather than
# relying on HOME, so no configuration file anywhere can supply an identity.
# shellcheck disable=SC2016  # $1 is for the inner bash -c, not this shell
no_identity_state="$(
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
      -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      bash -c 'source "$1"/helpers.sh; shlib_import git_branches; git_branches_merge_state main squashed-clean' \
      _ "$root_dir"
)"
if (( ! can_verify )); then
  skip "squash detection with no git identity"
elif [[ "$no_identity_state" == "squashed" ]]; then
  ok "squash detection works with no git identity available"
else
  error "with no git identity, squashed-clean came back '$no_identity_state' (expected squashed)"
fi

# A git without `patch-id --verbatim` (older than 2.39) confirms a match with
# the diff-hash fallback instead: squash-merged branches are still found, and
# the whitespace-only case is still not called squashed.
# shellcheck disable=SC2317  # the git override is called indirectly, by the library
no_verbatim() {
  git() {
    if [[ "${1:-}" == patch-id ]]; then echo "error: unknown option" >&2; return 129; fi
    command git "$@"
  }
  git_branches_merge_state main "$1"
}
if (( ! can_verify )); then
  skip "the no-patch-id fallback"
else
  old_git_state="$(no_verbatim squashed-clean)"
  if [[ "$old_git_state" == "squashed" ]]; then
    ok "without patch-id --verbatim the fallback still finds a squash merge"
  else
    error "without patch-id --verbatim, squashed-clean came back '$old_git_state' (expected squashed)"
  fi
  old_git_state="$(no_verbatim squashed-odd-names)"
  if [[ "$old_git_state" == "squashed" ]]; then
    ok "the fallback handles names with spaces, newlines and magic"
  else
    error "without patch-id --verbatim, squashed-odd-names came back '$old_git_state' (expected squashed)"
  fi
  old_git_state="$(no_verbatim squashed-then-reindent)"
  if [[ "$old_git_state" == "unknown" ]]; then
    ok "the fallback does not call a whitespace-only change squashed"
  else
    error "without patch-id --verbatim, squashed-then-reindent came back '$old_git_state' (expected unknown)"
  fi
fi

# Neither `patch-id --verbatim` nor the fallback: unknown, kept.
# shellcheck disable=SC2317  # the git override is called indirectly, by the library
# (Defined outside the command substitution: bash 3.2 cannot parse a `case`
# inside `$( )`.)
no_verify() {
  git() {
    if [[ "${1:-}" == patch-id || "${1:-}" == hash-object ]]; then
      echo "error: unavailable" >&2; return 129
    fi
    command git "$@"
  }
  git_branches_merge_state main "$1"
}
no_verify_state="$(no_verify squashed-clean)"
if [[ "$no_verify_state" == "unknown" ]]; then
  ok "with no way to confirm a cherry match it is unknown, not squashed"
else
  error "with no byte-exact check available, squashed-clean came back '$no_verify_state' (expected unknown)"
fi

# The byte-exact check diffs only base commits that touch the branch's paths,
# and never with `--binary`. Both were missing once: every commit on base was
# diffed with every binary blob inlined, and prune took over a minute per
# branch on a repository with binary assets. Checked on the commands the
# library runs, so the test stays fast whether or not it regresses.
limit_dir="$tmp/limit"
mkdir -p "$limit_dir"
(
  cd "$limit_dir"
  git init --quiet -b main .
  commit base.txt "base"
  git checkout --quiet -b landed-early main
  commit early.txt "early"
  git checkout --quiet main
  git merge --quiet --squash landed-early >/dev/null
  git_t commit --quiet -m "squashed early"
  i=0
  while (( i < 30 )); do
    i=$((i + 1))
    printf 'asset %s\0\001\002' "$i" > asset.bin
    git add asset.bin; git_t commit --quiet -m "asset $i"
  done
)
limit_log="$tmp/limit.log"
: > "$limit_log"
# shellcheck disable=SC2317  # the git override is called indirectly, by the library
limit_state="$(
  cd "$limit_dir"
  git() {
    if [[ "${1:-}" == diff-tree ]]; then
      printf 'diff-tree %s\n' "$*" >> "$limit_log"
      if [[ " $* " == *" --stdin "* ]]; then
        tee -a "$limit_log.stdin" | command git "$@"; return
      fi
    fi
    command git "$@"
  }
  git_branches_merge_state main landed-early
)"
fed=0
[[ -f "$limit_log.stdin" ]] && fed="$(grep -c . "$limit_log.stdin" || true)"
if (( can_verify )) && [[ "$limit_state" != "squashed" ]]; then
  error "the path-limit fixture came back '$limit_state' (expected squashed)"
fi
if grep -q -- '--binary' "$limit_log"; then
  error "the byte-exact check diffs with --binary (inlines every binary blob on base)"
else
  ok "the byte-exact check does not diff with --binary"
fi
if (( fed > 2 )); then
  error "the byte-exact check diffed $fed base commits; only the one touching the branch's paths is needed"
else
  ok "the byte-exact check diffs only base commits touching the branch's paths ($fed)"
fi

# End to end: the script must delete exactly the two landed branches.
out="$(bash "$root_dir/scripts/prune_branches.sh" --no-fetch --base main --apply 2>&1)" || {
  echo "$out"; error "prune_branches.sh --apply failed"
}

remaining="$(git for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ')"
expected="main never-merged squashed-then-more squashed-then-reindent stranger "
if (( ! can_verify )); then
  skip "the --apply survivor set"
elif [[ "$remaining" == "$expected" ]]; then
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

# A base branch with a name none of the protected patterns covers, which is not
# the branch currently checked out. Every branch is an ancestor of itself, so
# the base classifies as `merged` against itself; without an explicit guard the
# pruner deletes the branch everything else merges into. Found in review of the
# first version of this script, where exactly that guard was missing on the
# local path.
cd "$tmp"
rm -rf base_guard && mkdir base_guard && cd base_guard
git init --quiet -b staging .
commit base.txt "base"
git checkout --quiet -b landed
commit e.txt "e"
git checkout --quiet staging
git_t merge --quiet --no-ff -m "merge e" landed
# Stand somewhere else, so the current-branch rule cannot mask a missing base
# guard the way it does when you happen to be on the base.
git checkout --quiet -b parked staging

bash "$root_dir/scripts/prune_branches.sh" --no-fetch --base staging --apply >/dev/null 2>&1 || \
  error "prune_branches.sh failed on the non-standard base fixture"

if git show-ref --verify --quiet refs/heads/staging; then
  ok "a base branch with a non-standard name survives --apply"
else
  error "the base branch 'staging' was DELETED"
fi
if git show-ref --verify --quiet refs/heads/landed; then
  error "the landed branch was not deleted"
else
  ok "the branch merged into that base was deleted"
fi

# The same guard, reached through the flag. `--base` is human-facing and people
# type what they see: origin/main, refs/heads/main, refs/remotes/origin/main.
# Un-normalised, none of those match a local branch name, so the base stops
# being recognised as the base and is deleted as merged against itself.
git remote add origin . 2>/dev/null || true
i=0
for spec in refs/heads/staging origin/staging refs/remotes/origin/staging; do
  i=$((i + 1))
  git checkout --quiet -b "landed${i}" staging
  commit "f${i}.txt" "f${i}"
  git checkout --quiet staging
  git_t merge --quiet --no-ff -m "merge f${i}" "landed${i}"
  git checkout --quiet parked

  bash "$root_dir/scripts/prune_branches.sh" --no-fetch --base "$spec" --apply >/dev/null 2>&1 || \
    error "prune_branches.sh failed with --base $spec"

  if git show-ref --verify --quiet refs/heads/staging; then
    ok "--base $spec keeps the base branch"
  else
    error "--base $spec DELETED the base branch"
    git checkout --quiet -b staging "$(git rev-parse parked)" 2>/dev/null || true
  fi
done

cd "$root_dir"
if [[ "$failures" -gt 0 ]]; then
  echo "[git_branches_test] $failures failure(s)" >&2
  exit 1
fi
note "all checks passed"
