#!/usr/bin/env bash
# SCRIPT: ollama_install_check.sh
# DESCRIPTION: Real-machine check of ollama_install on Linux or macOS: downloads the pinned Ollama release, installs it into throwaway directories, and checks install, verify, refuse, upgrade and staging. Nothing outside those directories is touched.
# USAGE: bash tests/machine/ollama_install_check.sh [--keep] [-h]
# PARAMETERS:
#   --keep      Leave the throwaway directory for inspection (its path is printed).
#   -h, --help  Show this help.
# EXIT_CODES:
#   0  every case passed
#   1  a case failed
#   2  bad arguments, or this machine cannot run the check (no network, no tool)
# EXAMPLE:
#   bash tests/machine/ollama_install_check.sh
# ----------------------------------------------------
# Not part of `make test`: it downloads the real release (about 1.4 GB on Linux,
# 170 MB on macOS) and runs the real binary. The Ollama on PATH, if any, and its
# models and service are not touched: every install goes into a directory made
# here, with --prefix, and PATH is narrowed so that the installed one is not seen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
keep=false
for arg in "$@"; do
  case "$arg" in
    --keep) keep=true ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
source "$ROOT/helpers.sh"
shlib_import logging ollama_install

passed=0
failed=0
case_() { # case_ <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %s\n' "$1"; passed=$((passed + 1))
  else
    printf 'FAIL  %s\n      expected [%s]\n      got      [%s]\n' "$1" "$2" "$3"; failed=$((failed + 1))
  fi
}

