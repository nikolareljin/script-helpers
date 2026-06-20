# adb

A general toolkit for **inspecting and debugging Android devices** over USB via
the Android Debug Bridge (`adb`): list devices with their OS/API/IP, install
APKs, copy files to/from a device, run shell commands, and read logcat/status.

Everything is **multi-device safe** — functions target a device with
`adb -s <serial>` rather than a bare `adb shell`, which errors with *more than one
device* once a second device is attached. Every function returns non-zero / no-ops
when `adb` is missing, so callers degrade cleanly.

Available in both Bash (`lib/adb.sh`) and PowerShell (`ps/lib/adb.ps1`) with the
same function names. A ready-to-use CLI wrapper lives at `scripts/adb_tool.sh`.

Requirements
------------

- `adb` (Android platform-tools) on `PATH`.

Functions
---------

Discovery
- `adb_available` — 0 if `adb` is on `PATH`.
- `adb_ready_serials` — serials of *ready* devices, one per line (skips header +
  offline/unauthorized).

Device info
- `adb_getprop <serial> <prop>` — read a system property.
- `adb_device_model <serial>` — `ro.product.model`.
- `adb_android_version <serial>` — Android OS release (e.g. `9`).
- `adb_device_api <serial>` — supported API / SDK level (e.g. `28`).
- `adb_device_ip <serial> [iface=wlan0]` — IPv4 on an interface (Wi-Fi by default;
  pass e.g. `rmnet_data0` for cellular).
- `adb_list_devices [iface=wlan0]` — a `SERIAL  MODEL  ANDROID  API  IP` table for
  every ready device.

Shell / debugging
- `adb_shell <serial> <cmd...>` — run a shell command on a device.
- `adb_logcat <serial> [regex]` — dump the logcat buffer (`-d`), optionally
  filtered to lines matching `regex`. For a live tail use `adb -s <serial> logcat`.
- `adb_clear_logcat <serial>` — clear the logcat buffer.

File transfer
- `adb_push <serial> <local> <remote>` — copy a file/dir **to** the device.
- `adb_pull <serial> <remote> [local=.]` — copy a file/dir **from** the device.

Apps
- `adb_install <serial> <apk> [adb install args...]` — (re)install an APK (`-r`).
- `adb_install_all <apk> [adb install args...]` — install to **every** ready
  device; continues past failures, returns non-zero if any failed.
- `adb_uninstall <serial> <package>` — uninstall an app package.

Status
- `adb_battery_level <serial>` — battery percent (0–100).
- `adb_screen_on <serial>` — 0 = on, 1 = off, 2 = unknown.
- `adb_device_status <serial>` — a status block: model, Android + API, battery,
  screen, Wi-Fi IP.

CLI — `scripts/adb_tool.sh`
---------------------------

A thin dispatcher so the helpers are usable straight from the shell:

```bash
scripts/adb_tool.sh list                       # serial, model, OS, API, IP
scripts/adb_tool.sh status <serial>
scripts/adb_tool.sh install <serial> app.apk
scripts/adb_tool.sh install-all app.apk        # all attached devices
scripts/adb_tool.sh push <serial> ./f /sdcard/f
scripts/adb_tool.sh pull <serial> /sdcard/f ./f
scripts/adb_tool.sh logcat <serial> 'MyTag|crash'
scripts/adb_tool.sh --help
```

Examples (library)
------------------

```bash
source helpers.sh
shlib_import adb

adb_list_devices                                  # table of attached phones

for s in $(adb_ready_serials); do
  echo "$(adb_device_model "$s") — Android $(adb_android_version "$s") (API $(adb_device_api "$s")) @ $(adb_device_ip "$s")"
done

adb_install_all ./app-debug.apk                   # roll out a build everywhere
```

```powershell
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers adb
adb_list_devices | Format-Table -AutoSize
adb_device_status (adb_ready_serials | Select-Object -First 1)
```
