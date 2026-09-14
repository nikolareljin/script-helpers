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

# A dot in a hostname is a regex metacharacter. Interpolated into a pattern,
# "demo.local" matches the literal "demoXlocal", so the real entry would be
# judged already present and silently never added.
#
# This needs a file that does NOT already contain demo.local, or the assertion
# passes either way and proves nothing.
wildcard="$tmp/hosts_wildcard"
printf '198.51.100.7\tdemoXlocal\n' > "$wildcard"
HOSTS_FILE="$wildcard" add_to_etc_hosts demo.local 127.0.0.1 >/dev/null 2>&1
if grep -q '[[:space:]]demo\.local$' "$wildcard"; then
  note "a dot is matched literally, not as a wildcard"
else
  error "demo.local was treated as present because 'demoXlocal' matched it as a regex"
fi

# A hostname that is only a substring of a token in the file is not present.
substr="$tmp/hosts_substr"
printf '198.51.100.8\tprefix.other.local\n' > "$substr"
HOSTS_FILE="$substr" add_to_etc_hosts other.local 127.0.0.1 >/dev/null 2>&1
if grep -q '[[:space:]]other\.local$' "$substr"; then
  note "a substring match does not count as present"
else
  error "other.local was treated as present because it is a substring of prefix.other.local"
fi

# Commented-out entries are not entries. In /etc/hosts everything from the
# first # is a comment, wherever on the line it appears.
for fixture in '# 1.2.3.4 commented.local' \
               '   # 1.2.3.4 commented.local' \
               '198.51.100.9\trealhost # commented.local'; do
  tmp2="$tmp/hosts_comment"; printf "$fixture\n" > "$tmp2"
  HOSTS_FILE="$tmp2" add_to_etc_hosts commented.local 127.0.0.1 >/dev/null 2>&1
  if [[ "$(grep -c '^127\.0\.0\.1' "$tmp2")" -eq 1 ]]; then
    note "not present in: ${fixture}"
  else
    error "treated as already present in: ${fixture}"
  fi
done

# A real entry on a line that also carries a comment is still an entry.
tmp3="$tmp/hosts_inline"; printf '198.51.100.10\tlive.local # a note\n' > "$tmp3"
HOSTS_FILE="$tmp3" add_to_etc_hosts live.local 127.0.0.1 >/dev/null 2>&1
if [[ "$(grep -c 'live\.local' "$tmp3")" -eq 1 ]]; then
  note "a host before an inline comment is still found"
else
  error "a host before an inline comment was duplicated"
fi

# A newline in the domain or IP wrote a second, attacker-chosen entry.
inj="$tmp/hosts_inj"; printf '127.0.0.1\tlocalhost\n' > "$inj"
HOSTS_FILE="$inj" add_to_etc_hosts $'myapp.local\n203.0.113.66 github.com' 127.0.0.1 >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 && "$(cat "$inj")" == $'127.0.0.1\tlocalhost' ]]; then
  note "a newline in the domain is refused (2), file unchanged"
else
  error "domain with a newline: rc=$rc file=$(cat "$inj")"
fi
HOSTS_FILE="$inj" add_to_etc_hosts safe.local $'127.0.0.1\n203.0.113.66 github.com' >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]] && ! grep -q github "$inj"; then note "a newline in the IP is refused (2)"; else error "IP with a newline: rc=$rc file=$(cat "$inj")"; fi
for bad in 'not-an-ip' '127.0.0.1 x' '1.2.3'; do
  HOSTS_FILE="$inj" add_to_etc_hosts safe.local "$bad" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 2 ]]; then note "invalid IP refused: $bad"; else error "invalid IP '$bad' returned $rc"; fi
done
HOSTS_FILE="$inj" add_to_etc_hosts v6.local ::1 >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '^::1[[:space:]]*v6\.local$' "$inj"; then note "an IPv6 address is accepted"; else error "IPv6 add: rc=$rc file=$(cat "$inj")"; fi

# The address column is not a name: a "domain" matching some line's IP is absent.
ipcol="$tmp/hosts_ipcol"; printf '198.51.100.5\tother\n' > "$ipcol"
HOSTS_FILE="$ipcol" add_to_etc_hosts 198.51.100.5 127.0.0.1 >/dev/null 2>&1
if [[ "$(grep -c '' "$ipcol")" -eq 2 ]]; then note "the IP column is not compared as a name"; else error "domain matched against the IP column: $(cat "$ipcol")"; fi

# A write that fails is a failure. No writable file and a sudo that fails: the
# old code printed "Added" and returned 0. A path in a missing directory is
# unwritable even for root, so this holds inside a container too.
mkdir -p "$tmp/fakebin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/fakebin/sudo"; chmod +x "$tmp/fakebin/sudo"
out="$(PATH="$tmp/fakebin:$PATH" HOSTS_FILE="$tmp/no-such-dir/hosts" add_to_etc_hosts demo.local 127.0.0.1 2>&1)"; rc=$?
if [[ "$rc" -eq 1 && "$out" != *Added* ]]; then note "a failed sudo tee returns 1 and does not claim success"; else error "failed write: rc=$rc out=$out"; fi

# Missing arguments must be an error, not an abort in the caller under set -u.
out="$(bash -c 'set -u; source ./helpers.sh; shlib_import logging hosts; add_to_etc_hosts; echo "rc=$?"' 2>&1)"
case "$out" in
  *"unbound variable"*) error "missing arguments aborted the caller: $out" ;;
  *rc=2*) note "missing arguments return 2 under set -u" ;;
  *) error "missing arguments did not return 2: $out" ;;
esac

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
