#!/usr/bin/env bash
# SCRIPT: node_key_check.sh
# DESCRIPTION: Downloads NodeSource's apt repository key, checks it against the pinned fingerprint and that it signs the pinned Node.js repository.
# USAGE: bash tests/machine/node_key_check.sh [--keep] [-h]
# PARAMETERS:
#   --keep      Leave the throwaway directory (its path is printed).
#   -h, --help  Show this help.
# EXIT_CODES:
#   0  every case passed
#   1  a case failed
#   2  bad arguments, or this machine cannot run it (no gpg, no curl or wget, no network)
# EXAMPLE:
#   bash tests/machine/node_key_check.sh
# ----------------------------------------------------
#
# Uses the network. tests/deps_node_test.sh stubs curl and gpg, so this is the
# only check that CI_DEFAULT_NODESOURCE_APT_FPR in lib/ci_defaults.sh is the
# key NodeSource serves, and that node_<CI_DEFAULT_NODE_APT_MAJOR>.x is signed
# by it. Runs fetch_verified_gpg_key, the code path lib/deps.sh uses, into a
# directory that is removed on exit. It installs nothing, writes nothing under
# /etc/apt and does not run apt; the stubbed test covers those steps.
# Entry script for the same feature: scripts/install_ollama_model.sh -i.
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
command -v gpg >/dev/null 2>&1 || { echo "SKIP: gpg is not installed"; echo "summary: skipped"; exit 2; }
dir="$(mktemp -d)"
trap 'if [[ $keep -eq 1 ]]; then echo "kept: $dir"; else rm -rf -- "$dir"; fi' EXIT
export TMPDIR="$dir"
# shellcheck source=/dev/null
source "$ROOT_DIR/helpers.sh"
shlib_import logging os deps
fails=0
url="https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"
release="https://deb.nodesource.com/node_${CI_DEFAULT_NODE_APT_MAJOR}.x/dists/nodistro/InRelease"

if ! fetch_to_file node_key_check "$release" "$dir/InRelease" 2>/dev/null; then
  echo "SKIP: cannot reach deb.nodesource.com"; echo "summary: skipped"; exit 2
fi

rc=0; fetch_verified_gpg_key node_key_check "$url" "$CI_DEFAULT_NODESOURCE_APT_FPR" "$dir/key.asc" || rc=$?
if [[ $rc -eq 0 && -s "$dir/key.asc" ]]; then echo "PASS key: the served key is the pinned fingerprint"
else echo "FAIL key: rc=$rc"; fails=$((fails+1)); fi

wrong="0000000000000000000000000000000000000000"
rc=0; fetch_verified_gpg_key node_key_check "$url" "$wrong" "$dir/wrong.asc" 2>/dev/null || rc=$?
if [[ $rc -eq 1 && ! -e "$dir/wrong.asc" ]]; then echo "PASS refusal: another fingerprint is refused, nothing written"
else echo "FAIL refusal: rc=$rc"; fails=$((fails+1)); fi

mkdir -m 700 "$dir/gnupg"
sig="$(gpg --homedir "$dir/gnupg" --batch --quiet --import "$dir/key.asc" >/dev/null 2>&1 \
  && gpg --homedir "$dir/gnupg" --batch --status-fd 1 --verify "$dir/InRelease" 2>/dev/null \
  | awk '$2 == "VALIDSIG" { print $NF }')"
if [[ "$sig" == "$CI_DEFAULT_NODESOURCE_APT_FPR" ]]; then echo "PASS signature: node_${CI_DEFAULT_NODE_APT_MAJOR}.x InRelease is signed by the pinned key"
else echo "FAIL signature: InRelease signed by '${sig:-nothing valid}'"; fails=$((fails+1)); fi

left="$(find "$dir" -maxdepth 1 -name 'shlib-gpg-key.*' | sed -n 1p)"
if [[ -z "$left" ]]; then echo "PASS cleanup: no key temp directory left"
else echo "FAIL cleanup: left $left"; fails=$((fails+1)); fi

echo "summary: $fails failed"
[[ $fails -eq 0 ]]
