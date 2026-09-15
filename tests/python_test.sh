#!/usr/bin/env bash
# SCRIPT: python_test.sh
# DESCRIPTION: Tests for lib/python.sh -- python_pick_3 does not leak into the caller.
# USAGE: ./tests/python_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/python_test.sh
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[python_test] $*"; }
error() { echo "[python_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[python_test]   ok  $*"; }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging python

# A caller's own variable of the same name must survive the call, found or not.
candidate="mine"
python_pick_3 3 0 >/dev/null 2>&1 || true
if [[ "$candidate" == "mine" ]]; then ok "python_pick_3 leaves the caller's \$candidate alone"; else error "python_pick_3 overwrote \$candidate with [$candidate]"; fi
candidate="mine"
python_pick_3 99 0 >/dev/null 2>&1 || true
if [[ "$candidate" == "mine" ]]; then ok "also when nothing qualifies"; else error "python_pick_3 (no match) overwrote \$candidate with [$candidate]"; fi

if [[ $failures -eq 0 ]]; then
  note "all python tests passed"
  exit 0
fi
note "$failures failure(s)"
exit 1
