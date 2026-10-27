#!/usr/bin/env bash
# A stand-in for adb in tests/webshot_android_test.sh. Logs every call to
# $FAKE_ADB_LOG. FAKE_ADB_DEVICES is the device list ("SERIAL STATE" lines);
# "forward tcp:0" prints $FAKE_ADB_CDP_PORT, the DevTools port of a local
# Chromium that stands in for the phone's Chrome.
echo "$*" >>"${FAKE_ADB_LOG:-/dev/null}"
if [[ "${1:-}" == devices ]]; then
  echo "List of devices attached"
  [[ -n "${FAKE_ADB_DEVICES:-}" ]] && printf '%s\n' "$FAKE_ADB_DEVICES" | sed 's/ /\t/'
  exit 0
fi
[[ "${1:-}" == -s ]] && shift 2
case "$*" in
  "forward tcp:0 localabstract:chrome_devtools_remote") echo "${FAKE_ADB_CDP_PORT:?}" ;;
  "shell getprop ro.product.model") echo "Fake Phone" ;;
  "exec-out screencap -p") printf '\x89PNG\r\n\x1a\n' ;;
  "reverse tcp:"*|"forward --remove"*|"reverse --remove"*|"shell am start"*) ;;
  *) echo "fake adb: unexpected: $*" >&2; exit 1 ;;
esac
