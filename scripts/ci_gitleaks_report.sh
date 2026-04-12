#!/usr/bin/env bash
# SCRIPT: ci_gitleaks_report.sh
# DESCRIPTION: Normalize and evaluate a Gitleaks SARIF report for CI workflows.
# USAGE: scripts/ci_gitleaks_report.sh --output <path> [--requested-output <path>] [--report-format sarif] [--fail-on-findings true|false]
# PARAMETERS:
#   --output <path>              Existing report path produced by Gitleaks.
#   --requested-output <path>    Target report path to copy/normalize to.
#   --report-format <fmt>        Report format (only sarif is supported).
#   --scan-path <path>           Requested scan path; logged when unsupported.
#   --config-path <path>         Requested config path; logged when unsupported.
#   --fail-on-findings <bool>    Exit non-zero when findings exist.
#   -h, --help                   Show this help message.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { show_help "${BASH_SOURCE[0]}"; }

output="results.sarif"
requested_output="results.sarif"
report_format="sarif"
scan_path="."
config_path=""
fail_on_findings="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --requested-output) requested_output="$2"; shift 2 ;;
    --report-format) report_format="$2"; shift 2 ;;
    --scan-path) scan_path="$2"; shift 2 ;;
    --config-path) config_path="$2"; shift 2 ;;
    --fail-on-findings) fail_on_findings="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$requested_output")"

if [[ "$scan_path" != "." ]]; then
  log_warn "gitleaks-action ignores scan_path; it scans git history by default."
fi
if [[ -n "$config_path" ]]; then
  log_warn "gitleaks-action ignores config_path; only .gitleaks.toml is auto-detected."
fi
if [[ "$report_format" != "sarif" ]]; then
  log_warn "gitleaks-action emits SARIF only; overriding report_format to sarif."
  report_format="sarif"
fi

if [[ -f "$output" && "$requested_output" != "$output" ]]; then
  cp "$output" "$requested_output"
fi

if [[ ! -s "$requested_output" ]]; then
  log_error "Selected Gitleaks report is missing or empty: $requested_output"
  exit 1
fi

REPORT_FORMAT="$report_format" OUTPUT="$requested_output" FAIL_ON_FINDINGS="$fail_on_findings" python3 - <<'PY'
import json
import os
import sys

report_format = os.environ["REPORT_FORMAT"]
output = os.environ["OUTPUT"]
fail_on_findings = os.environ["FAIL_ON_FINDINGS"] == "true"

count = 0
if report_format == "sarif":
    with open(output, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    runs = data.get("runs", [])
    for run in runs:
        results = run.get("results", [])
        if isinstance(results, list):
            count += len(results)
else:
    with open(output, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, list):
        count = len(data)
    elif isinstance(data, dict):
        for key in ("findings", "leaks", "results", "issues"):
            value = data.get(key)
            if isinstance(value, list):
                count += len(value)

if count > 0:
    print(f"Gitleaks findings detected: {count}")
    print("Tip: remove leaked secrets with Leak-Lock:")
    print("  https://marketplace.visualstudio.com/items?itemName=NikolaReljin.leak-lock")
    print("  https://open-vsx.org/extension/nikolareljin/leak-lock")
    if fail_on_findings:
        sys.exit(3)
else:
    print("No Gitleaks findings detected.")
PY
