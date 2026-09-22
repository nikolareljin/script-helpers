#!/usr/bin/env bash
# SCRIPT: ci_wp_plugin_check_report_test.sh
# DESCRIPTION: Asserts ci_wp_plugin_check.sh reads wp plugin check's real output.
# USAGE: bash tests/ci_wp_plugin_check_report_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_wp_plugin_check_report_test.sh
# ----------------------------------------------------
#
# `wp plugin check --format=json` writes one section per file, not one
# document:
#
#   FILE: includes/foo.php
#   [{"line":33,"type":"WARNING","code":"..."}]
#
# The report block read the whole file with json.loads and so ended every run
# that had findings with "plugin-check.json is not valid JSON" and exit 5. The
# checks had run; their results were thrown away.
#
# The fixture is real output from a 12-file plugin, with the names replaced.
# Counted by hand from it: 8 errors, 50 warnings.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/ci_wp_plugin_check.sh"
FIXTURE="tests/fixtures/plugin-check-file-sections.json"
failures=0
note()  { echo "[ci_wp_plugin_check_report_test] $*"; }
error() { echo "[ci_wp_plugin_check_report_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Extracted from the script, not retyped, so editing the report block without
# editing this test cannot leave the test asserting old behaviour.
report_py="$tmp/report.py"
awk '/python3 - <<.PY.$/{flag=1;next} /^PY$/{flag=0} flag' "$SCRIPT" > "$report_py"
if [[ ! -s "$report_py" ]]; then
  error "could not extract the report block from $SCRIPT; the test would assert nothing"
  echo "[ci_wp_plugin_check_report_test] FAILED ($failures)" >&2
  exit 1
fi

run_report() {   # <out_dir> <plugin_check_available> -> prints output, sets rc
  OUT_DIR="$1" PLUGIN_CHECK_AVAILABLE="$2" python3 "$report_py" 2>&1
}

# 1) The real format: parsed, and counted by severity rather than by entry.
case_dir="$tmp/sections"; mkdir -p "$case_dir"
cp "$FIXTURE" "$case_dir/plugin-check.json"
out="$(run_report "$case_dir" true)"; rc=$?
if [[ "$out" == *"not valid JSON"* ]]; then
  error "the real output is still reported as invalid JSON:"
  sed 's/^/    /' <<<"$out" >&2
elif [[ $rc -ne 4 ]]; then
  error "exit $rc on a fixture with errors, expected 4"
elif [[ "$out" != *"8 error(s)"* || "$out" != *"50 warning(s)"* ]]; then
  error "counts wrong; expected 8 errors and 50 warnings, got: $out"
else
  note "the FILE-sectioned format is parsed: $out"
fi

# 2) Warnings alone must not fail the build. Counting every entry as an error
#    is what the whole-document fallback used to do.
case_dir="$tmp/warnings"; mkdir -p "$case_dir"
cat > "$case_dir/plugin-check.json" <<'JSON'
FILE: includes/a.php
[{"line":1,"column":1,"type":"WARNING","code":"X","message":"m","docs":""}]
JSON
out="$(run_report "$case_dir" true)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"0 error(s), 1 warning(s)"* ]]; then
  note "warnings are reported and do not fail: $out"
else
  error "a warning-only report exited $rc: $out"
fi

# 3) A single JSON document still works, for other wp-cli builds.
case_dir="$tmp/document"; mkdir -p "$case_dir"
printf '{"errors": 2, "warnings": 1}\n' > "$case_dir/plugin-check.json"
out="$(run_report "$case_dir" true)"; rc=$?
if [[ $rc -eq 4 && "$out" == *"2 error(s), 1 warning(s)"* ]]; then
  note "a whole-document report still parses: $out"
else
  error "whole-document report exited $rc: $out"
fi

# 4) Genuinely broken input must still be a parse failure, not a silent pass.
#    A parser that swallows everything is worse than the bug it replaced.
case_dir="$tmp/broken"; mkdir -p "$case_dir"
printf 'FILE: includes/a.php\n[{"line":1,\n' > "$case_dir/plugin-check.json"
out="$(run_report "$case_dir" true)"; rc=$?
if [[ $rc -eq 5 ]]; then
  note "malformed input is still a parse failure"
else
  error "malformed input exited $rc, expected 5: $out"
fi

# 5) A missing file when the checker was available is still an error.
case_dir="$tmp/missing"; mkdir -p "$case_dir"
out="$(run_report "$case_dir" true)"; rc=$?
if [[ $rc -eq 5 ]]; then
  note "a missing report with the checker available is still an error"
else
  error "missing report exited $rc, expected 5: $out"
fi

if [[ $failures -gt 0 ]]; then
  echo "[ci_wp_plugin_check_report_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_wp_plugin_check_report_test] OK"
