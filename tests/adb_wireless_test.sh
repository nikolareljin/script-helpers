#!/usr/bin/env bash
# SCRIPT: adb_wireless_test.sh
# DESCRIPTION: Tests for lib/adb.sh wireless helpers and scripts/check_no_private_ips.sh.
# USAGE: ./tests/adb_wireless_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/adb_wireless_test.sh
# ----------------------------------------------------
#
# `adb` is stubbed as a shell function, so these run with no device attached.
#
# The behaviours worth pinning without hardware are the ones where the obvious
# implementation is wrong: `adb connect` reporting success on a bare TCP
# handshake, an "offline" entry counting as attached, and an env-file writer
# that discards the keys it was not asked about.
# ----------------------------------------------------
# The `adb` stubs below are called only indirectly, by the library functions
# under test, so shellcheck reads every branch of them as unreachable. Must sit
# above the first command to apply file-wide.
# shellcheck disable=SC2317
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[adb_wireless_test] $*"; }
error() { echo "[adb_wireless_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[adb_wireless_test]   ok  $*"; }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import adb

# --- address from the environment -------------------------------------------
export ANDROID_DEVICE_IP="203.0.113.10"
export ANDROID_DEVICE_PORT="5555"
if [[ "$(adb_wireless_addr)" == "203.0.113.10:5555" ]]; then
  ok "adb_wireless_addr joins ip and port"
else
  error "adb_wireless_addr returned '$(adb_wireless_addr)'"
fi

unset ANDROID_DEVICE_PORT
if [[ "$(adb_wireless_addr)" == "203.0.113.10:5555" ]]; then
  ok "port defaults to 5555"
else
  error "port default wrong: '$(adb_wireless_addr)'"
fi

unset ANDROID_DEVICE_IP
if adb_wireless_addr >/dev/null 2>&1; then
  error "adb_wireless_addr must fail with no ANDROID_DEVICE_IP"
else
  ok "no address configured returns non-zero"
fi

# --- attached-ness reads the STATE column, not just the name ----------------
export ANDROID_DEVICE_IP="203.0.113.10"
export ANDROID_DEVICE_PORT="5555"

adb() {
  case "${1:-}" in
    devices) printf 'List of devices attached\n203.0.113.10:5555\tdevice\n' ;;
    *) return 0 ;;
  esac
}
if adb_wireless_attached "203.0.113.10:5555"; then
  ok "a ready device counts as attached"
else
  error "ready device not detected"
fi

adb() {
  case "${1:-}" in
    devices) printf 'List of devices attached\n203.0.113.10:5555\toffline\n' ;;
    *) return 0 ;;
  esac
}
if adb_wireless_attached "203.0.113.10:5555"; then
  error "an OFFLINE device must not count as attached"
else
  ok "an offline device does not count as attached"
fi

adb() {
  case "${1:-}" in
    devices) printf 'List of devices attached\n203.0.113.10:5555\tunauthorized\n' ;;
    *) return 0 ;;
  esac
}
if adb_wireless_attached "203.0.113.10:5555"; then
  error "an UNAUTHORIZED device must not count as attached"
else
  ok "an unauthorized device does not count as attached"
fi

# --- connect confirms against `adb devices`, it does not trust `adb connect` -
#
# This is the case that matters. `adb connect` exits 0 on a bare TCP handshake,
# so a stale address pointing at anything listening reports success while no
# device is usable.
adb() {
  case "${1:-}" in
    connect) return 0 ;;                                    # claims success...
    devices) printf 'List of devices attached\n' ;;         # ...but nothing attached
    *) return 0 ;;
  esac
}
if adb_wireless_connect "203.0.113.10:5555"; then
  error "connect must not trust adb connect's exit status"
else
  ok "a lying 'adb connect' is caught by re-checking adb devices"
fi

adb() {
  case "${1:-}" in
    connect) return 0 ;;
    devices) printf 'List of devices attached\n203.0.113.10:5555\tdevice\n' ;;
    *) return 0 ;;
  esac
}
if adb_wireless_connect "203.0.113.10:5555"; then
  ok "connect succeeds when the device really is attached"
else
  error "connect failed on an attached device"
fi

# --- env writing upserts and preserves ---------------------------------------
envfile="$(mktemp)"
cat >"$envfile" <<'EOF'
# a comment
SOME_OTHER_KEY=keep-me
ANDROID_DEVICE_IP=198.51.100.1
EOF

adb_wireless_write_env "$envfile" "203.0.113.77" "41234"

if grep -q '^ANDROID_DEVICE_IP=203.0.113.77$' "$envfile"; then
  ok "existing ANDROID_DEVICE_IP is replaced, not duplicated"
else
  error "ip not replaced: $(cat "$envfile")"
fi
if [[ "$(grep -c '^ANDROID_DEVICE_IP=' "$envfile")" == "1" ]]; then
  ok "exactly one ANDROID_DEVICE_IP line"
else
  error "duplicate ip lines: $(cat "$envfile")"
fi
if grep -q '^ANDROID_DEVICE_PORT=41234$' "$envfile"; then
  ok "a missing ANDROID_DEVICE_PORT is appended"
else
  error "port not appended: $(cat "$envfile")"
fi
if grep -q '^SOME_OTHER_KEY=keep-me$' "$envfile" && grep -q '^# a comment$' "$envfile"; then
  ok "unrelated keys and comments survive"
else
  error "clobbered unrelated content: $(cat "$envfile")"
fi

missing="$(mktemp -u)"
adb_wireless_write_env "$missing" "203.0.113.9"
if grep -q '^ANDROID_DEVICE_IP=203.0.113.9$' "$missing" \
  && grep -q '^ANDROID_DEVICE_PORT=5555$' "$missing"; then
  ok "a missing env file is created with both keys"
else
  error "file not created properly: $(cat "$missing" 2>/dev/null)"
fi
rm -f "$envfile" "$missing"

# --- the private-IP gate ------------------------------------------------------
gate="./scripts/check_no_private_ips.sh"
fixture="$(mktemp -d)"

# Assembled from octets so no private-range literal appears in this tracked
# file. The gate is deliberately literal-blind — it cannot tell a real home
# address from a synthetic one — so building the fixture is the only way to keep
# tracked files clean AND still exercise the detector.
for quad in "10 0 0 1" "192 168 1 20" "172 16 5 5"; do
  # shellcheck disable=SC2086
  set -- $quad
  printf 'host %d.%d.%d.%d\n' "$1" "$2" "$3" "$4" >>"$fixture/bad.conf"
done
if bash "$gate" --path "$fixture" >/dev/null 2>&1; then
  error "gate passed a file containing private-range literals"
else
  ok "gate fails on 10/8, 192.168/16 and 172.16/12"
fi

clean="$(mktemp -d)"
printf 'docs use 203.0.113.10 and 198.51.100.4; flutter 3.44.7; sdk 10.0.2\n' >"$clean/ok.md"
printf '127.0.0.1 localhost\nphone.local\n' >>"$clean/ok.md"
if bash "$gate" --path "$clean" >/dev/null 2>&1; then
  ok "gate allows RFC 5737, loopback, .local and version strings"
else
  error "false positive: $(bash "$gate" --path "$clean" 2>&1)"
fi
rm -rf "$fixture" "$clean"

if (( failures )); then
  note "FAILED ($failures)"
  exit 1
fi
note "all tests passed"
