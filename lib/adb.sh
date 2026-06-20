#!/usr/bin/env bash
# adb / Android device utilities — a general toolkit for inspecting and debugging
# Android devices over USB via the Android Debug Bridge (`adb`).
#
# Everything is MULTI-DEVICE SAFE: functions target a device with
# `adb -s <serial>` rather than a bare `adb shell`, which errors with "more than
# one device" once a second device is attached. All functions return non-zero /
# no-op when `adb` is missing, so callers degrade cleanly.

# --- discovery -------------------------------------------------------------

# Usage: adb_available; returns 0 if the adb CLI is on PATH.
adb_available() { command -v adb >/dev/null 2>&1; }

# Usage: adb_ready_serials; prints the serial of each *ready* device, one per
# line, skipping the header and any offline/unauthorized entries (state column
# must be exactly "device"). Prints nothing when none are ready.
adb_ready_serials() {
  adb_available || return 1
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}'
}

# --- device info -----------------------------------------------------------

# Usage: adb_getprop <serial> <prop>; prints a system property (CR/LF trimmed).
adb_getprop() {
  local serial="$1" prop="$2"
  adb_available || return 1
  [[ -n "$serial" && -n "$prop" ]] || return 1
  adb -s "$serial" shell getprop "$prop" 2>/dev/null | tr -d '\r\n'
}

# Usage: adb_device_model <serial>; prints ro.product.model (e.g. "Pixel 5").
adb_device_model() { adb_getprop "$1" ro.product.model; }

# Usage: adb_android_version <serial>; prints the Android OS release (e.g. "9").
adb_android_version() { adb_getprop "$1" ro.build.version.release; }

# Usage: adb_device_api <serial>; prints the supported API / SDK level (e.g. 28).
adb_device_api() { adb_getprop "$1" ro.build.version.sdk; }

# Usage: adb_device_ip <serial> [iface=wlan0]; prints the device's IPv4 on the
# interface (default wlan0 / Wi-Fi; pass e.g. rmnet_data0 for cellular). Returns
# non-zero with no output when adb is missing or the interface has no address.
adb_device_ip() {
  local serial="$1" iface="${2:-wlan0}" ip=""
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  ip="$(adb -s "$serial" shell ip -f inet addr show "$iface" 2>/dev/null \
        | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -n1)"
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip"
}

# Usage: adb_list_devices [iface=wlan0]; prints a table of every ready device
# with its model, Android OS version, API level and IP. Works with any number of
# devices attached. Returns 1 when adb is missing; 0 (empty table) when none.
adb_list_devices() {
  local iface="${1:-wlan0}" s
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
  printf '%-20s %-18s %-9s %-5s %s\n' "SERIAL" "MODEL" "ANDROID" "API" "IP ($iface)"
  for s in "${serials[@]}"; do
    printf '%-20s %-18s %-9s %-5s %s\n' \
      "$s" \
      "$(adb_device_model "$s" 2>/dev/null || echo '?')" \
      "$(adb_android_version "$s" 2>/dev/null || echo '?')" \
      "$(adb_device_api "$s" 2>/dev/null || echo '?')" \
      "$(adb_device_ip "$s" "$iface" 2>/dev/null || echo '-')"
  done
}

# --- shell / debugging -----------------------------------------------------

