#!/usr/bin/env bash
# SCRIPT: check_no_private_ips.sh
# DESCRIPTION: Fail when an RFC 1918 private-range IP literal appears in a tracked file.
# USAGE: scripts/check_no_private_ips.sh [--repo <path>] [--path <dir>] [-h]
# PARAMETERS:
#   --repo <path>   Repository to scan (default: cwd). Scans `git ls-files`.
#   --path <dir>    Scan a directory instead of the git index. For exercising
#                   the check against a known-bad fixture.
#   -h, --help      Show this help message.
# ----------------------------------------------------
#
# Wireless adb makes a device's LAN address part of everyday development, and
# that address then wants to end up in a README, a test fixture or a CI file.
# It belongs in a gitignored env file and nowhere else.
#
# Why a gate rather than a rule people remember: an address in a tracked file is
# a small permanent disclosure about someone's private network, it is invisible
# in review because it looks like configuration, and once copied into docs it
# lives there for years. It also blocks a repo from being opened up without an
# audit first.
#
# Scans the git index, NOT the working tree. Untracked and ignored files are
# exactly where a real address is supposed to live, so scanning the tree would
# flag `.env` itself and teach everyone to skip the check.
#
# Ranges are RFC 1918: 10/8, 172.16/12, 192.168/16. Loopback and the RFC 5737
# documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) are
# deliberately allowed — they are what a tracked example should use.
# ----------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging >/dev/null 2>&1 || true
type log_info >/dev/null 2>&1 || log_info() { printf '[INFO] %s\n' "$*"; }
type log_error >/dev/null 2>&1 || log_error() { printf '[ERROR] %s\n' "$*" >&2; }

REPO=""
SCAN_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    --path) SCAN_PATH="${2:?--path needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) log_error "Unknown argument: $1"; exit 2 ;;
  esac
done

# Full dotted quads only. Requiring four octets keeps version strings such as
# "10.0.2" or "flutter 3.44.7" out of the results.
PATTERN='\b(192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})\b'

hits=""
if [[ -n "$SCAN_PATH" ]]; then
  hits="$(grep -rnEI "$PATTERN" "$SCAN_PATH" 2>/dev/null || true)"
else
  cd "${REPO:-.}" || { log_error "No such directory: ${REPO:-.}"; exit 2; }
  hits="$(git ls-files -z 2>/dev/null | xargs -0 grep -nEI "$PATTERN" 2>/dev/null || true)"
fi

if [[ -n "$hits" ]]; then
  log_error "Private-range IP literal in a tracked file:"
  printf '%s\n' "$hits" | sed 's/^/      /'
  log_error "Move the address to a gitignored env file and reference it by variable."
  log_error "Tracked examples must use RFC 5737 (192.0.2.x / 198.51.100.x /"
  log_error "203.0.113.x), an mDNS .local name, or loopback."
  exit 1
fi

log_info "no private-range IP literals in tracked files"
