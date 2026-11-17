#!/usr/bin/env bash
# SCRIPT: foxguard_parse_test.sh
# DESCRIPTION: Fails when foxguard cannot parse a shell or Python file in the repository.
# USAGE: ./tests/foxguard_parse_test.sh
# PARAMETERS: No required parameters. FOXGUARD_REQUIRE=1 turns a missing pinned
#             foxguard into a failure instead of a skip.
# EXAMPLE: bash tests/foxguard_parse_test.sh
# ----------------------------------------------------
# A diff gate that runs foxguard refuses a changed file foxguard skips with
# "(parse error)", so every vendored copy of such a file fails that gate.
# Templates with @PLACEHOLDER@ text (templates/) are not source and are ignored.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
note() { echo "[foxguard_parse_test] $*"; }

# The pinned foxguard only: another version parses other files, so its answer
# says nothing about what the pre-push hook will refuse.
fox="$(source "$root_dir/lib/foxguard.sh" >/dev/null 2>&1 && foxguard_bin 2>/dev/null)" || fox=""
if [[ -z "$fox" ]]; then
  if [[ "${FOXGUARD_REQUIRE:-0}" == 1 ]]; then
    note "FAIL: the pinned foxguard is not installed and FOXGUARD_REQUIRE=1" >&2
    exit 1
  fi
  note "SKIP: the pinned foxguard is not installed; parse check not run"
  exit 0
fi
note "using $fox ($("$fox" --version 2>&1 | sed -n 1p))"

out="$(cd "$root_dir" && "$fox" . 2>&1)" || true
skipped="$(printf '%s\n' "$out" | grep -oE 'skipping [^ ]+ \(parse error\)' \
  | sed -E 's/^skipping (.*) \(parse error\)$/\1/' \
  | grep -E '\.(sh|bash|py)$' | grep -v '^\./templates/' | sort || true)"
if [[ -n "$skipped" ]]; then
  note "FAIL: foxguard cannot parse these files:" >&2
  printf '%s\n' "$skipped" | sed 's/^/  /' >&2
  exit 1
fi
note "PASS: foxguard parses every shell and Python file"
