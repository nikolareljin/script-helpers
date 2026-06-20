# adb

Utilities for USB-connected Android devices via the Android Debug Bridge (`adb`).
All helpers are **multi-device safe**: they target a device with `adb -s <serial>`
rather than a bare `adb shell`, which errors with *more than one device* once a
second device is attached. Every function returns non-zero / no-ops when `adb` is
not installed, so callers degrade cleanly.

Requirements
------------

- `adb` (Android platform-tools) on `PATH`. Without it the functions return
  non-zero (and `adb_list_devices` logs a warning).

Functions
---------

- adb_available
  - Purpose: Check whether the `adb` CLI is available.
  - Returns: 0 if `adb` is on `PATH`, non-zero otherwise.

- adb_ready_serials
  - Purpose: Print the serial of each *ready* device, one per line.
  - Behavior: Skips the header line and any `offline`/`unauthorized` entries
    (the device-state column must be exactly `device`).
  - Returns: prints serials (possibly none); non-zero if `adb` is missing.

- adb_device_ip serial [iface=wlan0]
  - Purpose: Print a device's IPv4 address on an interface (default `wlan0` /
    Wi-Fi). Pass e.g. `rmnet_data0` for a cellular interface.
  - Returns: 0 and prints the IP; non-zero with no output when `adb` is missing,
    the serial is empty, or the interface has no address (e.g. Wi-Fi off).

- adb_device_model serial
  - Purpose: Print `ro.product.model` for a device (CR/LF trimmed).
  - Returns: non-zero with no output when `adb` is missing or the serial is empty.

- adb_list_devices [iface=wlan0]
  - Purpose: Print a `SERIAL  MODEL  IP` table for every ready device — useful for
    finding a phone's IP to reach an on-device HTTP API.
  - Behavior: Works with any number of devices attached. Shows
    `<no wlan0 / Wi-Fi off>` when a device has no address on the interface.
  - Returns: 1 when `adb` is missing; 0 (with an empty table) when no devices are
    ready.

Examples
--------

```bash
source helpers.sh
shlib_import adb

# A table of every attached phone with its Wi-Fi IP.
adb_list_devices

# Script against a single device.
for s in $(adb_ready_serials); do
  ip="$(adb_device_ip "$s")" || continue
  echo "$(adb_device_model "$s") is at $ip"
done
```
