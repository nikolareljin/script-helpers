#!/usr/bin/env bash
# SCRIPT: webshot_test.sh
# DESCRIPTION: Tests for lib/webshot.sh (argument and spec checks always; a real
#              capture and PDF render when Playwright for Python is available).
# USAGE: ./tests/webshot_test.sh
# PARAMETERS: No required parameters. WEBSHOT_REQUIRE_BROWSER=1 turns a missing
#             Playwright into a failure instead of a skip.
# EXAMPLE: bash tests/webshot_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[webshot_test] $*"; }
error() { echo "[webshot_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import python webshot

# Run a command with a time limit and return its status, or 137 when it had to
# be killed (macOS has no timeout(1)). The watcher's output goes to /dev/null
# so its sleep cannot hold a pipe open.
run_bounded() {
  local secs=$1; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 & local w=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -9 "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

expect_status() {
  local want="$1" label="$2" status
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq "$want" ]]; then
    note "$label returns $want"
  else
    error "$label returned $status (expected $want)"
  fi
}

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# 1) functions defined after import
for fn in webshot_venv_dir webshot_python webshot_ensure webshot_capture webshot_audit webshot_pdf; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) argument checks return 2 before any Python is needed
expect_status 2 "capture without args" webshot_capture
expect_status 2 "capture with a missing spec" webshot_capture "$tmp/nope.json" "$tmp/out"
expect_status 2 "pdf without args" webshot_pdf
expect_status 2 "audit without args" webshot_audit
expect_status 2 "audit with a relative start" webshot_audit index.html
expect_status 2 "audit with a bad --limit" webshot_audit http://localhost/ --limit 0
expect_status 2 "audit with an unknown option" webshot_audit http://localhost/ --depth 3
expect_status 2 "audit with an empty --device" webshot_audit http://localhost/ --device ""
# A value option with nothing after it returns 2 instead of looping on
# "shift 2" (137 = killed after hanging).
expect_status 2 "audit with a trailing --limit" run_bounded 10 webshot_audit http://localhost/ --limit
expect_status 2 "pdf with a trailing --format" run_bounded 10 webshot_pdf "$tmp/in.html" "$tmp/out.pdf" --format
expect_status 2 "pdf with a missing input" webshot_pdf "$tmp/nope.html" "$tmp/out.pdf"
printf '<p>x</p>' > "$tmp/in.html"
expect_status 2 "pdf with a bad --format" webshot_pdf "$tmp/in.html" "$tmp/out.pdf" --format Postcard
expect_status 2 "pdf with a bad --wait-ms" webshot_pdf "$tmp/in.html" "$tmp/out.pdf" --wait-ms soon
expect_status 2 "pdf with an unknown option" webshot_pdf "$tmp/in.html" "$tmp/out.pdf" --colour

# 3) an unusable WEBSHOT_PYTHON returns 3, not a crash
printf '{"shots":[{"name":"a","url":"about:blank"}]}' > "$tmp/ok.json"
WEBSHOT_PYTHON="$tmp/no-python" expect_status 3 "capture with an unusable WEBSHOT_PYTHON" \
  webshot_capture "$tmp/ok.json" "$tmp/out"
WEBSHOT_PYTHON="$tmp/no-python" expect_status 3 "pdf with an unusable WEBSHOT_PYTHON" \
  webshot_pdf "$tmp/in.html" "$tmp/out.pdf"

# 4) the bin wrapper rejects unknown commands
expect_status 2 "bin/webshot with an unknown command" bin/webshot frobnicate

# 5) with Playwright: spec validation, a real capture and a PDF
if py="$(webshot_python 2>/dev/null)"; then
  note "using $py"

  for bad in '[]' '{"shots":[]}' '{"shots":[{"name":"a b","url":"about:blank"}]}' \
    '{"shots":[{"name":"a","path":"/x"}]}' '{"shots":[{"name":"a","url":"about:blank","auth":"ghost"}]}' \
    '{"shots":[{"name":"a","url":"about:blank","actions":[{"dance":"x"}]}]}' \
    '{"auth":{"u":{"type":"api_token","url":"/login"}},"shots":[{"name":"a","url":"about:blank"}]}' \
    '{"shots":[{"name":"a","url":"about:blank"},{"name":"a","url":"about:blank"}]}' 'not json' \
    '{"device":"Nokia 3310","shots":[{"name":"a","url":"about:blank"}]}' \
    '{"shots":[{"name":"a","url":"about:blank","device":7}]}'; do
    printf '%s' "$bad" > "$tmp/bad.json"
    expect_status 2 "invalid spec $bad" webshot_capture "$tmp/bad.json" "$tmp/out"
  done

  fixture="file://$root_dir/tests/fixtures/webshot/page.html"
  cat > "$tmp/spec.json" <<EOF
{
  "viewport": {"width": 800, "height": 600},
  "device_scale_factor": 2,
  "wait_ms": 50,
  "hide": ["#banner"],
  "shots": [
    {"name": "full", "url": "$fixture", "full_page": true},
    {"name": "plain", "url": "$fixture", "selector": "[data-shot=card]", "padding": 4},
    {"name": "card", "url": "$fixture", "selector": "[data-shot=card]", "padding": 4,
     "actions": [{"fill": "#name", "value": "\${WEBSHOT_TEST_VALUE}"}, {"click": "#reveal"},
                 {"wait_for": "#extra"},
                 {"eval": "() => { if (document.querySelector('#name').value !== 'expanded') throw new Error('env not expanded') }"},
                 {"eval": "() => { if ('\${HOME}' !== '$' + '{HOME}') throw new Error('eval code was expanded') }"}]}
  ]
}
EOF
  if WEBSHOT_TEST_VALUE=expanded webshot_capture "$tmp/spec.json" "$tmp/shots" 2>/dev/null; then
    for name in full card; do
      if [[ "$(head -c 8 "$tmp/shots/$name.png" | od -An -tx1 | tr -d ' \n')" == "89504e470d0a1a0a" ]]; then
        note "$name.png is a PNG"
      else
        error "$name.png is missing or not a PNG"
      fi
    done
    "$py" - "$tmp/shots/manifest.json" <<'PY' || error "manifest checks failed"
