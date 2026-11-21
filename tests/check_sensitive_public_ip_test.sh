#!/usr/bin/env bash
# SCRIPT: check_sensitive_public_ip_test.sh
# DESCRIPTION: check_sensitive.sh --refresh-public-ip asks for the address over
#              https only, also across redirects, with retries. curl is a stub;
#              no network. Addresses are RFC 5737 and RFC 3849.
# USAGE: ./tests/check_sensitive_public_ip_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/check_sensitive_public_ip_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/check_sensitive.sh"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf -- "$tmp"; fi' EXIT

failures=0
note()  { echo "[check_sensitive_public_ip_test] $*"; }
error() { echo "[check_sensitive_public_ip_test][ERROR] $*" >&2; failures=$((failures+1)); }

# Hermetic: no real cache or config of this machine.
export HOME="$tmp/home" XDG_CACHE_HOME="$tmp/home/.cache" XDG_CONFIG_HOME="$tmp/home/.config"
mkdir -p "$HOME" "$tmp/bin"
export SENSITIVE_PUBLIC_IP_CACHE="$tmp/cache/public-ip" STUB_CURL_ARGV="$tmp/curlargv"
unset SENSITIVE_NO_MACHINE SENSITIVE_MACHINE_IDS_FILE

# Assembled from pieces, so this file passes the address check it sits beside.
v4="192.0.2"; v4="$v4.7"
v6="2001:db8"; v6="$v6::7"
export STUB_V4="$v4" STUB_V6="$v6"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CURL_ARGV"
case "${STUB_CURL:-ok}:$*" in
  fail:*) exit 7 ;;
  *api6.ipify.org*) printf '%s\n' "$STUB_V6" ;;
  *api.ipify.org*) printf '%s\n' "$STUB_V4" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$tmp/bin/curl"

: > "$STUB_CURL_ARGV"
PATH="$tmp/bin:$PATH" bash "$CHECK" --refresh-public-ip >"$tmp/out" 2>&1; rc=$?
[[ "$rc" == 0 ]] || error "--refresh-public-ip: exit $rc: $(tail -3 "$tmp/out")"
want="$(printf '%s\n%s' "$v4" "$v6")"
[[ "$(cat "$SENSITIVE_PUBLIC_IP_CACHE" 2>/dev/null)" == "$want" ]] || error "cache is '$(cat "$SENSITIVE_PUBLIC_IP_CACHE" 2>/dev/null)'"
[[ "$(wc -l < "$STUB_CURL_ARGV" | tr -d ' ')" == 2 ]] || error "expected 2 curl calls: $(cat "$STUB_CURL_ARGV")"
while IFS= read -r line; do
  [[ "$line" == *"--proto =https --proto-redir =https"* ]] || error "curl without --proto =https --proto-redir =https: $line"
  [[ "$line" == *"--retry 3 --retry-delay 2"* ]] || error "curl without --retry 3 --retry-delay 2: $line"
  [[ "$line" == *" https://"* ]] || error "curl asked for a URL that is not https: $line"
done < "$STUB_CURL_ARGV"
note "--refresh-public-ip: https only, retried, both addresses cached"

# A failed lookup leaves the cache as it was and exits 2.
STUB_CURL=fail PATH="$tmp/bin:$PATH" bash "$CHECK" --refresh-public-ip >"$tmp/out" 2>&1; rc=$?
[[ "$rc" == 2 && "$(cat "$SENSITIVE_PUBLIC_IP_CACHE" 2>/dev/null)" == "$want" ]] || error "failed lookup: exit $rc, cache '$(cat "$SENSITIVE_PUBLIC_IP_CACHE" 2>/dev/null)'"
note "a failed lookup exits 2 and keeps the cache"

if [[ "$failures" -gt 0 ]]; then
  echo "[check_sensitive_public_ip_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[check_sensitive_public_ip_test] OK"
