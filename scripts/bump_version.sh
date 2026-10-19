#!/usr/bin/env bash
# SCRIPT: bump_version.sh
# DESCRIPTION: Bump the semantic version in a VERSION file using script-helpers.
# USAGE: ./bump_version.sh [major|minor|patch] [-f VERSION_FILE]
# PARAMETERS:
#   major|minor|patch   Which part of the version to increment.
#   -f, --file PATH     Version file path; a relative path is taken from the
#                       current directory (default: VERSION in the parent of the
#                       script-helpers directory).
#   -h, --help          Show this help.
# EXIT_CODES:
#   0  Version bumped and written (also -h/--help).
#   1  No arguments, unknown or repeated argument, -f without a path, a version
#      that is not X.Y.Z, or the version file directory could not be created.
# EXAMPLE:
#   scripts/bump_version.sh minor -f VERSION
# ----------------------------------------------------
set -euo pipefail

# Resolve script-helpers root and load modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging help env version

usage() { display_help; }

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

# version_bump resolves a relative -f path against the script-helpers parent
# directory, not the caller's cwd: `-f VERSION` from a project wrote into the
# vendored copy. Make the path absolute here, against where the user stands.
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      if [[ $# -ge 2 && -n "$2" && "$2" != /* ]]; then
        args+=("$1" "$PWD/$2"); shift 2; continue
      fi
      ;;
  esac
  args+=("$1"); shift
done

version_bump "${args[@]}" || exit $?