import json, sys
m = {s["name"]: s for s in json.load(open(sys.argv[1]))}
assert set(m) == {"full", "plain", "card"}, m
# DPR 2 doubles pixels; the card is 300px + 2x20px padding + 2px border + 2x4px clip padding = 350px wide.
assert m["card"]["width"] == 700, m["card"]
assert m["full"]["width"] == 1600, m["full"]
# The click revealed an extra paragraph, so the acted-on card is taller than the plain one.
assert m["card"]["height"] > m["plain"]["height"], (m["card"], m["plain"])
PY
    note "manifest sizes match the viewport, DPR, element clip and the action's effect"
  else
    error "webshot_capture failed on the fixture"
  fi

  if webshot_pdf "$root_dir/tests/fixtures/webshot/page.html" "$tmp/page.pdf" --footer "Fixture" 2>/dev/null \
    && [[ "$(head -c 5 "$tmp/page.pdf")" == "%PDF-" ]]; then
    note "webshot_pdf produced a PDF"
  else
    error "webshot_pdf failed to produce a PDF"
  fi

  printf '{"shots":[{"name":"gone","url":"%s","selector":"#does-not-exist"}],"timeout_ms":1500}' "$fixture" \
    > "$tmp/missing.json"
  expect_status 1 "capture of a missing selector" webshot_capture "$tmp/missing.json" "$tmp/shots2"

  # A named device sets a phone user agent, touch and its viewport; a shot
  # viewport still wins over a spec-level device.
  cat > "$tmp/device.json" <<EOF
{
  "device": "Pixel 7",
  "wait_ms": 0,
  "shots": [
    {"name": "phone", "url": "$fixture",
     "actions": [{"eval": "() => { if (!/Mobile/.test(navigator.userAgent) || navigator.maxTouchPoints < 1 || screen.width !== 412) throw new Error('not emulated: ' + screen.width) }"}]},
    {"name": "narrow", "url": "$fixture", "viewport": {"width": 360, "height": 640},
     "actions": [{"eval": "() => { if (screen.width !== 360 || navigator.maxTouchPoints < 1) throw new Error('viewport not applied: ' + screen.width) }"}]},
    {"name": "desktop", "url": "$fixture", "device": "Desktop Chrome",
     "actions": [{"eval": "() => { if (/Mobile/.test(navigator.userAgent)) throw new Error('shot device ignored') }"}]}
  ]
}
EOF
  if webshot_capture "$tmp/device.json" "$tmp/shots5" 2>"$tmp/device.err"; then
    "$py" - "$tmp/shots5/manifest.json" <<'PY' || error "device manifest checks failed"
import json, sys
m = {s["name"]: s for s in json.load(open(sys.argv[1]))}
assert m["phone"]["device"] == "Pixel 7" and m["desktop"]["device"] == "Desktop Chrome", m
# Pixel 7: 412px wide at scale factor 2.625.
assert m["phone"]["width"] == round(412 * 2.625), m["phone"]
PY
    note "device emulation: phone user agent, touch, viewport, override and per-shot device"
  else
    error "device capture failed: $(tail -1 "$tmp/device.err")"
  fi

  # Audit: index links to a wide page, a clipped heading, a skipped wide page,
  # an external host, a zip and itself. Two findings; the skipped page is not crawled.
  site="file://$root_dir/tests/fixtures/webshot/audit"
  set +e
  webshot_audit "$site/index.html" --skip "$root_dir/tests/fixtures/webshot/audit/skipped" \
    --shots "$tmp/audit-shots" >"$tmp/audit.json" 2>"$tmp/audit.err"
  status=$?
  set -e
  if [[ "$status" -eq 1 ]]; then
    if "$py" - "$tmp/audit.json" "$site" <<'PY'; then
