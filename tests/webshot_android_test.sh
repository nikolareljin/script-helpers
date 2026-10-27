#!/usr/bin/env bash
# SCRIPT: webshot_android_test.sh
# DESCRIPTION: Tests for webshot_android_audit in lib/webshot.sh. Argument and
#              device checks always run, with a fake adb. When Playwright's
#              Chromium is installed, a headless Chromium stands in for the
#              phone's Chrome and the checks run against it over DevTools.
# USAGE: ./tests/webshot_android_test.sh
# PARAMETERS: No required parameters. WEBSHOT_REQUIRE_BROWSER=1 turns a missing
#             Chromium into a failure instead of a skip.
# EXAMPLE: bash tests/webshot_android_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[webshot_android_test] $*"; }
error() { echo "[webshot_android_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import python webshot

tmp="$(mktemp -d)"
# Background helpers to stop at exit, space-separated (an empty array is
# "unbound" under set -u in bash 3.2).
pids=""
cleanup() {
  local p
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  # Chromium's helper processes write the profile for a moment after it exits.
  for p in $pids; do wait "$p" 2>/dev/null || true; done
  rm -rf "$tmp" 2>/dev/null || { sleep 2; rm -rf "$tmp"; }
}
# Only the test's own shell cleans up, not a subshell that exits.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT

expect_status() {
  local want="$1" label="$2" status
  shift 2
  set +e
  "$@" >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
  if [[ "$status" -eq "$want" ]]; then
    note "$label -> $status"
  else
    error "$label: expected $want, got $status: $(tail -1 "$tmp/err")"
  fi
}

# A PATH whose adb is the fake one; another with no adb at all.
mkdir -p "$tmp/bin" "$tmp/noadb"
cp tests/fixtures/webshot/fake_adb.sh "$tmp/bin/adb"
chmod +x "$tmp/bin/adb"
for tool in bash python3 awk sed head grep tr mkdir env cat dirname; do
  ln -sf "$(command -v "$tool")" "$tmp/noadb/$tool"
done
export FAKE_ADB_LOG="$tmp/adb.log"

expect_status 2 "no url" webshot_android_audit
expect_status 2 "a file url" webshot_android_audit file:///tmp/x.html
expect_status 2 "a url with a quote" webshot_android_audit "http://localhost:8000/a'b"
expect_status 2 "a url with a space" webshot_android_audit "http://localhost:8000/a b"
expect_status 2 "a url with a double quote" webshot_android_audit "http://localhost:8000/a\"b"
expect_status 2 "an unknown option" webshot_android_audit http://localhost:8000/ --crawl
expect_status 2 "a trailing --path" webshot_android_audit http://localhost:8000/ --path
expect_status 2 "a bad --timeout-ms" webshot_android_audit http://localhost:8000/ --timeout-ms 0
expect_status 3 "no adb on PATH" env PATH="$tmp/noadb" bash -c \
  "source ./helpers.sh; shlib_import python webshot; webshot_android_audit http://localhost:8000/"
if grep -q "adb not found" "$tmp/err"; then note "no adb names the cause"; else error "no adb: $(cat "$tmp/err")"; fi

PATH="$tmp/bin:$PATH"
export FAKE_ADB_DEVICES=""
expect_status 3 "no device attached" webshot_android_audit http://localhost:8000/
if grep -q "no Android device attached" "$tmp/err"; then note "no device names the cause"; else error "no device: $(cat "$tmp/err")"; fi
export FAKE_ADB_DEVICES="ABC unauthorized"
expect_status 3 "only an unauthorized device" webshot_android_audit http://localhost:8000/
export FAKE_ADB_DEVICES="ABC device"
expect_status 3 "a --serial that is not attached" webshot_android_audit http://localhost:8000/ --serial XYZ

py="$(webshot_python 2>/dev/null || true)"
chromium=""
if [[ -n "$py" ]]; then
  chromium="$("$py" -c 'from playwright.sync_api import sync_playwright
with sync_playwright() as p: print(p.chromium.executable_path)' 2>/dev/null || true)"
fi
if [[ -n "$chromium" && -x "$chromium" ]]; then
  # The site, on 127.0.0.1 (so the audit asks adb to reverse its port).
  "$py" tests/fixtures/webshot/audit_server.py >"$tmp/site-port" &
  pids="$pids $!"
  # The "phone": Chromium with a DevTools port, at a phone's width.
  cdp_port="$("$py" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  "$chromium" --headless=new --no-sandbox --remote-debugging-port="$cdp_port" --window-size=390,844 \
    --user-data-dir="$tmp/profile" about:blank >/dev/null 2>&1 &
  pids="$pids $!"
  for _ in $(seq 1 40); do
    [[ -s "$tmp/site-port" ]] && "$py" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$cdp_port/json')" 2>/dev/null && break
    sleep 0.25
  done
  site_port="$(cat "$tmp/site-port")"
  export FAKE_ADB_CDP_PORT="$cdp_port"
  : >"$FAKE_ADB_LOG"

  expect_status 1 "a wide page, a clean page and a missing page" \
    webshot_android_audit "http://127.0.0.1:$site_port/" --path /wide.html --path /clean-only.html \
    --path /nope.html --shots "$tmp/shots"
  if "$py" - "$tmp/out" "$site_port" <<'PY'; then
import json, sys
r, base = json.load(open(sys.argv[1])), f"http://127.0.0.1:{sys.argv[2]}"
assert r["device"] == "Fake Phone", r
assert r["checked"] == [base + "/wide.html", base + "/clean-only.html"], r
assert list(r["findings"]) == [base + "/wide.html"], r
f = r["findings"][base + "/wide.html"]["Fake Phone"]
assert f["scroll_width"] > f["width"] and f["elements"], f
assert r["http_errors"] == {base + "/nope.html": 404}, r
PY
    note "the report names the wide page and the missing one"
  else
    error "android audit report: $(cat "$tmp/out") $(cat "$tmp/err")"
  fi
  count="$(find "$tmp/shots" -name '*--Fake_Phone.png' | wc -l | tr -d ' ')"
  if [[ "$count" == 2 ]]; then note "a screencap PNG per checked page"; else error "expected 2 PNGs, found $count"; fi
  if grep -qx -- "-s ABC reverse tcp:$site_port tcp:$site_port" "$FAKE_ADB_LOG" \
     && grep -qx -- "-s ABC reverse --remove tcp:$site_port" "$FAKE_ADB_LOG" \
     && grep -qx -- "-s ABC forward --remove tcp:$cdp_port" "$FAKE_ADB_LOG"; then
    note "the reverse and forward are set up and removed"
  else
    error "adb calls: $(cat "$FAKE_ADB_LOG")"
  fi

  expect_status 0 "a clean page" webshot_android_audit "http://127.0.0.1:$site_port/clean-only.html"
  expect_status 0 "bin/webshot android-audit of a clean page" \
    bin/webshot android-audit "http://127.0.0.1:$site_port/clean-only.html"

  # A host that is not local is not reversed.
  : >"$FAKE_ADB_LOG"
  expect_status 1 "a page that does not load" \
    webshot_android_audit "http://127.0.0.2:9/" --timeout-ms 5000
  if grep -q "reverse" "$FAKE_ADB_LOG"; then error "reversed a non-local host: $(cat "$FAKE_ADB_LOG")"; else note "a non-local host is not reversed"; fi

  # TERM mid-run: the driver stops and the forward is still removed. The
  # page never answers (the socket is listening but nothing accepts), so the
  # driver is still waiting for it when TERM arrives.
  "$py" -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
print(s.getsockname()[1], flush=True); sys.stdout.close(); time.sleep(600)' >"$tmp/hang-port" &
  pids="$pids $!"
  for _ in $(seq 1 20); do [[ -s "$tmp/hang-port" ]] && break; sleep 0.25; done
  : >"$FAKE_ADB_LOG"
  ( webshot_android_audit "http://127.0.0.1:$(cat "$tmp/hang-port")/" --timeout-ms 60000 >/dev/null 2>&1 ) &
  run=$!
  sleep 3
  pkill -TERM -P "$run" 2>/dev/null || true
  set +e; wait "$run"; set -e
  sleep 1
  if grep -q -- "forward --remove" "$FAKE_ADB_LOG"; then note "TERM removes the forward"; else error "TERM left the forward: $(cat "$FAKE_ADB_LOG")"; fi
  # The driver is "python -" with WEBSHOT_MODE=android in its environment.
  # grep exits 2 on the /proc entries it cannot read, even with a match, so
  # test its output, not its status.
  left="$(grep -lsz "^WEBSHOT_MODE=android$" /proc/[0-9]*/environ 2>/dev/null || true)"
  if [[ -n "$left" ]]; then
    error "driver still running after TERM: $left"
  else
    note "TERM stops the driver"
  fi
elif [[ "${WEBSHOT_REQUIRE_BROWSER:-0}" == "1" ]]; then
  error "Playwright's Chromium not available and WEBSHOT_REQUIRE_BROWSER=1"
else
  note "Playwright's Chromium not available: skipping the DevTools checks (not a failure)"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
