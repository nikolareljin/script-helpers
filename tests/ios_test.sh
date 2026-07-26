#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/ios.sh"

OSTYPE=darwin
boot_calls=0
simctl_output=""
boot_status=0
devicectl_available=false

xcrun() {
  if [[ "$1 $2 ${3:-}" == "simctl list devices" ]]; then
    printf '%s' "$simctl_output"
    return 0
  fi
  if [[ "$1 $2" == "simctl boot" ]]; then
    boot_calls=$((boot_calls + 1))
    return "$boot_status"
  fi
  if [[ "$1 $2" == "devicectl --version" ]]; then
    "$devicectl_available"
    return
  fi
  return 1
}

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

ipa_file="$(mktemp)"
trap 'rm -f "$ipa_file"' EXIT
mv "$ipa_file" "${ipa_file}.ipa"
ipa_file="${ipa_file}.ipa"
if ios_install "device-id" "$ipa_file" 2>/dev/null; then
  echo "IPA installation succeeded without devicectl" >&2
  exit 1
fi

echo "ios tests passed"
