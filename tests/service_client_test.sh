#!/usr/bin/env bash
# SCRIPT: service_client_test.sh
# DESCRIPTION: Tests for the service-client building blocks: ui_* (dialog.sh), http_probe_json and http_check_key (http.sh), json_get_field (json.sh), version_offer_update (version.sh).
# USAGE: ./tests/service_client_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/service_client_test.sh
# ----------------------------------------------------
#
# The service is a small Python HTTP server on 127.0.0.1: /info answers JSON,
# /private answers 200 JSON only for the header "X-Token: right" and 401
# otherwise, /forbidden answers 403, /html answers 200 text/html, /empty
# answers 200 with no body. No network, no `dialog`: the UI is forced to
# none or plain through SHLIB_UI and fed answers on stdin.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[service_client_test] $*"; }
error() { echo "[service_client_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[service_client_test]   ok  $*"; }

command -v python3 >/dev/null 2>&1 || { note "SKIP: python3 not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { note "SKIP: curl not available"; exit 0; }

tmp="$(mktemp -d)"
server_pid=""
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging dialog json http version
unset SHLIB_UI SHLIB_UI_PLAIN

cat >"$tmp/server.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/info":
            self._send(200, {"name": "svc", "version": "1.2.0", "api_version": "v9", "nested": {"a": 1}})
        elif path == "/private":
            if self.headers.get("X-Token") == "right":
                self._send(200, {"ok": True}, "application/problem+json; charset=utf-8")
            else:
                self._send(401, {"code": "unauthorized"})
        elif path == "/forbidden":
            self._send(403, {"code": "forbidden"})
        elif path == "/html":
            self._send(200, b"<html></html>", "text/html")
        elif path == "/empty":
            self._send(200, b"")
        else:
            self._send(404, {"code": "not_found"})

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 "$tmp/server.py" "$port" &
server_pid=$!
url="http://127.0.0.1:$port"
for _attempt in $(seq 1 50); do
  curl -fsS --max-time 1 "$url/info" >/dev/null 2>&1 && break
  sleep 0.1
done
dead_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# --- ui_mode ---------------------------------------------------------------------
note "ui_mode"
if [[ "$(SHLIB_UI=none ui_mode)" == none ]]; then ok "SHLIB_UI=none wins"; else error "SHLIB_UI=none ignored"; fi
if [[ "$(SHLIB_UI=plain ui_mode)" == plain ]]; then ok "SHLIB_UI=plain wins"; else error "SHLIB_UI=plain ignored"; fi
if [[ "$(SHLIB_UI=dialog SHLIB_UI_PLAIN=1 ui_mode)" == plain ]]; then ok "SHLIB_UI_PLAIN=1 downgrades dialog"; else error "SHLIB_UI_PLAIN ignored"; fi
if [[ "$(ui_mode </dev/null)" == none ]]; then ok "no TTY means no prompts"; else error "non-TTY did not resolve to none"; fi
if out="$(SHLIB_UI=bogus ui_mode 2>&1)"; then error "an unknown SHLIB_UI must fail"
elif [[ "$out" == *"SHLIB_UI must be dialog, plain or none"* ]]; then ok "unknown SHLIB_UI refused, naming the variable"
else error "wrong message: $out"; fi

# --- ui_menu / ui_input / ui_secret / ui_yesno / ui_note ----------------------------
note "ui prompts"
if [[ "$(printf 'b\n' | SHLIB_UI=plain ui_menu T Pick a a First b Second 2>/dev/null)" == b ]]; then ok "menu returns the typed key"; else error "menu key"; fi
if [[ "$(printf '\n' | SHLIB_UI=plain ui_menu T Pick a a First b Second 2>/dev/null)" == a ]]; then ok "menu: empty answer takes the default"; else error "menu default"; fi
if printf 'z\n' | SHLIB_UI=plain ui_menu T Pick a a First b Second >/dev/null 2>&1; then error "menu accepted a key not offered"; else ok "menu refuses a key not offered"; fi
if SHLIB_UI=none ui_menu T Pick a a First </dev/null >/dev/null 2>&1; then error "menu prompted with no UI"; else ok "menu with no UI returns 1"; fi
if [[ "$(printf 'val\n' | SHLIB_UI=plain ui_input T Name def 2>/dev/null)" == val ]]; then ok "input returns the answer"; else error "input answer"; fi
if [[ "$(printf '\n' | SHLIB_UI=plain ui_input T Name def 2>/dev/null)" == def ]]; then ok "input: empty answer takes the default"; else error "input default"; fi
if SHLIB_UI=plain ui_input T Name def </dev/null >/dev/null 2>&1; then error "input at EOF succeeded"; else ok "input at EOF returns 1"; fi
if [[ "$(printf 's3cret\n' | SHLIB_UI=plain ui_secret T Key 2>/dev/null)" == s3cret ]]; then ok "secret returns the answer"; else error "secret answer"; fi
if SHLIB_UI=none ui_secret T Key </dev/null >/dev/null 2>&1; then error "secret prompted with no UI"; else ok "secret with no UI returns 1"; fi
if printf 'yes\n' | SHLIB_UI=plain ui_yesno T Sure >/dev/null 2>&1; then ok "yesno: yes"; else error "yesno yes"; fi
if printf '\n' | SHLIB_UI=plain ui_yesno T Sure >/dev/null 2>&1; then error "yesno: empty answer said yes"; else ok "yesno: empty answer is no"; fi
if printf 'yesss\n' | SHLIB_UI=plain ui_yesno T Sure >/dev/null 2>&1; then error "yesno: 'yesss' said yes"; else ok "yesno: only y or yes"; fi
if SHLIB_UI=none ui_yesno T Sure </dev/null >/dev/null 2>&1; then error "yesno said yes with no UI"; else ok "yesno with no UI is no"; fi
if SHLIB_UI=bogus ui_note T hello >/dev/null 2>&1; then ok "ui_note never fails"; else error "ui_note failed"; fi

# --- http_probe_json ---------------------------------------------------------------
note "http_probe_json"
if body="$(http_probe_json "$url/" info 3)" && [[ "$body" == *'"version": "1.2.0"'* ]]; then ok "probe returns the body (trailing / and bare path)"; else error "probe body: ${body:-}"; fi
if http_probe_json "$url" /missing 3 >/dev/null 2>&1; then error "a 404 counted as an answer"; else ok "a 404 is not an answer"; fi
if http_probe_json "$url" /empty 3 >/dev/null 2>&1; then error "an empty body counted as an answer"; else ok "an empty body is not an answer"; fi
if http_probe_json "http://127.0.0.1:$dead_port" /info 2 >/dev/null 2>&1; then error "a dead port answered"; else ok "nothing listening returns 1"; fi
if http_probe_json "$url" /info 0 >/dev/null 2>&1; then error "timeout 0 accepted"; else ok "a bad timeout is refused"; fi
if http_probe_json "$url" >/dev/null 2>&1; then error "a missing PATH accepted"; else ok "PATH is required"; fi

# --- json_get_field ----------------------------------------------------------------
note "json_get_field"
if [[ "$(json_get_field "$body" version)" == 1.2.0 ]]; then ok "reads a string field"; else error "version"; fi
if [[ "$(json_get_field "$body" api_version)" == v9 ]]; then ok "api_version is its own field"; else error "api_version"; fi
if [[ -z "$(json_get_field "$body" nested)" ]]; then ok "an object field prints nothing"; else error "nested printed"; fi
if [[ -z "$(json_get_field "$body" absent)" ]]; then ok "a missing field prints nothing, exit 0"; else error "missing field"; fi
if [[ "$(json_get_field '{"ok":true,"off":false,"n":3}' ok)" == true ]]; then ok "a boolean prints as JSON true"; else error "boolean printed as $(json_get_field '{"ok":true}' ok)"; fi
if [[ "$(json_get_field '{"off":false}' off)" == false ]]; then ok "false prints as JSON false"; else error "false"; fi
if [[ "$(json_get_field '{"n":3}' n)" == 3 ]]; then ok "a number prints as written"; else error "number"; fi
if [[ -z "$(json_get_field "not json" version)" ]]; then ok "not JSON prints nothing"; else error "not json"; fi
if json_get_field "$body" 'ver.*' >/dev/null 2>&1; then error "a regex key accepted"; else ok "a key that is not a word is refused"; fi
mkdir -p "$tmp/nopy"
for t in grep head sed printf; do p="$(command -v "$t" || true)"; [[ -n "$p" && "$p" == /* ]] && ln -sf "$p" "$tmp/nopy/$t"; done
v="$(PATH="$tmp/nopy" json_get_field "$body" version)"
if [[ "$v" == 1.2.0 ]]; then ok "sed fallback without python3 reads the field"; else error "fallback read: [$v]"; fi
v="$(PATH="$tmp/nopy" json_get_field '{"api_version": "v9"}' version)"
if [[ -z "$v" ]]; then ok "fallback: version does not match api_version"; else error "fallback matched api_version: [$v]"; fi

# --- http_check_key ----------------------------------------------------------------
note "http_check_key"
if http_check_key "$url" /private X-Token right; then ok "the right key is accepted (problem+json counts as JSON)"; else error "right key refused"; fi
rc=0; http_check_key "$url" private X-Token wrong 2>/dev/null || rc=$?
if [[ $rc -eq 2 ]]; then ok "a 401 is a refused key (2)"; else error "401 gave $rc, want 2"; fi
rc=0; http_check_key "$url" /forbidden X-Token any 2>/dev/null || rc=$?
if [[ $rc -eq 2 ]]; then ok "a 403 is a refused key (2)"; else error "403 gave $rc, want 2"; fi
rc=0; http_check_key "$url" /html X-Token any 2>/dev/null || rc=$?
if [[ $rc -eq 1 ]]; then ok "a 200 with HTML is not acceptance (1)"; else error "HTML 200 gave $rc, want 1"; fi
rc=0; http_check_key "http://127.0.0.1:$dead_port" /private X-Token right 2>/dev/null || rc=$?
if [[ $rc -eq 1 ]]; then ok "nothing listening is 1"; else error "dead port gave $rc, want 1"; fi
if http_check_key "$url" /private X-Token $'ri\nght' 2>/dev/null; then error "LF in key accepted"; else ok "LF in key refused"; fi
if http_check_key "$url" /private X-Token $'ri\rght' 2>/dev/null; then error "CR in key accepted"; else ok "CR in key refused"; fi
if http_check_key "$url" /private 'X-Token: x' right 2>/dev/null; then error "a header name with ': ' accepted"; else ok "a header name that is not a token is refused"; fi
if http_check_key "$url" /private X-Token 2>/dev/null; then error "a missing KEY accepted"; else ok "KEY is required"; fi
# The key never reaches curl's argv: a curl shim records its arguments.
mkdir -p "$tmp/shim"
real_curl="$(command -v curl)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s/argv"\nexec "%s" "$@"\n' "$tmp" "$real_curl" >"$tmp/shim/curl"
chmod +x "$tmp/shim/curl"
if PATH="$tmp/shim:$PATH" http_check_key "$url" /private X-Token right; then ok "the key check passes through the shim"; else error "shim run failed"; fi
if grep -q right "$tmp/argv" 2>/dev/null; then error "the key appeared in curl's argv"; else ok "the key is not in curl's argv"; fi

# --- version_offer_update ----------------------------------------------------------
note "version_offer_update"
ran="$tmp/ran"
record() { echo "$*" >"$ran"; }
rm -f "$ran"; out="$(SHLIB_UI=none version_offer_update --label App 1.0.0 1.1.0 record x 2>&1)"
if [[ ! -e "$ran" && "$out" == *"App 1.0.0 is running; 1.1.0 is available: record x"* ]]; then ok "no person: one line, nothing run"; else error "no-UI: ran=$(cat "$ran" 2>/dev/null) out=$out"; fi
rm -f "$ran"; out="$(SHLIB_UI=none version_offer_update --hint "cd d && ./update" 1.0.0 1.1.0 record x 2>&1)"
if [[ "$out" == *"available: cd d && ./update"* ]]; then ok "--hint replaces the command in the line"; else error "hint: $out"; fi
rm -f "$ran"; printf 'y\n' | SHLIB_UI=plain version_offer_update 1.0.0 1.1.0 record a b >/dev/null 2>&1
if [[ "$(cat "$ran" 2>/dev/null)" == "a b" ]]; then ok "yes runs the command with its arguments"; else error "yes did not run the command"; fi
rm -f "$ran"; printf 'n\n' | SHLIB_UI=plain version_offer_update 1.0.0 1.1.0 record a >/dev/null 2>&1
if [[ ! -e "$ran" ]]; then ok "no runs nothing"; else error "declined offer ran the command"; fi
rm -f "$ran"; printf 'y\n' | SHLIB_UI=plain version_offer_update 1.1.0 1.1.0 record a >/dev/null 2>&1
if [[ ! -e "$ran" ]]; then ok "equal versions offer nothing"; else error "equal versions ran the command"; fi
rm -f "$ran"; printf 'y\n' | SHLIB_UI=plain version_offer_update 1.2.0 1.1.0 record a >/dev/null 2>&1
if [[ ! -e "$ran" ]]; then ok "a newer running version offers nothing"; else error "newer running ran the command"; fi
if rm -f "$ran"; SHLIB_UI=plain version_offer_update "" 1.1.0 record a </dev/null >/dev/null 2>&1 && [[ ! -e "$ran" ]]; then ok "an unknown running version is nothing to offer (0)"; else error "empty running"; fi
fails() { return 7; }
rc=0; printf 'y\n' | SHLIB_UI=plain version_offer_update 1.0.0 1.1.0 fails >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 7 ]]; then ok "the command's failure is returned"; else error "command rc $rc, want 7"; fi
if SHLIB_UI=plain version_offer_update 1.0.0 1.1.0 </dev/null >/dev/null 2>&1; then error "a missing COMMAND accepted"; else ok "COMMAND is required"; fi
if SHLIB_UI=bogus version_offer_update 1.0.0 1.1.0 record a </dev/null >/dev/null 2>&1; then error "a bad SHLIB_UI passed silently"; else ok "a bad SHLIB_UI is an error"; fi
out="$(SHLIB_UI=none version_offer_update --label "" 1.0.0 1.1.0 true 2>&1)"
bare="$(SHLIB_UI=none version_offer_update 1.0.0 1.1.0 true 2>&1)"
if [[ "$out" == "$bare" ]]; then ok "an empty --label adds no space"; else error "empty label: $out"; fi
if version_offer_update --label </dev/null >/dev/null 2>&1; then error "--label without a value accepted"; else ok "--label needs a value"; fi

# Imported alone, version loads the dialog module it needs.
out="$(bash -c 'cd "$1" && . ./helpers.sh && shlib_import version && SHLIB_UI=none version_offer_update 1.0.0 1.1.0 true' _ "$root_dir" 2>&1)" || true
if [[ "$out" == *"1.1.0 is available"* ]]; then ok "version imported alone still offers"; else error "version alone: $out"; fi

# --- the new modules name no service ----------------------------------------------
note "neutral"
if git grep -n -i -w hub -- lib/http.sh lib/json.sh lib/version.sh docs/modules/http.md >/dev/null 2>&1; then
  error "a neutral module names a service"
else
  ok "no service named in the neutral modules"
fi

if [[ "$failures" -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all service client tests passed"
