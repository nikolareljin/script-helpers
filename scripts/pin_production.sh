#!/usr/bin/env bash
# SCRIPT: pin_production.sh
# DESCRIPTION: Point the production branch at a specific tag, forward or (explicitly) backward.
# USAGE: scripts/pin_production.sh <tag> [--allow-rewind] [--remote <name>] [--branch <name>] [--dry-run]
# PARAMETERS:
#   <tag>             Release tag to point production at (e.g. 0.10.0).
#   --allow-rewind    Permit moving production to a tag that is NOT ahead of it —
#                     i.e. a rollback, or a move onto a diverged history. Without
#                     this flag such a move is refused rather than attempted.
#   --remote <name>   Remote to read and push (default: origin).
#   --branch <name>   Branch to move (default: production). main, master and HEAD are refused.
#   --dry-run         Report what would change and push nothing.
#   -h, --help        Show this help message.
# EXAMPLE:
#   scripts/pin_production.sh 0.10.0                   # roll forward
#   scripts/pin_production.sh 0.9.0 --allow-rewind     # roll back, deliberately
# ----------------------------------------------------
#
# Why the rewind is a separate flag, and why this verifies the result.
#
# The move used to be `git merge --ff-only "$TAG"`, and rolling back was
# documented as a supported use. It never worked, and it never said so: when
# the target is an ANCESTOR of production, `--ff-only` reports "Already up to
# date" and exits 0. The script then pushed nothing of consequence and printed
# "production now points to tag <tag>". Exit 0, success message, production
# untouched — the operator had to notice on their own that the rollback they
# asked for had not happened.
#
# So: a backward or diverged move is now named (--allow-rewind) rather than
# silently attempted, and the end state is read back from the remote before
# anything claims success.
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG=""
REMOTE="origin"
BRANCH="production"
ALLOW_REWIND=false
DRY_RUN=false

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --allow-rewind) ALLOW_REWIND=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$TAG" ]]; then
        echo "Unexpected argument: $1" >&2
        exit 2
      fi
      TAG="$1"; shift
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  usage >&2
  exit 1
fi

case "$BRANCH" in
  main|master|HEAD|"")
    echo "Refusing to move branch '$BRANCH'." >&2
    exit 1
    ;;
esac

cd "$ROOT_DIR"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required." >&2
  exit 1
fi

# The working tree is never touched — the move is a refspec push — so a dirty
# tree is no longer a reason to refuse, and the caller is not left standing on
# a checked-out production branch the way the old implementation left them.
git fetch --tags --force "$REMOTE" >/dev/null 2>&1 || {
  echo "Failed to fetch tags from '$REMOTE'." >&2
  exit 1
}
git fetch --force "$REMOTE" "refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" >/dev/null 2>&1 || true

if ! target="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")"; then
  echo "Tag not found: $TAG" >&2
  exit 1
fi

# The remote is the authority on where the branch currently is. A stale local
# copy is exactly how a move gets reasoned about against the wrong base.
current="$(git ls-remote "$REMOTE" "refs/heads/$BRANCH" | awk '{print $1}')"

describe_move() {
  echo "  tag            $TAG"
  echo "  target commit  $target"
  echo "  $BRANCH is now  ${current:-<does not exist>}"
}

if [[ -z "$current" ]]; then
  kind="create"
elif [[ "$current" == "$target" ]]; then
  echo "$BRANCH already points at $TAG ($target). Nothing to do."
  exit 0
elif git merge-base --is-ancestor "$current" "$target" 2>/dev/null; then
  kind="fast-forward"
elif git merge-base --is-ancestor "$target" "$current" 2>/dev/null; then
  kind="rewind"
else
  kind="diverged"
fi

if [[ "$kind" == "rewind" || "$kind" == "diverged" ]] && [[ "$ALLOW_REWIND" != true ]]; then
  {
    echo "Refusing to move $BRANCH: $TAG is not ahead of it ($kind)."
    describe_move
    echo
    echo "This is the case that used to report success and do nothing."
    echo "If you mean to roll back, say so:"
    echo "  scripts/pin_production.sh $TAG --allow-rewind"
  } >&2
  exit 1
fi

echo "Moving $BRANCH to $TAG ($kind)."
describe_move

if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run: nothing pushed."
  exit 0
fi

if [[ "$kind" == "rewind" || "$kind" == "diverged" ]]; then
  # --force-with-lease pinned to the value just read, so a concurrent move by
  # someone else aborts this push rather than being overwritten by it.
  git push --force-with-lease="refs/heads/$BRANCH:$current" \
    "$REMOTE" "$target:refs/heads/$BRANCH"
else
  git push "$REMOTE" "$target:refs/heads/$BRANCH"
fi

# Read it back. `git push` exiting 0 is not by itself evidence that the branch
# is where it was asked to go.
landed="$(git ls-remote "$REMOTE" "refs/heads/$BRANCH" | awk '{print $1}')"
if [[ "$landed" != "$target" ]]; then
  echo "Push reported success but $BRANCH is at ${landed:-<missing>}, not $target." >&2
  exit 1
fi

echo "$BRANCH now points to tag $TAG ($target)."
