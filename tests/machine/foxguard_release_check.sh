#!/usr/bin/env bash
# SCRIPT: foxguard_release_check.sh
# DESCRIPTION: Downloads the pinned foxguard release, checks its SHA-256 and that it reports the pinned version.
# USAGE: bash tests/machine/foxguard_release_check.sh [--keep] [-h]
# PARAMETERS:
#   --keep      Leave the throwaway cache directory (its path is printed).
#   -h, --help  Show this help.
# EXIT_CODES:
#   0  every case passed
#   1  a case failed
#   2  bad arguments, or this machine cannot run it (no curl or sha256 tool, or no release binary for this platform)
# EXAMPLE:
#   bash tests/machine/foxguard_release_check.sh
# ----------------------------------------------------
#
# Uses the network. tests/ci_security_foxguard_test.sh stubs curl, so this is
# the only check that the checksums in lib/ci_defaults.sh match the release.
# Runs foxguard_install, the code path ci_security.sh uses, into a throwaway
# cache that is removed on exit. It does not run a scan; the stubbed test covers that.
# Entry script for the same feature: scripts/ci_security.sh --install-foxguard.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
keep=0
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
XDG_CACHE_HOME="$(mktemp -d)"; export XDG_CACHE_HOME
trap 'if [[ $keep -eq 1 ]]; then echo "kept: $XDG_CACHE_HOME"; else rm -rf "$XDG_CACHE_HOME"; fi' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/helpers.sh"
shlib_import logging foxguard
fails=0
rc=0; foxguard_install || rc=$?
if [[ $rc -eq 3 ]]; then echo "SKIP install: this machine cannot run it (rc 3)"; echo "summary: skipped"; exit 2; fi
if [[ $rc -eq 0 ]]; then echo "PASS install: downloaded, SHA-256 matches the pin"
else echo "FAIL install: rc=$rc"; fails=$((fails+1)); fi
bin="$(foxguard_cache_path)"
want="foxguard $CI_DEFAULT_FOXGUARD_VERSION"
got="$("$bin" --version 2>&1 | tr -d '\r')" || true
if [[ "$got" == "$want" ]]; then echo "PASS version: $got"
else echo "FAIL version: got '$got', want '$want'"; fails=$((fails+1)); fi
echo "summary: $fails failed"
[[ $fails -eq 0 ]]
