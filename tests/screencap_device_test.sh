#!/usr/bin/env bash
# SCRIPT: screencap_device_test.sh
# DESCRIPTION: tests/screencap_test.sh passes with a device attached, unless a real capture is requested.
# USAGE: bash tests/screencap_device_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/screencap_device_test.sh
# ----------------------------------------------------
# A stub adb on PATH reports one ready device and cannot capture. Before the
# fix, screencap_test.sh ran a real capture whenever a device showed up, so a
# developer with a phone plugged in got a red suite.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[screencap_device_test] $*"; }
error() { echo "[screencap_device_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/adb" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "devices" ]]; then
  printf 'List of devices attached\nSTUB0001\tdevice\n\n'
  exit 0
fi
exit 1
STUB
chmod +x "$tmp/bin/adb"

out="$(PATH="$tmp/bin:$PATH" SCREENCAP_TEST_REAL="" bash tests/screencap_test.sh 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]]; then note "device attached, no request: screencap_test.sh passes"
else error "device attached: screencap_test.sh exit $rc: $out"; fi
if grep -q 'set SCREENCAP_TEST_REAL=1' <<<"$out"; then note "and says how to run the real capture"
else error "no note about SCREENCAP_TEST_REAL: $out"; fi

# Requested: the real capture runs, and this stub cannot capture, so it fails.
out="$(PATH="$tmp/bin:$PATH" SCREENCAP_TEST_REAL=1 bash tests/screencap_test.sh 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'running a real capture' <<<"$out"; then note "SCREENCAP_TEST_REAL=1 runs the real capture"
else error "SCREENCAP_TEST_REAL=1: exit $rc: $out"; fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
