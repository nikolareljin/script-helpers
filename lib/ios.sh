#!/usr/bin/env bash
# iOS device / simulator utilities — a general toolkit for inspecting iOS
# devices and simulators and installing builds, the iOS counterpart to the
# `adb` module.
#
# macOS ONLY: every function requires Apple's command-line tools (`xcrun`,
# `simctl`, `xctrace`), which exist only on macOS with Xcode. On other hosts
# each function no-ops (returns non-zero / prints nothing) so callers degrade
# cleanly — mirror the way the `adb` module behaves when `adb` is missing.

# --- discovery -------------------------------------------------------------

# Usage: ios_available; returns 0 only on macOS with Xcode's xcrun on PATH.
ios_available() {
  [[ "$OSTYPE" == darwin* ]] || return 1
  command -v xcrun >/dev/null 2>&1
}

# Usage: ios_list_devices; prints attached physical iOS devices, one per line
# ("<name> (<udid>)"). Prints nothing when none are attached.
ios_list_devices() {
  ios_available || return 1
  # xctrace enumerates real + simulated devices; keep only physical iPhone/iPad
  # entries (they carry a UDID and are not marked "Simulator").
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{d=1;next} /^== /{d=0} d && /\(([0-9A-Fa-f-]{8,})\)/ && !/Simulator/ {print}'
}

# Usage: ios_list_simulators; prints available simulators ("<name> (<udid>) <state>").
ios_list_simulators() {
  ios_available || return 1
  xcrun simctl list devices available 2>/dev/null \
    | awk '/\(([0-9A-Fa-f-]{8,})\)/ {sub(/^[[:space:]]+/,""); print}'
}

# Usage: ios_booted_simulators; prints the udid of each currently booted simulator.
ios_booted_simulators() {
  ios_available || return 1
  xcrun simctl list devices booted 2>/dev/null \
    | awk 'match($0, /\([0-9A-Fa-f-]{8,}\)/) { print substr($0, RSTART + 1, RLENGTH - 2) }'
}

# --- simulator control -----------------------------------------------------

# Usage: ios_boot_simulator <udid|name>; boots a simulator (no-op if already booted).
ios_boot_simulator() {
  ios_available || return 1
  local id="${1:-}"
  [[ -n "$id" ]] || return 1

  # Avoid masking genuine simctl failures while keeping an already-booted
  # simulator idempotent.
  if xcrun simctl list devices booted 2>/dev/null \
    | awk -v id="$id" 'index($0, id) { found=1 } END { exit !found }'; then
    return 0
  fi
  xcrun simctl boot "$id"
}

# Usage: ios_shutdown_simulators; shuts down all booted simulators.
ios_shutdown_simulators() {
  ios_available || return 1
  xcrun simctl shutdown all 2>/dev/null || true
}

# --- install / launch ------------------------------------------------------

# Usage: ios_install <udid> <path.app|path.ipa>; installs a build onto a booted
# simulator (.app) or an attached device (.ipa, via devicectl when available).
ios_install() {
  ios_available || return 1
  local id="$1" artifact="$2"
  [[ -n "$id" && -e "$artifact" ]] || return 1
  if [[ "$artifact" == *.ipa ]] && xcrun devicectl --version >/dev/null 2>&1; then
    xcrun devicectl device install app --device "$id" "$artifact"
  else
    xcrun simctl install "$id" "$artifact"
  fi
}

# Usage: ios_launch <udid> <bundle_id>; launches an installed app on a simulator.
ios_launch() {
  ios_available || return 1
  local id="$1" bundle_id="$2"
  [[ -n "$id" && -n "$bundle_id" ]] || return 1
  xcrun simctl launch "$id" "$bundle_id"
}

# --- build -----------------------------------------------------------------

# Usage: ios_build_release <flutter_project_dir> [export_options_plist]; builds
# a signed IPA when a plist is provided, or an unsigned iOS app otherwise.
ios_build_release() {
  ios_available || { echo "ios_build_release: requires macOS with Xcode" >&2; return 1; }
  command -v flutter >/dev/null 2>&1 || { echo "ios_build_release: flutter not on PATH" >&2; return 1; }
  local dir="${1:-.}" plist="${2:-}"
  ( cd "$dir" && flutter pub get && \
    if [[ -n "$plist" ]]; then
      [[ -f "$plist" ]] || { echo "ios_build_release: export options plist not found: $plist" >&2; exit 1; }
      flutter build ipa --release --export-options-plist "$plist"
    else
      flutter build ios --release --no-codesign
    fi )
}
