#!/usr/bin/env bash
# adb / Android device utilities
#
# Helpers for working with USB-connected Android devices via the Android Debug
# Bridge (`adb`). All functions are multi-device safe — they target a specific
# device with `adb -s <serial>` rather than a bare `adb shell`, which errors with
# "more than one device" once a second device is attached. Every function is a
# no-op / non-zero return when `adb` is missing, so callers can degrade cleanly.

# Usage: adb_available; returns 0 if the adb CLI is on PATH.
adb_available() {
  command -v adb >/dev/null 2>&1
}

# Usage: adb_ready_serials; prints the serial of each *ready* device, one per
# line, skipping the header and any offline/unauthorized entries (the state
# column must be exactly "device"). Prints nothing when none are ready.
adb_ready_serials() {
  adb_available || return 1
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}'
}

# Usage: adb_device_ip <serial> [iface=wlan0]; prints the device's IPv4 address
# on the interface (default wlan0 / Wi-Fi). Returns non-zero with no output when
# adb is missing, the serial is empty, or the interface has no address (e.g.
# Wi-Fi off). Pass e.g. "rmnet_data0" for a cellular interface.
adb_device_ip() {
  local serial="$1" iface="${2:-wlan0}" ip=""
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  ip="$(adb -s "$serial" shell ip -f inet addr show "$iface" 2>/dev/null \
        | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -n1)"
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip"
}

# Usage: adb_device_model <serial>; prints ro.product.model (CR/LF trimmed).
adb_device_model() {
  local serial="$1"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n'
}

# Usage: adb_list_devices [iface=wlan0]; prints a "SERIAL  MODEL  IP" table for
# every ready device. Works with any number of devices attached. Returns 1 when
# adb is missing; 0 (and an empty table) when no devices are ready.
adb_list_devices() {
  local iface="${1:-wlan0}" s ip model
  local -a serials=()
  if ! adb_available; then
    log_warn "adb not found. Install the Android platform-tools and put adb on PATH."
    return 1
  fi
  mapfile -t serials < <(adb_ready_serials)
  if [[ ${#serials[@]} -eq 0 ]]; then
    log_warn "No ready devices. Check the USB cable and 'adb devices' — authorize the on-phone prompt if it shows 'unauthorized'."
    return 0
  fi
  printf '%-22s %-22s %s\n' "SERIAL" "MODEL" "IP ($iface)"
  for s in "${serials[@]}"; do
    ip="$(adb_device_ip "$s" "$iface" || true)"
    model="$(adb_device_model "$s" || true)"
    printf '%-22s %-22s %s\n' "$s" "${model:-?}" "${ip:-<no $iface / Wi-Fi off>}"
  done
}
