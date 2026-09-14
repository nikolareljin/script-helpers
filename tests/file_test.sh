#!/usr/bin/env bash
# SCRIPT: file_test.sh
# DESCRIPTION: Tests for lib/file.sh -- download failures, per-file checksum verification, download_iso skip.
# USAGE: ./tests/file_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/file_test.sh
# ----------------------------------------------------
#
# Each of these failed by succeeding: a 404 page saved as the download with
# exit 0, a checksum "verified" because some other file in the list matched,
# and a download that said it was skipped and then ran.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[file_test] $*"; }
error() { echo "[file_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[file_test]   ok  $*"; }

tmp="$(mktemp -d)"
server_pid=""
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging file

note "download_file"
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  mkdir -p "$tmp/www"; printf 'payload' >"$tmp/www/present.bin"
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  ( cd "$tmp/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  server_pid=$!
  for _attempt in $(seq 1 50); do
    curl -fsS --max-time 1 "http://127.0.0.1:$port/present.bin" >/dev/null 2>&1 && break
    sleep 0.1
  done
  rc=0; DOWNLOAD_USE_DIALOG=never download_file "http://127.0.0.1:$port/present.bin" "$tmp/ok.bin" 2>/dev/null || rc=$?
  if [[ "$rc" == "0" && "$(cat "$tmp/ok.bin" 2>/dev/null)" == "payload" ]]; then ok "a 200 is saved, exit 0"; else error "200 download rc=$rc"; fi
  rc=0; DOWNLOAD_USE_DIALOG=never download_file "http://127.0.0.1:$port/missing.iso" "$tmp/missing.iso" 2>/dev/null || rc=$?
  if [[ "$rc" != "0" ]]; then ok "a 404 is a failure"; else error "a 404 returned 0"; fi
  if [[ ! -e "$tmp/missing.iso" ]]; then ok "no error page left at the output path"; else error "404 body saved: $(head -c 60 "$tmp/missing.iso")"; fi
  kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; server_pid=""
else
  note "SKIP download_file: needs python3 and curl"
fi

note "verify_checksum"
# POSIX cksum as the checksum tool: its first field is a number, which reads
# as a hash the same way, and it exists on every platform this library runs on.
if command -v cksum >/dev/null 2>&1; then
  # `file` is what is_valid_iso and is_valid_checksum consult; a stand-in keeps
  # the test off real ISO images.
  # shellcheck disable=SC2317
  file() { case "$1" in *.iso) echo "$1: ISO 9660 CD-ROM filesystem data" ;; *) echo "$1: ASCII text" ;; esac; }
  cd "$tmp" || exit 1
  printf 'good bytes' >other.iso
  printf 'target bytes' >target.iso
  good="$(cksum target.iso | awk '{print $1}')"
  other="$(cksum other.iso | awk '{print $1 "  " $3}')"
  zeros="0000000000"

  check() {
    local label="$1" want="$2" list="$3" target="${4:-target.iso}"
    printf '%s' "$list" >SUMS
    local rc=0
    verify_checksum "$target" SUMS cksum >/dev/null 2>&1 || rc=$?
    if [[ "$want" == "pass" && "$rc" == "0" ]] || [[ "$want" == "fail" && "$rc" != "0" ]]; then ok "$label"; else error "$label: rc=$rc"; fi
  }
  check "the right hash passes" pass "$other"$'\n'"$good  target.iso"$'\n'
  check "a wrong hash fails although another entry is OK" fail "$other"$'\n'"$zeros  target.iso"$'\n'
  check "a list that never names the file fails" fail "$other"$'\n'
  check "binary-mode entries (*name) are read" pass "$good *target.iso"$'\n'
  check "a listed path matches on its basename" pass "$good  ./isos/target.iso"$'\n'
  check "tagged ALGO (name) = HASH entries are read" pass "CKSUM (target.iso) = $good"$'\n'
  check "a CRLF list is read" pass "$good  target.iso"$'\r\n'
  check "a longer name sharing the prefix is not the file" fail "$good  target.iso.bak"$'\n'
  # Hex digests compare case-insensitively; the tool is a stand-in printing one.
  # shellcheck disable=SC2317
  hexsum() { echo "ABCDEF0123  $1"; }
  printf '%s' "abcdef0123  target.iso"$'\n' >SUMS
  rc=0; verify_checksum target.iso SUMS hexsum >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "0" ]]; then ok "hashes compare case-insensitively"; else error "hex case: rc=$rc"; fi
  mkdir -p sub && cp target.iso sub/
  check "the file is hashed where it is, not in the cwd" pass "$good  target.iso"$'\n' sub/target.iso
  cd "$root_dir" || exit 1
  unset -f file
else
  note "SKIP verify_checksum: needs cksum"
fi

note "download_iso"
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  (
    cd "$tmp" || exit 1
    # download_iso reads ${DISTROS[$name]}. An indexed array stands in for the
    # caller's associative one: with `demo` unset the subscript is 0, which is
    # enough to reach the skip logic under test.
    set +u
    DISTROS=("http://example.invalid/demo.iso")
    calls=0
    # shellcheck disable=SC2317
    download_file() { calls=$((calls+1)); printf 'x' >"$2"; }
    # shellcheck disable=SC2317
    file() { echo "$1: ISO 9660 CD-ROM filesystem data"; }
    printf 'existing' >demo.iso
    rc=0; download_iso demo >/dev/null 2>&1 || rc=$?
    if [[ "$calls" == "0" && "$(cat demo.iso)" == "existing" && "$rc" == "0" ]]; then echo "ok"; else echo "calls=$calls rc=$rc content=$(cat demo.iso)"; fi
  ) >"$tmp/iso.out" 2>&1
  if [[ "$(cat "$tmp/iso.out")" == "ok" ]]; then ok "an existing ISO is not downloaded again"; else error "download_iso with an existing file: $(cat "$tmp/iso.out")"; fi
else
  note "SKIP download_iso: needs bash 4 (DISTROS associative array)"
fi

if [[ $failures -eq 0 ]]; then
  note "all file tests passed"
  exit 0
fi
note "$failures failure(s)"
exit 1
