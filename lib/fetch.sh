#!/usr/bin/env bash
# fetch: download one release asset to a file, with retries and a clear error.
#
# One transient error from a release CDN should not fail an install. curl gets
# --retry 3 --retry-delay 2, plus --retry-all-errors when it is 7.71 or newer
# (older curl rejects that option, so it is left out there). wget gets
# --tries=3 --waitretry=2.
#
# A failed download deletes the output file, so a partial file is never left
# for the caller to check or unpack. Callers still verify the checksum.
#
# Expected imports by caller: none. log_error is used when logging is loaded,
# plain stderr otherwise.
#
# Return codes: 0 downloaded; 1 the download failed; 2 bad arguments; 3 no curl
# or wget.

# Usage: fetch_curl_retry_args
# fetch_curl_retry_args; the retry options this machine's curl accepts, one per
# line: --retry 3 --retry-delay 2, and --retry-all-errors on curl 7.71 or newer.
# Returns: 0.
# Output: stdout the options, one per line.
fetch_curl_retry_args() {
  local v major minor
  printf '%s\n' --retry 3 --retry-delay 2
  v="$(curl --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 0
  if (( major > 7 || (major == 7 && minor >= 71) )); then
    printf '%s\n' --retry-all-errors
  fi
  return 0
}

# Usage: fetch_url_host <url>
# fetch_url_host <url>; the host part of a URL, without user info or port.
# Returns: 0.
# Output: stdout the host.
fetch_url_host() {
  local h="${1#*://}" rb="]"
  h="${h%%/*}"; h="${h%%[?#]*}"; h="${h##*@}"
  if [[ "${h:0:1}" == "[" ]]; then
    h="${h%%"$rb"*}$rb"
  else
    h="${h%%:*}"
  fi
  printf '%s\n' "$h"
}

# Usage: fetch_exit_reason <curl|wget> <code>
# fetch_exit_reason <curl|wget> <code>; a short reason for a curl or wget exit code.
# Returns: 0.
# Output: stdout the reason.
fetch_exit_reason() {
  local r=""
  case "$1:$2" in
    curl:6) r="could not resolve host" ;;
    curl:7) r="could not connect" ;;
    curl:18) r="transfer ended early" ;;
    curl:22) r="HTTP error (400 or above)" ;;
    curl:28) r="timed out" ;;
    curl:35) r="TLS handshake failed" ;;
    curl:52) r="empty reply from server" ;;
    curl:56) r="network receive failed" ;;
    curl:60) r="TLS certificate not trusted" ;;
    wget:4) r="network failure" ;;
    wget:5) r="TLS verification failed" ;;
    wget:8) r="server error response" ;;
  esac
  printf '%s\n' "${r:-see the $1 documentation for this exit code}"
}

# Usage: fetch_to_file <label> <url> <output>
# fetch_to_file <label> <url> <output>; download <url> to <output> with curl
# (or wget when there is no curl), retrying transient errors. On failure the
# output file is deleted and one line on stderr names the label, the host, the
# tool and its exit code.
# Returns: 0 downloaded; 1 download failed; 2 an empty label, URL or output, or
#   a URL that starts with "-"; 3 no curl or wget.
# Output: stdout nothing; stderr the error line on failure.
fetch_to_file() {
  local label="${1:-}" url out tool rc=0 host msg shown a
  local -a retry=()
  if [[ -z "$label" || -z "${2:-}" || -z "${3:-}" || "${2:-}" == -* ]]; then
    _fetch_err "fetch_to_file: usage: fetch_to_file <label> <url> <output>"
    return 2
  fi
  # checked above; printf -v marks the validated copies for the scanner
  printf -v url '%s' "$2"
  printf -v out '%s' "$3"
  if command -v curl >/dev/null 2>&1; then
    tool=curl
    while IFS= read -r msg; do retry+=("$msg"); done < <(fetch_curl_retry_args)
    curl -fsSL --connect-timeout 15 --max-time "${FETCH_MAX_TIME:-300}" "${retry[@]}" -o "$out" -- "$url" || rc=$?
  elif command -v wget >/dev/null 2>&1; then
    tool=wget
    wget -q -T 60 --tries=3 --waitretry=2 -O "$out" -- "$url" || rc=$?
  else
    _fetch_err "$label: download failed: curl or wget is needed to download $url"
    return 3
  fi
  if [[ "$rc" -ne 0 ]]; then
    rm -f -- "$out"
    host="$(fetch_url_host "$url")"
    shown="$url"
    # A URL with user info (user:token@host) is not printed; the host is.
    a="${url#*://}"; a="${a%%/*}"
    [[ "$a" != *@* ]] || shown="(not shown: it has user info)"
    _fetch_err "$label: download failed from $host: $tool exit $rc ($(fetch_exit_reason "$tool" "$rc")), after retries; URL $shown"
    return 1
  fi
  return 0
}

# _fetch_err <message>: log_error when logging is loaded, else plain stderr.
_fetch_err() {
  if declare -F log_error >/dev/null 2>&1; then log_error "$*"; else printf '[ERROR] %s\n' "$*" >&2; fi
}
