#!/usr/bin/env bash
# SCRIPT: ollama_install_test.sh
# DESCRIPTION: ollama_install downloads the pinned Ollama archive from a stand-in
#   release server, checks it against the pinned SHA-256 and unpacks it, and
#   refuses a mismatch with nothing unpacked.
# USAGE: bash tests/ollama_install_test.sh
# ----------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/helpers.sh"
shlib_import logging ollama_install

failures=0
note() { echo "[ollama_install_test] $*"; }
check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    note "  ok  $1"
  else
    note "[ERROR] $1: expected [$2], got [$3]"
    failures=$((failures + 1))
  fi
}

if ! command -v shasum >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1; then
  note "SKIP: neither shasum nor openssl is installed"
  exit 0
fi
for tool in python3 zstd tar unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    note "SKIP: $tool is not installed"
    exit 0
  fi
done

tmp="$(mktemp -d)"
server_pid=""
cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# This machine, as the module sees it: Linux on x86_64, whatever it really is.
mkdir -p "$tmp/fake-bin"
printf '#!/bin/sh\ncase "$1" in -s) echo "${FAKE_OS:-Linux}" ;; -m) echo "${FAKE_ARCH:-x86_64}" ;; *) echo Linux ;; esac\n' >"$tmp/fake-bin/uname"
chmod +x "$tmp/fake-bin/uname"

# A release archive laid out as Ollama's: bin/ollama (and lib/ollama/).
mkdir -p "$tmp/build/bin" "$tmp/build/lib/ollama"
printf '#!/bin/sh\necho "ollama version is 0.40.0"\n' >"$tmp/build/bin/ollama"
chmod +x "$tmp/build/bin/ollama"
: >"$tmp/build/lib/ollama/libggml.so"
mkdir -p "$tmp/www/v0.40.0"
tar -c -C "$tmp/build" bin lib | zstd -q -o "$tmp/www/v0.40.0/ollama-linux-amd64.tar.zst"
good_sha="$(ollama_install_sha256 "$tmp/www/v0.40.0/ollama-linux-amd64.tar.zst")"
# The Windows zip: ollama.exe and lib/ollama/, built with Python's zipfile.
python3 - "$tmp/build" "$tmp/www/v0.40.0/ollama-windows-amd64.zip" <<'PY'
import sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w") as z:
    z.write(src + "/bin/ollama", "ollama.exe")
    z.write(src + "/lib/ollama/libggml.so", "lib/ollama/ggml-base.dll")
PY
win_sha="$(ollama_install_sha256 "$tmp/www/v0.40.0/ollama-windows-amd64.zip")"
# The macOS archive, flat as the real one: the binary and what it loads beside it.
mkdir -p "$tmp/mac"
printf '#!/bin/sh\n[ -f "$(dirname "$0")/libggml-base.dylib" ] && echo "ollama version is 0.40.0" || echo "missing its libraries"\n' >"$tmp/mac/ollama"
chmod +x "$tmp/mac/ollama"; : >"$tmp/mac/libggml-base.dylib"; : >"$tmp/mac/llama-server"
tar -c -z -C "$tmp/mac" -f "$tmp/www/v0.40.0/ollama-darwin.tgz" ollama libggml-base.dylib llama-server
mac_sha="$(ollama_install_sha256 "$tmp/www/v0.40.0/ollama-darwin.tgz")"

# The stand-in release server; each request is logged.
cat >"$tmp/server.py" <<'PY'
import http.server, os, sys
root, log = sys.argv[1], sys.argv[2]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def log_message(self, fmt, *args):
        with open(log, "a") as f:
            f.write(self.path + "\n")