work="$(mktemp -d)"
cleanup() {
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  if [[ "$keep" == true ]]; then echo "kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

os="$(uname -s)"
asset="$(ollama_install_asset)" || { echo "SKIP: no checkable Ollama archive for $os $(uname -m)"; exit 2; }
pinned="$CI_DEFAULT_OLLAMA_VERSION"
echo "machine: $os $(uname -m), bash $BASH_VERSION; asset $asset; pinned $pinned"
for tool in curl tar; do command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not installed"; exit 2; }; done
curl -fsSI -o /dev/null "https://github.com/ollama/ollama/releases/download/v${pinned}/${asset}" \
  || { echo "SKIP: the release cannot be reached from here"; exit 2; }

# PATH without any installed Ollama: the tools this check and the installer
# use, linked one by one from wherever this machine keeps them.
mkdir -p "$work/path"
for tool in bash sh env cat cp mv rm mkdir rmdir ln ls chmod mktemp dirname basename head tail tr sed awk grep sort \
            uname id curl tar gzip zstd unzip shasum openssl install printf sleep date wc cut xargs find touch; do
  found="$(command -v "$tool" 2>/dev/null)" || continue
  [[ "$found" == /* ]] && ln -s "$found" "$work/path/$tool"
done
CLEAN_PATH="$work/path"
run() { # run <dir on PATH, or ""> <args...>: ollama_install in a clean shell; prints rc, output in $work/out
  local extra="$1" rc=0; shift
  PATH="${extra:+$extra:}$CLEAN_PATH" "$CLEAN_PATH/bash" -c \
    'source "$1/helpers.sh"; shlib_import logging ollama_install; shift; ollama_install "$@"' _ "$ROOT" "$@" >"$work/out" 2>&1 || rc=$?
  echo "$rc"
}
# The binary's own version, not a running server's (see ollama_installed_version).
version_of() { ollama_installed_version "$1" || true; }

echo
echo "1. install the real release into an empty directory"
rc="$(run "" --prefix "$work/a")"
case_ "install exits 0" "0" "$rc"
case_ "bin/ollama runs and reports the pinned version" "$pinned" "$(version_of "$work/a/bin/ollama")"
case_ "its libraries are in lib/ollama" "yes" "$([[ -n "$(ls -A "$work/a/lib/ollama" 2>/dev/null)" ]] && echo yes || echo no)"
if [[ "$rc" != 0 ]]; then sed 's/^/      /' "$work/out" | tail -n 5; fi

echo
echo "2. run again with that Ollama on PATH: nothing to do, nothing downloaded"
rc="$(run "$work/a/bin" --prefix "$work/a")"
case_ "exits 0 and says there is nothing to do" "0:1" "$rc:$(grep -c 'nothing to do' "$work/out")"
case_ "no download" "0" "$(grep -c 'Downloading' "$work/out")"

# What case 1 installed, packed again in the release's layout and served from a
# file: the remaining cases need no second download.
echo
echo "3. a damaged archive, and one that does not match the pin"
mkdir -p "$work/www/v$pinned"
case "$asset" in
  *.tar.zst) tar -c -C "$work/a" bin lib | zstd -q -o "$work/www/v$pinned/$asset" ;;
  *.tgz)     tar -c -z -C "$work/a/lib/ollama" -f "$work/www/v$pinned/$asset" . ;;
esac
good="$(ollama_install_sha256 "$work/www/v$pinned/$asset")"
local_url="file://$work/www"
mkdir -p "$work/b/lib/ollama"; echo old >"$work/b/lib/ollama/marker"
rc="$(OLLAMA_RELEASE_BASE_URL="$local_url" CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64="$(printf '0%.0s' $(seq 1 64))" \
  CI_DEFAULT_OLLAMA_SHA256_LINUX_ARM64="$(printf '0%.0s' $(seq 1 64))" CI_DEFAULT_OLLAMA_SHA256_DARWIN="$(printf '0%.0s' $(seq 1 64))" \
  run "" --prefix "$work/b")"
case_ "a mismatch is refused (1) and the installed copy is untouched" "1:old" "$rc:$(cat "$work/b/lib/ollama/marker" 2>/dev/null)"
cp "$work/www/v$pinned/$asset" "$work/$asset.good"
printf 'not an archive' >"$work/www/v$pinned/$asset"
bad="$(ollama_install_sha256 "$work/www/v$pinned/$asset")"
rc="$(OLLAMA_RELEASE_BASE_URL="$local_url" CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64="$bad" CI_DEFAULT_OLLAMA_SHA256_LINUX_ARM64="$bad" \
  CI_DEFAULT_OLLAMA_SHA256_DARWIN="$bad" run "" --prefix "$work/b")"
case_ "a damaged archive fails (1) before the installed copy is touched" "1:old" "$rc:$(cat "$work/b/lib/ollama/marker" 2>/dev/null)"
mv "$work/$asset.good" "$work/www/v$pinned/$asset"

echo
echo "4. upgrade an older install that is running"
mkdir -p "$work/c/bin" "$work/c/lib/ollama"
printf '#!/bin/sh\necho "ollama version is 0.1.0"\nexec sleep "${1:-0}"\n' >"$work/c/bin/ollama"; chmod +x "$work/c/bin/ollama"
echo stale >"$work/c/lib/ollama/stale-library"
"$work/c/bin/ollama" 60 >/dev/null & running=$!
rc="$(OLLAMA_RELEASE_BASE_URL="$local_url" CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64="$good" CI_DEFAULT_OLLAMA_SHA256_LINUX_ARM64="$good" \
  CI_DEFAULT_OLLAMA_SHA256_DARWIN="$good" run "$work/c/bin" --prefix "$work/c")"
kill "$running" 2>/dev/null || true; wait "$running" 2>/dev/null || true
case_ "the older one is upgraded while it runs" "0:$pinned" "$rc:$(version_of "$work/c/bin/ollama")"
case_ "the old libraries are gone" "no" "$([[ -e "$work/c/lib/ollama/stale-library" ]] && echo yes || echo no)"
case_ "it says a running Ollama keeps its version until restarted" "1" "$(grep -c 'until it is restarted' "$work/out")"

echo
echo "5. a prefix that would put shell code into the launcher is refused"
rc="$(run "" --prefix "$work/x\$(touch pwned)")"
case_ "refused (3), nothing run" "3:no" "$rc:$([[ -e "$work/pwned" || -e pwned ]] && echo yes || echo no)"

echo
echo "Not covered here, run by hand: Homebrew (macOS, no --prefix) and winget (Windows) upgrade"
echo "the Ollama they manage; see docs/modules/ollama_install.md."
echo
echo "summary: $passed passed, $failed failed ($os $(uname -m), pinned $pinned)"
[[ "$failed" -eq 0 ]]
