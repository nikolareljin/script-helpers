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
trap 'rm -rf "$tmp"' EXIT

# 1) functions defined after import
for fn in webshot_venv_dir webshot_python webshot_ensure webshot_capture webshot_pdf; do
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
    '{"shots":[{"name":"a","url":"about:blank"},{"name":"a","url":"about:blank"}]}' 'not json'; do
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
                 {"eval": "() => { if (document.querySelector('#name').value !== 'expanded') throw new Error('env not expanded') }"}]}
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
