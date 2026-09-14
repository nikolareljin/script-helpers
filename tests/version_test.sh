#!/usr/bin/env bash
# SCRIPT: version_test.sh
# DESCRIPTION: Tests for lib/version.sh (version_compare).
# USAGE: ./tests/version_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/version_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[version_test] $*"; }
error() { echo "[version_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging version

for fn in version_bump version_compare; do
  if declare -f "$fn" >/dev/null 2>&1; then note "$fn is defined"; else error "$fn is NOT defined"; fi
done

# expect <a> <b> <status>: version_compare's exit status, with stderr captured so
# an arithmetic error ("value too great for base") fails the check too.
expect() {
  local a="$1" b="$2" want="$3" got err
  set +e
  err="$(version_compare "$a" "$b" 2>&1)"
  got=$?
  set -e
  if [[ "$got" -ne "$want" ]]; then
    error "version_compare $a $b returned $got (expected $want)"
  elif [[ -n "$err" ]]; then
    error "version_compare $a $b printed: $err"
  fi
}

expect 1.2.3 1.2.3 0
expect 1.10.0 1.9.9 1
expect 1.9.9 1.10.0 255
expect v1.10.0-rc1 1.9.9 1
expect 1.2.3-rc.1 1.2.3 0      # a prerelease suffix is ignored, as documented
note "ordinary comparisons are unchanged"

# Leading zeros are decimal, not octal: 08 was an arithmetic error and 010 was 8.
expect 2026.08.1 2026.9.0 255
expect 2026.9.0 2026.08.1 1
expect 1.010.0 1.9.0 1
expect 1.08.0 1.8.0 0
note "leading zeros compare as decimal"

set +e
version_compare >/dev/null 2>&1;          [[ $? -eq 2 ]] || error "version_compare with no args did not return 2"
version_compare 1.2 1.2.3 >/dev/null 2>&1; [[ $? -eq 3 ]] || error "version_compare with an invalid version did not return 3"
set -e
note "bad arguments return 2 and 3"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
