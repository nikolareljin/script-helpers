#!/usr/bin/env bash
# SCRIPT: command_reference_test.sh
# DESCRIPTION: docs/commands.md matches the script headers it is generated from.
# USAGE: bash tests/command_reference_test.sh
# ----------------------------------------------------
set -uo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
py="$(command -v python3 || command -v python || true)"
[[ -n "$py" ]] || { echo "[command_reference_test] SKIP: python not available"; exit 0; }
if "$py" "$root_dir/scripts/gen_command_reference.py" --check; then
  echo "[command_reference_test] PASS: docs/commands.md is up to date"
else
  echo "[command_reference_test][ERROR] run: python3 scripts/gen_command_reference.py" >&2
  exit 1
fi
rc=0; "$py" "$root_dir/scripts/gen_command_reference.py" --bogus 2>/dev/null || rc=$?
[[ $rc -eq 2 ]] || { echo "[command_reference_test][ERROR] bad argument gave $rc, not 2" >&2; exit 1; }
echo "[command_reference_test] PASS: a bad argument is exit 2"
