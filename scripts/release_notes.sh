#!/usr/bin/env bash
# SCRIPT: release_notes.sh
# DESCRIPTION: Produce the body of a GitHub Release, from CHANGELOG.md if it has a section for the version, otherwise from the commit range.
# USAGE: scripts/release_notes.sh --version <X.Y.Z> [--tag <tag>] [--changelog <path>] [--repo <dir>] [--output <file>]
# PARAMETERS:
#   --version <X.Y.Z>   Version being released. Required.
#   --tag <tag>         Tag for that version (default: the version itself).
#   --changelog <path>  CHANGELOG to read (default: CHANGELOG.md in the repo).
#   --repo <dir>        Repository to read (default: current directory).
#   --output <file>     Write here instead of stdout. Prefer this: notes reach
#                       actions/gh through body_path, never through an
#                       interpolated string.
#   -h, --help          Show this help message.
# ----------------------------------------------------
#
# Why this exists: three ci-helpers workflows each inlined the same notes
# generator, and each resolved the range's start with
#
#     since_tag="$(git describe --tags --abbrev=0)"
#
# run from a checkout of the tag being released. That describe returns the tag
# it is standing on, so the range was always `X..X`, always empty, and every
# release body was the literal string `* No changes listed.` -- measured across
# nine repositories and four years of releases. The composite action they were
# inlined from took a `since_tag` input and did not have the bug; inlining it
# dropped the parameter.
#
# So: one implementation, and it asks for the previous tag rather than the
# nearest one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/helpers.sh"
shlib_import logging changelog

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

VERSION=""
TAG=""
CHANGELOG=""
REPO_DIR="."
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="${2:-}"; shift 2;;
    --tag)       TAG="${2:-}"; shift 2;;
    --changelog) CHANGELOG="${2:-}"; shift 2;;
    --repo)      REPO_DIR="${2:-}"; shift 2;;
    --output)    OUTPUT="${2:-}"; shift 2;;
    -h|--help)   usage; exit 0;;
    *) log_error "release_notes: unknown argument: $1"; usage >&2; exit 2;;
  esac
done

[[ -n "$VERSION" ]] || { log_error "release_notes: --version is required"; exit 2; }
[[ -d "$REPO_DIR" ]] || { log_error "release_notes: not a directory: $REPO_DIR"; exit 2; }

cd "$REPO_DIR"
[[ -n "$TAG" ]] || TAG="$VERSION"
[[ -n "$CHANGELOG" ]] || CHANGELOG="CHANGELOG.md"

# The tag whose commits we are describing. Works whether or not the release tag
# exists yet: before tagging there is nothing to exclude and HEAD is the end of
# the range; after tagging the tag is excluded and the range ends at it.
range_end="HEAD"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  range_end="$TAG"
fi

previous_tag() {
  # --exclude, not "$TAG^". Both find the previous tag in the ordinary case, but
  # `^` walks to a parent: it fails outright on a tag at a root commit, and on a
  # merge commit it silently follows the first parent only. This asks the
  # question actually being asked -- the nearest tag that is not this one.
  git describe --tags --abbrev=0 --exclude "$TAG" "$range_end" 2>/dev/null || true
}

body=""
source_used=""

if [[ -f "$CHANGELOG" ]] && body="$(changelog_extract "$CHANGELOG" "$VERSION" 2>/dev/null)" && [[ -n "$body" ]]; then
  source_used="the $CHANGELOG section for $VERSION"
else
  prev="$(previous_tag)"
  if [[ -n "$prev" ]]; then
    body="$(git log --no-merges --pretty=format:'* %s' "$prev..$range_end" || true)"
    source_used="commits in $prev..$range_end"
  else
    body="$(git log --no-merges --pretty=format:'* %s' "$range_end" || true)"
    source_used="every commit, because $TAG is the first tag"
  fi
fi

# Never a bare placeholder. `* No changes listed.` was indistinguishable between
# "this release changed nothing", "the range was computed wrongly" and "the
# changelog was never written" -- and it was always the second. A body that
# cannot say what changed should at least say what it looked at.
if [[ -z "${body//[[:space:]]/}" ]]; then
  body="No changes recorded for ${VERSION}. Looked at ${source_used}."
  log_warn "release_notes: nothing found for $VERSION; looked at $source_used"
else
  log_info "release_notes: $VERSION from $source_used"
fi

if [[ -n "$OUTPUT" ]]; then
  printf '%s\n' "$body" > "$OUTPUT"
else
  printf '%s\n' "$body"
fi
