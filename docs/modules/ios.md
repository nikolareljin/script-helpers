# ios

A general toolkit for **inspecting iOS devices and simulators and installing
builds** — the iOS counterpart to the [`adb`](./adb.md) module. List attached
devices and available simulators, boot/shut down simulators, install `.app`/`.ipa`
artifacts, launch apps, and build a release app or IPA with Flutter.

**macOS only.** Every function requires Apple's command-line tools (`xcrun`,
`simctl`, `xctrace`), which exist only on macOS with Xcode installed. On any
other host each function returns non-zero without stdout output, so callers
degrade cleanly. Prerequisite errors may still be written to stderr.

Provided as Bash (`lib/ios.sh`). A CI/build runner lives at `scripts/ci_ios.sh`.

CI runner
---------

Run `scripts/ci_ios.sh [--workdir <path>] [--skip-analyze] [--skip-test]
[--skip-build] [--export-plist <path>]` on a macOS host with Xcode and Flutter.
The export plist path is relative to `--workdir`. The runner exits `3` when the
Apple toolchain is unavailable, `1` for invalid arguments or a missing Flutter
executable, and otherwise propagates failures from Flutter build/test commands.

Requirements
------------

- macOS with Xcode and the command-line tools (`xcrun`, `simctl`).
- `flutter` on `PATH` for `ios_build_release`.

Functions
---------

Discovery
- `ios_available` — 0 only on macOS with `xcrun` on `PATH`.
- `ios_list_devices` — attached physical iOS devices, one per line (`<name> (<udid>)`).
- `ios_list_simulators` — available simulators (`<name> (<udid>) <state>`).
- `ios_booted_simulators` — udids of currently booted simulators.

Simulator control
- `ios_boot_simulator <udid|name>` — boot a simulator (no-op if already booted).
- `ios_shutdown_simulators` — shut down all booted simulators.

Install / launch
- `ios_install <udid> <path.app|path.ipa>` — install onto a booted simulator
  (`.app`) or an attached device (`.ipa`, via `devicectl` when available).
- `ios_launch <udid> <bundle_id>` — launch an installed app on a simulator.

Build
- `ios_build_release <flutter_project_dir> [export_options_plist]` — build a
  Flutter release. With an export-options plist (resolved relative to the
  project directory), it produces a signed IPA; without one, it produces an
  unsigned iOS app build rather than an IPA.

Example
-------

```bash
source helpers.sh
shlib_import ios

ios_available || { echo "not on macOS"; exit 0; }
ios_list_simulators
ios_boot_simulator "iPhone 15"
ios_build_release ./mobile ios/ExportOptions.plist
```
