#!/usr/bin/env bash
# SCRIPT: ios_test.sh
# DESCRIPTION: Regression tests for the iOS helper module.
# USAGE: ./tests/ios_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ios_test.sh
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=/dev/null
source ./helpers.sh
shlib_import ios

OSTYPE=darwin
boot_calls=0
simctl_output=""
boot_status=0
shutdown_status=0
devicectl_available=false
xctrace_output=""

xcrun() {
  if [[ "$1 $2 ${3:-}" == "xctrace list devices" ]]; then
    printf '%s' "$xctrace_output"
    return 0
  fi
  if [[ "$1 $2 ${3:-}" == "simctl list devices" ]]; then
    printf '%s' "$simctl_output"
    return 0
  fi
  if [[ "$1 $2" == "simctl boot" ]]; then
    boot_calls=$((boot_calls + 1))
    return "$boot_status"
  fi
  if [[ "$1 $2 ${3:-}" == "simctl shutdown all" ]]; then
    return "$shutdown_status"
  fi
  if [[ "$1 $2" == "devicectl --version" ]]; then
    "$devicectl_available"
    return
  fi
  return 1
}

xctrace_output='== Devices ==
Nikos iPhone (18.5) (00008110-001234567890001E)
Office iPad (17.7.8) (00008101-00ABCDEF1234001E)
Apple Watch (11.5) (00008120-00FEDCBA4321001E)
== Simulators ==
iPhone 15 Simulator (18.5) (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)'
output="$(ios_list_devices)"
expected='Nikos iPhone (00008110-001234567890001E)
Office iPad (00008101-00ABCDEF1234001E)'
[[ "$output" == "$expected" ]] || {
  echo "unexpected physical device list: $output" >&2
  exit 1
}

if ios_launch "simulator-id"; then
  echo "ios_launch accepted a missing bundle id" >&2
  exit 1
fi

output="$(ios_booted_simulators)"
[[ -z "$output" ]] || { echo "expected no booted simulator output" >&2; exit 1; }

simctl_output='    iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Booted)'
output="$(ios_booted_simulators)"
[[ "$output" == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" ]] || {
  echo "unexpected booted simulator UDID: $output" >&2
  exit 1
}

ios_boot_simulator "iPhone 15"
[[ "$boot_calls" -eq 0 ]] || { echo "already-booted simulator was booted again" >&2; exit 1; }

boot_status=0
ios_boot_simulator "iPhone 15 Pro Max"
[[ "$boot_calls" -eq 1 ]] || { echo "partial simulator name incorrectly matched" >&2; exit 1; }

simctl_output=""
boot_status=7
if ios_boot_simulator "missing-simulator"; then
  echo "simctl boot failure was masked" >&2
  exit 1
fi
[[ "$boot_calls" -eq 2 ]] || { echo "expected two simctl boot attempts" >&2; exit 1; }

shutdown_status=9
if ios_shutdown_simulators 2>/dev/null; then
  echo "simctl shutdown failure was masked" >&2
  exit 1
fi

ipa_dir="$(mktemp -d)"
trap 'rm -rf "$ipa_dir"' EXIT
ipa_file="$ipa_dir/app.ipa"
: > "$ipa_file"
if ios_install "device-id" "$ipa_file" 2>/dev/null; then
  echo "IPA installation succeeded without devicectl" >&2
  exit 1
fi

# ios_list_simulators keeps only lines carrying a UDID and strips the leading
# indentation from `simctl list devices available` (headers are dropped).
simctl_output='== Devices ==
-- iOS 18.5 --
    iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Shutdown)
    iPhone 15 Pro (11111111-2222-3333-4444-555555555555) (Booted)
-- Unavailable --'
output="$(ios_list_simulators)"
expected='iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Shutdown)
iPhone 15 Pro (11111111-2222-3333-4444-555555555555) (Booted)'
[[ "$output" == "$expected" ]] || {
  echo "unexpected simulator list: $output" >&2
  exit 1
}

echo "ios tests passed"