# Usage: adb_shell <serial> <command...>; run a shell command on a device.
adb_shell() {
  local serial="$1"; shift || true   # drop the serial; the rest is the command
  adb_available || return 1
  [[ -n "$serial" && $# -gt 0 ]] || { log_error "adb_shell: need <serial> <command...>"; return 2; }
  adb -s "$serial" shell "$@"
}

# Usage: adb_logcat <serial> [regex]; dump the current logcat buffer (-d),
# optionally filtered to lines matching <regex>. Non-streaming (scriptable); for
# a live tail use `adb -s <serial> logcat` directly.
adb_logcat() {
  local serial="$1" regex="${2:-}"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  if [[ -n "$regex" ]]; then
    # `--` so a regex starting with '-' isn't taken as a grep option.
    adb -s "$serial" logcat -d 2>/dev/null | grep -E -- "$regex"
  else
    adb -s "$serial" logcat -d 2>/dev/null
  fi
}

# Usage: adb_clear_logcat <serial>; clears the device's logcat buffer.
adb_clear_logcat() {
  local serial="$1"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  adb -s "$serial" logcat -c 2>/dev/null
}

# --- file transfer ---------------------------------------------------------

# Usage: adb_push <serial> <local> <remote>; copy a local file/dir TO the device.
adb_push() {
  local serial="$1" local_path="$2" remote_path="$3"
  adb_available || return 1
  [[ -n "$serial" && -n "$local_path" && -n "$remote_path" ]] \
    || { log_error "adb_push: need <serial> <local> <remote>"; return 2; }
  [[ -e "$local_path" ]] || { log_error "adb_push: local path not found: $local_path"; return 2; }
  log_info "push $local_path -> $serial:$remote_path"
  adb -s "$serial" push "$local_path" "$remote_path"
}

# Usage: adb_pull <serial> <remote> [local=.]; copy a file/dir FROM the device.
adb_pull() {
  local serial="$1" remote_path="$2" local_path="${3:-.}"
  adb_available || return 1
  [[ -n "$serial" && -n "$remote_path" ]] \
    || { log_error "adb_pull: need <serial> <remote> [local]"; return 2; }
  log_info "pull $serial:$remote_path -> $local_path"
  adb -s "$serial" pull "$remote_path" "$local_path"
}

# --- apps ------------------------------------------------------------------

# Usage: adb_install <serial> <apk> [extra adb install args...]; (re)install an
# APK to one device (-r keeps app data). Returns adb's exit status.
adb_install() {
  local serial="$1" apk="$2"; shift 2 || true   # drop serial+apk; rest = adb flags
  adb_available || return 1
  [[ -n "$serial" && -n "$apk" ]] || { log_error "adb_install: need <serial> <apk>"; return 2; }
  [[ -f "$apk" ]] || { log_error "adb_install: APK not found: $apk"; return 2; }
  log_info "install $apk -> $serial"
  adb -s "$serial" install -r "$@" "$apk"
}

# Usage: adb_install_all <apk> [extra adb install args...]; install the APK to
# every ready device. Continues past failures; returns non-zero if any failed.
adb_install_all() {
  local apk="$1"; shift || true   # drop the apk; rest = extra adb install flags
  local s rc=0 ok=0 fail=0
  local -a serials=()
  adb_available || return 1
  [[ -n "$apk" && -f "$apk" ]] || { log_error "adb_install_all: APK not found: ${apk:-<none>}"; return 2; }
  mapfile -t serials < <(adb_ready_serials)
  [[ ${#serials[@]} -gt 0 ]] || { log_warn "No ready devices to install to."; return 0; }
  for s in "${serials[@]}"; do
    if adb_install "$s" "$apk" "$@" >/dev/null 2>&1; then
      log_info "installed on $s"; ok=$((ok + 1))
    else
      log_warn "install FAILED on $s"; fail=$((fail + 1)); rc=1
    fi
  done
  log_info "install summary: $ok ok, $fail failed of ${#serials[@]} device(s)"
  return $rc
}

# Usage: adb_uninstall <serial> <package>; uninstall an app package.
adb_uninstall() {
  local serial="$1" pkg="$2"
  adb_available || return 1
  [[ -n "$serial" && -n "$pkg" ]] || { log_error "adb_uninstall: need <serial> <package>"; return 2; }
  adb -s "$serial" uninstall "$pkg"
}

# --- status ----------------------------------------------------------------

# Usage: adb_battery_level <serial>; prints battery charge percent (0-100).
adb_battery_level() {
  local serial="$1"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  adb -s "$serial" shell dumpsys battery 2>/dev/null \
    | awk -F': *' '/ level:/{print $2; exit}' | tr -d '\r'
}

# Usage: adb_screen_on <serial>; returns 0 if the display is on, 1 if off, 2 if
# it can't be determined (varies across Android versions).
adb_screen_on() {
  local serial="$1" out
  adb_available || return 2
  [[ -n "$serial" ]] || return 2
  out="$(adb -s "$serial" shell dumpsys power 2>/dev/null | tr -d '\r')"
  if grep -qE 'Display Power: state=ON|mScreenOn=true|mWakefulness=Awake' <<<"$out"; then
    return 0
  elif grep -qE 'Display Power: state=OFF|mScreenOn=false|mWakefulness=(Asleep|Dozing)' <<<"$out"; then
    return 1
  fi
  return 2
}

# Usage: adb_device_status <serial>; print a human-readable status block (model,
# Android + API, battery, screen, Wi-Fi IP) for one device.
adb_device_status() {
  local serial="$1" screen="unknown"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  if adb_screen_on "$serial"; then screen="on"; elif [[ $? -eq 1 ]]; then screen="off"; fi
  printf 'serial:  %s\n' "$serial"
  printf 'model:   %s\n' "$(adb_device_model "$serial")"
  printf 'android: %s (API %s)\n' "$(adb_android_version "$serial")" "$(adb_device_api "$serial")"
  printf 'battery: %s%%\n' "$(adb_battery_level "$serial")"
  printf 'screen:  %s\n' "$screen"
  printf 'wifi_ip: %s\n' "$(adb_device_ip "$serial" 2>/dev/null || echo '-')"
}
