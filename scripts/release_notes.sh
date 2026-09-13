#!/usr/bin/env bash
# SCRIPT: release_notes.sh
# DESCRIPTION: Produce the body of a GitHub Release, from CHANGELOG.md if it has a section for the version, otherwise from the commit range.
# USAGE: scripts/release_notes.sh --version <X.Y.Z> [--tag <tag>] [--changelog <path>] [--repo <dir>] [--output <file>]
# PARAMETERS:
#   --version <X.Y.Z>   Version being released. Required.
#   --tag <tag>         Tag for that version (default: X.Y.Z or vX.Y.Z, whichever
#                       exists; X.Y.Z when neither does yet).
#   --changelog <path>  CHANGELOG to read, relative to --repo (default: CHANGELOG.md).
#   --repo <dir>        Repository to read (default: current directory).
#   --output <file>     Write here instead of stdout, relative to the current
#                       directory. Prefer this: notes reach actions/gh through
#                       body_path, never through an interpolated string.
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
# So: one implementation, and it asks for the previous release tag rather than
# the nearest tag of any kind.
#
# The commit fallback needs full history. In a shallow clone (actions/checkout's
# default) it refuses rather than describe one commit as a first release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/helpers.sh"
shlib_import logging changelog

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# A lone `--version` at the end used to reach `shift 2` with one argument left,
# which exits 1 under set -e and says nothing.
need_value() {
  [[ $# -ge 2 && -n "$2" ]] || { log_error "release_notes: $1 requires a value"; usage >&2; exit 2; }
}

VERSION=""
TAG=""
CHANGELOG=""
REPO_DIR="."
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   need_value "$@"; VERSION="$2"; shift 2;;
    --tag)       need_value "$@"; TAG="$2"; shift 2;;
    --changelog) need_value "$@"; CHANGELOG="$2"; shift 2;;
    --repo)      need_value "$@"; REPO_DIR="$2"; shift 2;;
    --output)    need_value "$@"; OUTPUT="$2"; shift 2;;
    -h|--help)   usage; exit 0;;
    *) log_error "release_notes: unknown argument: $1"; usage >&2; exit 2;;
  esac
done

[[ -n "$VERSION" ]] || { log_error "release_notes: --version is required"; exit 2; }
if ! [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
  log_error "release_notes: not a version: '$VERSION' (expected X.Y.Z, optionally with a pre-release or build suffix)"
  exit 2
fi
[[ -d "$REPO_DIR" ]] || { log_error "release_notes: not a directory: $REPO_DIR"; exit 2; }

# Before the cd: `--output body.md --repo ../other` means ./body.md, not a file
# inside the other repository's working tree.
if [[ -n "$OUTPUT" && "$OUTPUT" != /* ]]; then
  OUTPUT="$PWD/$OUTPUT"
fi

cd "$REPO_DIR"
bare="${VERSION#v}"
[[ -n "$CHANGELOG" ]] || CHANGELOG="CHANGELOG.md"

tag_exists() { git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1; }

# A repository tagged vX.Y.Z must not need --tag. Defaulting to the bare version
# there meant "not tagged yet", HEAD as the range end, and describe returning
# vX.Y.Z itself: an empty range.
if [[ -z "$TAG" ]]; then
  TAG="$bare"
  if ! tag_exists "$bare" && tag_exists "v$bare"; then
    TAG="v$bare"
  fi
fi

# The tag whose commits we are describing. Works whether or not the release tag
# exists yet: before tagging there is nothing to exclude and HEAD is the end of
# the range; after tagging the tag is excluded and the range ends at it.
range_end="HEAD"
if tag_exists "$TAG"; then
  range_end="$TAG"
fi

previous_tag() {
  # Only version-shaped tags count. `git describe --tags` otherwise returns a
  # floating tag such as `production` or `latest` sitting on the release commit,
  # and the range is empty again. When --tag carries a prefix before the version
  # (`app-v1.2.0`), the previous release is looked for under the same prefix.
  local prefix=""
  local -a match=(--match '[0-9]*.[0-9]*.[0-9]*' --match 'v[0-9]*.[0-9]*.[0-9]*')
  if [[ "$TAG" == *"$bare" ]]; then
    prefix="${TAG%"$bare"}"
    if [[ -n "$prefix" && "$prefix" != "v" ]]; then
      match=(--match "${prefix}[0-9]*.[0-9]*.[0-9]*")
    fi
  fi
  # --exclude, not "$TAG^". Both find the previous tag in the ordinary case, but
  # `^` walks to a parent: it fails outright on a tag at a root commit, and on a
  # merge commit it silently follows the first parent only. This asks the
  # question actually being asked -- the nearest release tag that is not this
  # one, under either spelling.
  git describe --tags --abbrev=0 "${match[@]}" \
    --exclude "$TAG" --exclude "$bare" --exclude "v$bare" "$range_end" 2>/dev/null || true
}

body=""
source_used=""

if [[ -f "$CHANGELOG" ]] && body="$(changelog_extract "$CHANGELOG" "$VERSION" 2>/dev/null)" && [[ -n "$body" ]]; then
  source_used="the $CHANGELOG section for $VERSION"
else
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_error "release_notes: $PWD is not a git repository and $CHANGELOG has no section for $VERSION"
    exit 1
  fi
  # A shallow clone has no previous tag to find, so the answer would be one
  # commit presented as a whole first release. Refuse instead.
  if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    log_error "release_notes: $CHANGELOG has no section for $VERSION, and this is a shallow clone,"
    log_error "  so the commits since the previous tag cannot be listed. Check out with"
    log_error "  full history (actions/checkout: fetch-depth: 0), or add the CHANGELOG section."
    exit 1
  fi
  prev="$(previous_tag)"
  if [[ -n "$prev" ]]; then
    range="$prev..$range_end"
    source_used="commits in $range"
  else
    range="$range_end"
    source_used="every commit, because $TAG is the first tag"
  fi
  # No `|| true`: a git log that fails is an error, not an empty release.
  if ! body="$(git log --no-merges --pretty=format:'* %s' "$range")"; then
    log_error "release_notes: git log $range failed"
    exit 1
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
