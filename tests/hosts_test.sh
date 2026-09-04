#!/usr/bin/env bash
# SCRIPT: hosts_test.sh
# DESCRIPTION: Regression tests for lib/hosts.sh, chiefly the duplicate-entry bug.
# USAGE: bash tests/hosts_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging hosts

failures=0
note()  { echo "[hosts_test] $*"; }
error() { echo "[hosts_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
HOSTS_FILE="$tmp/hosts"; export HOSTS_FILE
printf '127.0.0.1\tlocalhost\n' > "$HOSTS_FILE"

# The bug this guards: the presence test used GNU \s, which BSD grep never
# matches, so a second call appended the domain again. It is silent on both
# platforms -- nothing errors, the file just grows.
add_to_etc_hosts demo.local 127.0.0.1 >/dev/null 2>&1
add_to_etc_hosts demo.local 127.0.0.1 >/dev/null 2>&1
add_to_etc_hosts demo.local 127.0.0.1 >/dev/null 2>&1

count="$(grep -c '[[:space:]]demo\.local$' "$HOSTS_FILE")"
if [[ "$count" -eq 1 ]]; then
  note "three calls produce exactly one entry"
else
  error "expected 1 entry for demo.local, found $count"
fi

if grep -q 'localhost' "$HOSTS_FILE"; then
  note "existing entries are preserved"
else
  error "pre-existing localhost line was lost"
fi

# A domain that is a prefix of another must not count as present.
add_to_etc_hosts demo.local.uk 127.0.0.2 >/dev/null 2>&1
if grep -q 'demo\.local\.uk' "$HOSTS_FILE"; then
  note "a longer domain sharing a prefix is still added"
else
  error "demo.local.uk was wrongly treated as already present"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
