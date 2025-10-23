#!/usr/bin/env bash
# SCRIPT: bump_version.sh
# DESCRIPTION: Bump the version number in the VERSION file. 
# USAGE: ./bump_version.sh [major|minor|patch]
# EXAMPLE: ./bump_version.sh minor
# ----------------------------------------------------
set -euo pipefail

# Resolve script-helpers root and load modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging dialog os env json file deps ollama help

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

usage() {
  display_help
}
if [[ $# -lt 1 ]]; then usage; exit 1; fi
bump_type="$1"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "0.1.0" > "$VERSION_FILE"
fi
current=$(cat "$VERSION_FILE" | tr -d ' \t\n\r')
IFS='.' read -r major minor patch <<< "$current"

case "$bump_type" in
  major) major=$((major + 1)); minor=0; patch=0;;
  minor) minor=$((minor + 1)); patch=0;;
  patch) patch=$((patch + 1));;
  *) usage; exit 1;;
esac

new_version="${major}.${minor}.${patch}"
echo "$new_version" > "$VERSION_FILE"
echo "Bumped version: $current -> $new_version"

