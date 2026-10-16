#!/usr/bin/env bash
# SCRIPT: ci_pimcore_bundle_check_test.sh
# DESCRIPTION: Asserts ci_pimcore_bundle_check.sh refuses bad --db-wait-seconds values.
# USAGE: bash tests/ci_pimcore_bundle_check_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_pimcore_bundle_check_test.sh
# ----------------------------------------------------
#
# 09 passed the old (( )) check with a printed "value too great for base" and
# the run went on with it. Every bad value must exit 2 before Docker is touched.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/ci_pimcore_bundle_check.sh"
failures=0
note()  { echo "[ci_pimcore_bundle_check_test] $*"; }
error() { echo "[ci_pimcore_bundle_check_test][ERROR] $*" >&2; failures=$((failures+1)); }

for bad in 09 0 -1 abc; do
  out="$(bash "$SCRIPT" --compose-file /nonexistent --db-wait-seconds "$bad" 2>&1)"
  rc=$?
  if [[ $rc -eq 2 && "$out" == *"Invalid value for --db-wait-seconds"* ]]; then
    note "--db-wait-seconds $bad refused (rc 2)"
  else
    error "--db-wait-seconds $bad: rc $rc, want 2 with 'Invalid value for --db-wait-seconds'; output: $out"
  fi
done

if [[ $failures -gt 0 ]]; then
  echo "[ci_pimcore_bundle_check_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_pimcore_bundle_check_test] OK"
