#!/usr/bin/env bash
# SCRIPT: json_test.sh
# DESCRIPTION: Tests for lib/json.sh -- json_escape output is a valid JSON string body.
# USAGE: ./tests/json_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/json_test.sh
# ----------------------------------------------------
#
# json_escape builds request bodies by interpolation ("{\"prompt\":\"$(json_escape ...)\"}"),
# so anything it lets through raw makes the whole body invalid JSON, and
# anything it drops is silently missing from the request.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[json_test] $*"; }
error() { echo "[json_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[json_test]   ok  $*"; }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging json

# Exact expected output, independent of any JSON parser.
expect() {
  local label="$1" input="$2" want="$3" got
  got="$(json_escape "$input")"
  if [[ "$got" == "$want" ]]; then ok "$label"; else error "$label: got $(printf '%q' "$got"), want $(printf '%q' "$want")"; fi
}

note "unchanged"
expect "plain text" 'hello world' 'hello world'
expect "backslash" 'C:\dir' 'C:\\dir'
expect "newline, CR, tab" $'a\nb\rc\td' 'a\nb\rc\td'
expect "empty" '' ''
expect "unicode passes through" 'naïve – ok' 'naïve – ok'

note "fixed"
expect "double quotes are escaped" 'say "hi"' 'say \"hi\"'
expect "-n is not swallowed" '-n' '-n'
expect "-e is not swallowed" '-e' '-e'
expect "backspace and form feed" $'a\bb\fc' 'a\u0008b\u000cc'
expect "escape (0x1b)" $'\033[0m' '\u001b[0m'
expect "0x01" $'x\001y' 'x\u0001y'
expect "0x1f" $'x\037y' 'x\u001fy'
expect "bell with a newline" $'\a\n' '\u0007\n'
expect "backslash then control" $'\\\001' '\\\u0001'

if command -v python3 >/dev/null 2>&1; then
  all=""
  # shellcheck disable=SC2059
  for (( i = 1; i < 32; i++ )); do all+="$(printf "\\$(printf '%03o' "$i")")"; done
  all+=$'\n'' "\ end'
  body="{\"s\":\"$(json_escape "$all")\"}"
  if printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if len(d["s"]) == 31 + 7 else 1)' 2>/dev/null; then
    ok "every control character round-trips through a JSON parser"
  else
    error "not valid JSON: $(printf '%q' "$body")"
  fi
fi

if [[ $failures -eq 0 ]]; then
  note "all json tests passed"
  exit 0
fi
note "$failures failure(s)"
exit 1
