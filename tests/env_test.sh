#!/usr/bin/env bash
# SCRIPT: env_test.sh
# DESCRIPTION: Tests for lib/env.sh -- resolve_env_value parsing and load_env.
# USAGE: ./tests/env_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/env_test.sh
# ----------------------------------------------------
#
# resolve_env_value is read by every module that takes a port, a URL or a key
# from .env, so its output is a contract. The first table pins what already
# parsed correctly and must keep parsing identically; the second pins values
# that used to come back wrong -- silently, as a plausible-looking string.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[env_test] $*"; }
error() { echo "[env_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[env_test]   ok  $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging env

# Each case: the line written to the file (after "KEY=") and the expected value.
# DEFAULT is what resolve_env_value falls back to when the value is empty.
check_table() {
  local label="$1"; shift
  local raw expected got
  while [[ $# -ge 2 ]]; do
    raw="$1" expected="$2"; shift 2
    printf 'OTHER=1\nKEY=%s\n' "$raw" >"$tmp/t.env"
    got="$(resolve_env_value KEY DEFAULT "$tmp/t.env")"
    if [[ "$got" == "$expected" ]]; then
      ok "$label: KEY=$raw -> [$expected]"
    else
      error "$label: KEY=$raw -> [$got], expected [$expected]"
    fi
  done
}

note "values that already parsed correctly"
check_table unchanged \
  'value' 'value' \
  'http://localhost:8000' 'http://localhost:8000' \
  '8000' '8000' \
  '"hello world"' 'hello world' \
  "'hello world'" 'hello world' \
  'value # a comment' 'value' \
  '  spaced  ' 'spaced' \
  '' 'DEFAULT' \
  '""' 'DEFAULT' \
  '# only a comment' 'DEFAULT' \
  "value"$'\r' 'value' \
  "'it''s'" "it''s" \
  '"a\"b"' 'a"b' \
  '"abc' 'abc' \
  'abc"' 'abc' \
  'ollama/ollama:latest' 'ollama/ollama:latest' \
  './models/ollama-data' './models/ollama-data'

note "values that used to come back wrong"
check_table fixed \
  '"quoted" # a comment' 'quoted' \
  'dGVzdGtleQ==' 'dGVzdGtleQ==' \
  'postgres://u:p@h/db?sslmode=require' 'postgres://u:p@h/db?sslmode=require' \
  'ab#cd' 'ab#cd' \
  '"a #b"' 'a #b' \
  "'x#y' # note" 'x#y' \
  "O'Brien" "O'Brien" \
  '-n' '-n' \
  '-e' '-e' \
  'C:\new\dev' 'C:\new\dev' \
  "'it\"s'" 'it"s'

note "quoted values are not read one character at a time"
# Parsing a quoted value indexed it character by character, which is quadratic:
# a 20KB value took about 9 seconds and a 40KB one well over half a minute.
# run_bounded <seconds> <cmd...>: sets rc, 124 when the command had to be killed.
run_bounded() {
  local limit="$1" pid waited=0; shift
  "$@" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$waited" -ge $((limit * 10)) ]]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rc=124
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  rc=0; wait "$pid" || rc=$?
  return 0
}
big="$(printf '%40000s' '' | tr ' ' 'x')"
# The parser itself runs in the bounded process, not in a command substitution
# under it: kill -9 would not reach that grandchild, which kept the CPU busy
# after a timeout.
# shellcheck disable=SC2317
parse_big() { _env__parse_value "$1" >"$tmp/big.out"; }
for form in "'$big'" "\"$big\"" "'$big' # note"; do
  rc=0; run_bounded 5 parse_big "$form"
  case "$rc" in
    0)
      if [[ "$(cat "$tmp/big.out")" == "$big" ]]; then
        ok "a 40KB ${form:0:1}-quoted value parses within 5s (${form:$((${#form} - 6))})"
      else
        error "a 40KB ${form:0:1}-quoted value parsed wrong"
      fi
      ;;
    124) error "a 40KB ${form:0:1}-quoted value took longer than 5s" ;;
    *) error "a 40KB ${form:0:1}-quoted value failed (rc=$rc)" ;;
  esac
done

# Last assignment wins, as when the file is sourced.
printf 'KEY=first\nKEY=second\n' >"$tmp/t.env"
if [[ "$(resolve_env_value KEY DEFAULT "$tmp/t.env")" == "second" ]]; then ok "last assignment wins"; else error "last assignment did not win"; fi
# The environment beats the file.
if [[ "$(KEY=fromenv resolve_env_value KEY DEFAULT "$tmp/t.env")" == "fromenv" ]]; then ok "environment beats the file"; else error "environment did not win"; fi
if [[ "$(resolve_env_value MISSING DEFAULT "$tmp/t.env")" == "DEFAULT" ]]; then ok "a missing key gets the default"; else error "missing key did not default"; fi
if [[ "$(resolve_env_value KEY DEFAULT "$tmp/nope.env")" == "DEFAULT" ]]; then ok "a missing file gets the default"; else error "missing file did not default"; fi
# A key that is a prefix of another is not that key.
printf 'KEYS=wrong\n' >"$tmp/t.env"
if [[ "$(resolve_env_value KEY DEFAULT "$tmp/t.env")" == "DEFAULT" ]]; then ok "KEYS= is not KEY="; else error "KEYS= read as KEY="; fi

note "load_env"
printf 'LOADED_A=one\n' >"$tmp/l.env"
(
  set +o allexport
  load_env "$tmp/l.env"
  if [[ -o allexport ]]; then error "load_env left allexport on"; else ok "allexport off afterwards when it was off before"; fi
  if [[ "$(bash -c 'printf %s "${LOADED_A:-}"')" == "one" ]]; then ok "loaded values are exported"; else error "LOADED_A not exported"; fi
)
(
  set -o allexport
  load_env "$tmp/l.env"
  if [[ -o allexport ]]; then ok "a caller's allexport is left on"; else error "load_env turned off the caller's allexport"; fi
)

if [[ $failures -eq 0 ]]; then
  note "all env tests passed"
  exit 0
fi
note "$failures failure(s)"
exit 1