import json, sys
r, site = json.load(open(sys.argv[1])), sys.argv[2]
assert r["crawled"] == 3, r
# A link to a download is neither a page nor a load error.
assert r["downloads"] == [site + "/file.zip"] and not r["http_errors"], r
f = r["findings"]
assert set(f) == {site + "/wide.html", site + "/clipped.html"}, f
wide = f[site + "/wide.html"]
assert set(wide) == {"iPhone 13", "Galaxy S8"}, wide
assert wide["Galaxy S8"]["width"] == 360 and wide["Galaxy S8"]["scroll_width"] > 360, wide
assert any(e.startswith("p#long ") for e in wide["iPhone 13"]["elements"]), wide
clip = f[site + "/clipped.html"]["iPhone 13"]
assert clip["scroll_width"] == clip["width"] and clip["clipped_headings"], clip
PY
      note "audit reports the wide page and the clipped heading on both devices"
    else
      error "audit report checks failed"
    fi
    count="$(find "$tmp/audit-shots" -name '*.png' | wc -l)"
    if [[ "$count" -eq 6 ]]; then
      note "audit saved 6 PNGs (3 pages x 2 devices)"
    else
      error "audit saved $count PNGs, expected 6"
    fi
  else
    error "audit of the fixture site returned $status (expected 1): $(tail -1 "$tmp/audit.err")"
  fi
  # A page whose path is longer than a file name allows still gets a PNG.
  long="$tmp/$(printf 'x%.0s' {1..200})/$(printf 'y%.0s' {1..200})"
  mkdir -p "$long"
  cp tests/fixtures/webshot/audit/clean-only.html "$long/page.html"
  expect_status 0 "audit --shots of a page under two 200-character directories" \
    webshot_audit "file://$long/page.html" --device "Pixel 7" --shots "$tmp/long-shots"
  # Over HTTP: a redirect to a page that is also linked is one page,
  # reported once under the URL the redirect ends on.
  port_file="$tmp/audit-port"
  "$py" tests/fixtures/webshot/audit_server.py >"$port_file" &
  server_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$port_file" ]] && break; sleep 0.5; done
  port="$(cat "$port_file")"
  set +e
  webshot_audit "http://127.0.0.1:$port/redirects.html" --device "Pixel 7" --skip /skipped >"$tmp/audit-http.json" 2>/dev/null
  status=$?
  set -e
  # A start URL that redirects to another host crawls that host, not one page.
  set +e
  webshot_audit "http://localhost:$port/elsewhere" --device "Pixel 7" --skip /skipped \
    >"$tmp/audit-host.json" 2>/dev/null
  host_status=$?
  set -e
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  if [[ "$status" -eq 1 ]] && "$py" - "$tmp/audit-http.json" "$port" <<'PY'; then
import json, sys
r, base = json.load(open(sys.argv[1])), f"http://127.0.0.1:{sys.argv[2]}"
# /redirect lands on /wide.html, which is also linked: one entry, not two.
assert set(r["findings"]) == {base + "/wide.html", base + "/clipped.html"}, r
assert not r["http_errors"], r
# An image opened directly is not a page: listed, not measured.
assert base + "/wide.png" in r["downloads"], r
PY
    note "audit over HTTP reports a redirected page once, under its final URL, and lists an image apart"
  else
    error "audit over HTTP returned $status or reported a page twice: $(cat "$tmp/audit-http.json")"
  fi
  if [[ "$host_status" -eq 1 ]] && "$py" - "$tmp/audit-host.json" "$port" <<'PY'; then
import json, sys
r, base = json.load(open(sys.argv[1])), f"http://127.0.0.1:{sys.argv[2]}"
assert set(r["findings"]) == {base + "/wide.html", base + "/clipped.html"}, r
PY
    note "audit follows a start URL that redirects to another host"
  else
    error "audit of a start URL redirecting to another host returned $host_status: $(cat "$tmp/audit-host.json")"
  fi

  expect_status 0 "audit of a clean page" webshot_audit "$site/clean-only.html"
  expect_status 1 "audit of a missing start page" webshot_audit "$site/nope.html"
  expect_status 2 "audit with an unknown device" webshot_audit "$site/clean-only.html" --device "Nokia 3310"
  expect_status 0 "bin/webshot audit of a clean page" bin/webshot audit "$site/clean-only.html" --device "Pixel 7"

  # A hidden element cannot be captured: proves the hide rule applied.
  printf '{"hide":["#banner"],"timeout_ms":1500,"shots":[{"name":"b","url":"%s","selector":"#banner"}]}' \
    "$fixture" > "$tmp/hidden.json"
  expect_status 1 "capture of a hidden element" webshot_capture "$tmp/hidden.json" "$tmp/shots3"

  # Without the env var the eval check fails: proves ${VAR} expansion is what made it pass.
  expect_status 1 "capture whose eval check fails" env -u WEBSHOT_TEST_VALUE bash -c \
    "source ./helpers.sh; shlib_import python webshot; webshot_capture '$tmp/spec.json' '$tmp/shots4'"
elif [[ "${WEBSHOT_REQUIRE_BROWSER:-0}" == "1" ]]; then
  error "Playwright for Python not available and WEBSHOT_REQUIRE_BROWSER=1"
else
  note "Playwright for Python not available: skipping render checks (not a failure)"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