class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer looks up this machine's host name here (socket.getfqdn). On
        # a macOS CI runner that took longer than the test waited. The name is
        # not used, so only bind and store the address.
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[0], self.server_address[1]
s = Server(("127.0.0.1", 0), H)
with open(os.path.join(root, "..", "port"), "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$tmp/server.py" "$tmp/www" "$tmp/requests" &
server_pid=$!
# Up to 30 seconds: python can be slow to start on a busy runner.
for _ in $(seq 1 150); do [[ -s "$tmp/port" ]] && break; sleep 0.2; done
[[ -s "$tmp/port" ]] || { note "[ERROR] the stand-in release server did not start"; exit 1; }
OLLAMA_RELEASE_BASE_URL="http://127.0.0.1:$(cat "$tmp/port")"
export OLLAMA_RELEASE_BASE_URL
export CI_DEFAULT_OLLAMA_VERSION=0.40.0
export CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64="$good_sha"
export CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64="$win_sha"
export CI_DEFAULT_OLLAMA_SHA256_DARWIN="$mac_sha"

# The tools the installer needs, wherever this machine keeps them (Homebrew's
# zstd on macOS is not in /usr/bin), without the directory they came from: an
# ollama installed beside them must not be found.
mkdir -p "$tmp/tools"
for tool in zstd unzip curl shasum openssl; do
  found="$(command -v "$tool" 2>/dev/null)" || continue
  ln -s "$found" "$tmp/tools/$tool"
done
# Run with the fake uname first on PATH, and no real ollama on it.
run() { # run [args...]; prints the exit code
  local rc=0
  PATH="$tmp/fake-bin:$tmp/tools:/usr/bin:/bin" ollama_install "$@" >"$tmp/out" 2>&1 || rc=$?
  echo "$rc"
}
requests() { if [[ -f "$tmp/requests" ]]; then wc -l <"$tmp/requests" | tr -d ' '; else echo 0; fi; }

note "the checked install"
if command -v ollama >/dev/null 2>&1 && [[ "$(command -v ollama)" == /usr/bin/* || "$(command -v ollama)" == /bin/* ]]; then
  note "SKIP: an ollama in /usr/bin or /bin would be found; the install cases need a PATH without one"
else
  check "the pinned archive is downloaded, checked and unpacked into the prefix" "0:yes:yes" \
    "$(run --prefix "$tmp/p1"):$([[ -x "$tmp/p1/bin/ollama" ]] && echo yes || echo no):$([[ -f "$tmp/p1/lib/ollama/libggml.so" ]] && echo yes || echo no)"
  check "it asked for the pinned version's archive" "1" "$(grep -c '^/v0.40.0/ollama-linux-amd64.tar.zst$' "$tmp/requests")"
  check "a mismatch installs nothing" "1:no" \
    "$(CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64="$(printf '0%.0s' $(seq 1 64))" run --prefix "$tmp/p2"):$([[ -e "$tmp/p2/bin/ollama" ]] && echo yes || echo no)"
  check "and says so, with both checksums" "1" "$(grep -c 'does not match the pinned SHA-256' "$tmp/out")"
  check "an archive with no pin is not downloaded" "3:$(requests)" "$(CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64="" run --prefix "$tmp/p3"):$(requests)"
  check "a platform with no archive gets the official installer named, and nothing is downloaded" "3:1:$(requests)" \
    "$(FAKE_OS=FreeBSD run --prefix "$tmp/p4"):$(grep -c 'ollama.com/download' "$tmp/out"):$(requests)"
  check "an architecture with no archive too" "3" "$(FAKE_ARCH=riscv64 run --prefix "$tmp/p5")"
  check "an unknown option is refused" "3" "$(run --nope)"
  # A prefix whose parent does not exist yet, under a directory this user cannot
  # write: root is needed. With no sudo on PATH it says so and installs nothing.
  mkdir -p "$tmp/ro"; chmod 0555 "$tmp/ro"
  if [[ "$(id -u)" -ne 0 ]]; then
    # Everything from /usr/bin and /bin but sudo.
    mkdir -p "$tmp/no-sudo"
    for f in /usr/bin/* /bin/*; do
      name="${f##*/}"
      [[ "$name" == sudo || -e "$tmp/no-sudo/$name" ]] || ln -s "$f" "$tmp/no-sudo/$name" 2>/dev/null || true
    done
    rc=0; PATH="$tmp/fake-bin:$tmp/tools:$tmp/no-sudo" "$BASH" -c 'source "$1/helpers.sh"; shlib_import logging ollama_install; ollama_install --prefix "$2"' _ "$ROOT" "$tmp/ro/a/b" >"$tmp/out" 2>&1 || rc=$?
    check "an unwritable directory above a prefix still to be made needs root" "3:1" "$rc:$(grep -c 'not writable and sudo is not there' "$tmp/out")"
    rc=0; PATH="$tmp/fake-bin:$tmp/tools:$tmp/no-sudo" "$BASH" -c 'source "$1/helpers.sh"; shlib_import logging ollama_install; ollama_install --prefix "$2"' _ "$ROOT" "$tmp/mine/new/deep" >"$tmp/out" 2>&1 || rc=$?
    check "a writable directory above it needs no root, however deep the prefix" "0:yes" "$rc:$([[ -x "$tmp/mine/new/deep/bin/ollama" ]] && echo yes || echo no)"
  fi
  chmod 0755 "$tmp/ro"
  check "a failed download is 1, nothing unpacked" "1:no" \
    "$(OLLAMA_RELEASE_BASE_URL="http://127.0.0.1:1" run --prefix "$tmp/p6"):$([[ -e "$tmp/p6/bin/ollama" ]] && echo yes || echo no)"

  check "a release the server does not have (404) is 1, nothing unpacked" "1:no" \
    "$(CI_DEFAULT_OLLAMA_VERSION=9.9.9 run --prefix "$tmp/p10"):$([[ -e "$tmp/p10/bin/ollama" ]] && echo yes || echo no)"
  check "and says the download failed, not that a web page did not match" "1:0" "$(grep -c 'download failed' "$tmp/out"):$(grep -c 'does not match' "$tmp/out")"
  note "Windows (Git Bash, MSYS, Cygwin)"
  mkdir -p "$tmp/winget-bin"
  printf '#!/bin/sh\necho "$@" >>"%s/winget-calls"\nexit "${FAKE_WINGET_RC:-0}"\n' "$tmp" >"$tmp/winget-bin/winget"; chmod +x "$tmp/winget-bin/winget"
  before="$(requests)"
  rc=0; FAKE_OS=MINGW64_NT-10.0 LOCALAPPDATA="$tmp/appdata" PATH="$tmp/fake-bin:$tmp/winget-bin:$tmp/tools:/usr/bin:/bin" ollama_install >"$tmp/out" 2>&1 || rc=$?
  check "winget when it is there: Ollama's own package, nothing downloaded here" "0:1:$before" \
    "$rc:$(grep -c -- '--id Ollama.Ollama -e' "$tmp/winget-calls" 2>/dev/null):$(requests)"
  rc=0; FAKE_WINGET_RC=1 FAKE_OS=MINGW64_NT-10.0 LOCALAPPDATA="$tmp/appdata" PATH="$tmp/fake-bin:$tmp/winget-bin:$tmp/tools:/usr/bin:/bin" ollama_install >"$tmp/out" 2>&1 || rc=$?
  check "a failed winget falls back to the checked zip, per user" "0:yes:yes" \
    "$rc:$([[ -f "$tmp/appdata/Programs/Ollama/ollama.exe" ]] && echo yes || echo no):$([[ -f "$tmp/appdata/Programs/Ollama/lib/ollama/ggml-base.dll" ]] && echo yes || echo no)"
  check "(it asked for the Windows zip of the pinned version)" "1" "$(grep -c '^/v0.40.0/ollama-windows-amd64.zip$' "$tmp/requests")"
  rc=0; FAKE_OS=MSYS_NT-10.0 PATH="$tmp/fake-bin:$tmp/tools:/usr/bin:/bin" ollama_install --prefix "$tmp/win2" >"$tmp/out" 2>&1 || rc=$?
  check "without winget, or with --prefix: the zip into that prefix" "0:yes" "$rc:$([[ -f "$tmp/win2/ollama.exe" ]] && echo yes || echo no)"
  rc=0; CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64="$good_sha" FAKE_OS=CYGWIN_NT-10.0 PATH="$tmp/fake-bin:$tmp/tools:/usr/bin:/bin" ollama_install --prefix "$tmp/win3" >"$tmp/out" 2>&1 || rc=$?
  check "a Windows zip that does not match is not unpacked" "1:no" "$rc:$([[ -e "$tmp/win3/ollama.exe" ]] && echo yes || echo no)"
  check "an ARM Windows machine has its own pinned zip" "ollama-windows-arm64.zip:yes" \
    "$(FAKE_OS=MINGW64_NT-10.0 FAKE_ARCH=aarch64 PATH="$tmp/fake-bin:$PATH" ollama_install_asset):$([[ "$CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64" =~ ^[0-9a-f]{64}$ ]] && echo yes || echo no)"

  note "macOS without Homebrew"
  rc=0; FAKE_OS=Darwin FAKE_ARCH=arm64 PATH="$tmp/fake-bin:$tmp/tools:/usr/bin:/bin" ollama_install --prefix "$tmp/mac1" >"$tmp/out" 2>&1 || rc=$?
  check "the whole archive is installed, and bin/ollama runs it beside its libraries" "0:yes:ollama version is 0.40.0" \
    "$rc:$([[ -f "$tmp/mac1/lib/ollama/llama-server" ]] && echo yes || echo no):$("$tmp/mac1/bin/ollama" --version 2>&1)"

  note "what is installed already"
  mkdir -p "$tmp/have"
  printf '#!/bin/sh\necho "ollama version is %s"\n' 0.40.0 >"$tmp/have/ollama"; chmod +x "$tmp/have/ollama"
  before="$(requests)"
  rc=0; PATH="$tmp/fake-bin:$tmp/have:$tmp/tools:/usr/bin:/bin" ollama_install --prefix "$tmp/p7" >"$tmp/out" 2>&1 || rc=$?
  check "the pinned version on PATH: nothing to do, nothing downloaded" "0:$before:no" "$rc:$(requests):$([[ -e "$tmp/p7" ]] && echo yes || echo no)"
  printf '#!/bin/sh\necho "Warning: could not connect to a running Ollama instance"\necho "Warning: client version is 0.30.2"\n' >"$tmp/have/ollama"
  rc=0; PATH="$tmp/fake-bin:$tmp/have:$tmp/tools:/usr/bin:/bin" ollama_install --prefix "$tmp/p8" >"$tmp/out" 2>&1 || rc=$?
  check "an older one (read while no server runs) is replaced" "0:yes" "$rc:$([[ -x "$tmp/p8/bin/ollama" ]] && echo yes || echo no)"
  printf '#!/bin/sh\necho "ollama version is 0.40.0"\n' >"$tmp/have/ollama"
  rc=0; PATH="$tmp/fake-bin:$tmp/have:$tmp/tools:/usr/bin:/bin" ollama_install --prefix "$tmp/p9" --force >"$tmp/out" 2>&1 || rc=$?
  check "--force installs over the same version" "0:yes" "$rc:$([[ -x "$tmp/p9/bin/ollama" ]] && echo yes || echo no)"
fi

note "versions"
at_least() { if _ollama_install_at_least "$1" "$2"; then echo yes; else echo no; fi; }
check "equal, newer patch, newer minor by number not text, major" "yes yes yes yes" \
  "$(at_least 0.40.0 0.40.0) $(at_least 0.40.1 0.40.0) $(at_least 0.100.0 0.40.0) $(at_least 1.0.0 0.40.0)"
check "older, and what is not a version" "no no no" "$(at_least 0.39.9 0.40.0) $(at_least 0.9.0 0.40.0) $(at_least x.y.z 0.40.0)"
check "leading zeros are not octal" "yes" "$(at_least 0.08.0 0.8.0)"

note "the pins"
for name in CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64 CI_DEFAULT_OLLAMA_SHA256_LINUX_ARM64 CI_DEFAULT_OLLAMA_SHA256_DARWIN CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64; do
  value="$(env -u "$name" bash -c 'source "$1/lib/ci_defaults.sh"; printf "%s" "${!2}"' _ "$ROOT" "$name")"
  check "$name is a SHA-256" "yes" "$([[ "$value" =~ ^[0-9a-f]{64}$ ]] && echo yes || echo no)"
done
# PowerShell carries its own copy of the Windows pins: they must be the same.
ps_pins="$(grep -E "CI_DEFAULT_OLLAMA_(VERSION|SHA256_WINDOWS_[A-Z0-9]+) = " "$ROOT/ps/lib/ci_defaults.ps1" | sed -E "s/^\\\$env:(CI_DEFAULT_OLLAMA_[A-Z0-9_]+) = .* else \{ '([^']+)' \}.*/\1=\2/" | sort)"
sh_pins="$(env -u CI_DEFAULT_OLLAMA_VERSION -u CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 -u CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64 bash -c 'source "$1/lib/ci_defaults.sh"; for n in CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64 CI_DEFAULT_OLLAMA_VERSION; do printf "%s=%s\n" "$n" "${!n}"; done' _ "$ROOT" | sort)"
check "the PowerShell pins equal the Bash pins" "$sh_pins" "$ps_pins"
check "the version is pinned in one place" "1" "$(grep -rl --include=*.sh 'CI_DEFAULT_OLLAMA_VERSION:-[0-9]' "$ROOT/lib" "$ROOT/scripts" | wc -l | tr -d ' ')"
check "no library code pipes a download into a shell" "" \
  "$(grep -rn -E 'curl[^|#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh\b' "$ROOT/lib" "$ROOT/scripts" | grep -v -E ':[[:space:]]*#' || true)"

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
