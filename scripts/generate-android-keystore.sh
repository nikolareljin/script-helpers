#!/usr/bin/env bash
# SCRIPT: generate-android-keystore.sh
# DESCRIPTION: Generate an Android signing keystore without placing passwords on a command line.
# USAGE: bash scripts/generate-android-keystore.sh <output.jks>
# PARAMETERS:
#   <output.jks>  Required new keystore path. Existing files are refused.
# EXIT_CODES:
#   0  Keystore generated.
#   1  Keystore generation failed.
#   2  Invalid arguments.
# EXAMPLE: bash scripts/generate-android-keystore.sh ./release.jks
# ----------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../helpers.sh
source "$ROOT_DIR/helpers.sh"
shlib_import android
if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: $0 <output.jks>"
  exit 0
fi
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output.jks>" >&2
  exit 2
fi
android_generate_keystore "$1"
