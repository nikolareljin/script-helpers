#!/usr/bin/env bash
# SCRIPT: gitleaks_install_test.sh
# DESCRIPTION: Tests lib/gitleaks.sh (pinned install) and preflight installing a missing gitleaks.
# USAGE: bash tests/gitleaks_install_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/gitleaks_install_test.sh
# ----------------------------------------------------
#
# A stub curl serves a fake release archive, so nothing goes to the network.
# A stub uname picks the platform, so the asset names of all three are checked
# on any machine.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[gitleaks_install_test] $*"; }
error() { echo "[gitleaks_install_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# A PATH with no gitleaks and no foxguard: every tool the scripts use, linked
# one by one, so a gitleaks in /bin or /usr/bin cannot leak in.
mkdir -p "$tmp/bin"
for c in bash sh git env dirname basename mktemp head tail rm cat grep sed awk tr \
         uname find sort date mkdir id chmod mv cp tar gzip shasum openssl ls wc cut \
         printf tee touch sleep sha256sum; do
  p="$(command -v "$c" 2>/dev/null)" && [[ "$p" == /* ]] && ln -sf "$p" "$tmp/bin/$c"
done

# The fake release: a gitleaks that reports clean, or a finding on LEAKME.
mkdir -p "$tmp/rel"
cat > "$tmp/rel/gitleaks" <<'EOF'
#!/usr/bin/env bash
echo "fake gitleaks $*" >> "${GL_LOG:-/dev/null}"
if git ls-files -z 2>/dev/null | xargs -0 grep -l LEAKME >/dev/null 2>&1; then echo "leaks found: 1"; exit 1; fi
echo "no leaks found"
EOF
chmod +x "$tmp/rel/gitleaks"
tar -czf "$tmp/rel/archive.tar.gz" -C "$tmp/rel" gitleaks
GOOD_SHA="$(source "$ROOT_DIR/lib/foxguard.sh" && foxguard_sha256 "$tmp/rel/archive.tar.gz")"
[[ ${#GOOD_SHA} -eq 64 ]] || { echo "[gitleaks_install_test] SKIP: no shasum, sha256sum or openssl"; exit 0; }
ln -sf "$(command -v xargs)" "$tmp/bin/xargs"

# Stub curl: records the URL, writes the fake archive to -o.
cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [[ \$# -gt 0 ]]; do case "\$1" in -o) out="\$2"; shift 2;; -*) shift;; *) url="\$1"; shift;; esac; done
echo "\$url" >> "$tmp/curl.log"
cp "$tmp/rel/archive.tar.gz" "\$out"
EOF
chmod +x "$tmp/bin/curl"

lib() { # lib <uname -s> <uname -m> <code>; runs code with lib/gitleaks.sh loaded
  local s="$1" m="$2"; shift 2
  mkdir -p "$tmp/u"
  printf '#!/usr/bin/env bash\ncase "$1" in -s) echo %s;; -m) echo %s;; *) echo %s;; esac\n' "$s" "$m" "$s" > "$tmp/u/uname"
  chmod +x "$tmp/u/uname"
  PATH="$tmp/u:$tmp/bin" XDG_CACHE_HOME="$tmp/cache" bash -c "
    source '$ROOT_DIR/lib/logging.sh'; source '$ROOT_DIR/lib/foxguard.sh'; source '$ROOT_DIR/lib/gitleaks.sh'; $*"
}

# 1. Asset names: one per platform, and the pin exists for each.
for row in "Linux x86_64 gitleaks_8.30.1_linux_x64.tar.gz" \
           "Linux aarch64 gitleaks_8.30.1_linux_arm64.tar.gz" \
           "Darwin x86_64 gitleaks_8.30.1_darwin_x64.tar.gz" \
           "Darwin arm64 gitleaks_8.30.1_darwin_arm64.tar.gz" \
           "MINGW64_NT-10.0 x86_64 gitleaks_8.30.1_windows_x64.zip"; do
  set -- $row
  got="$(lib "$1" "$2" 'a="$(gitleaks_asset)" && gitleaks_expected_sha256 "$a" >/dev/null && echo "$a"')"
  [[ "$got" == "$3" ]] && note "asset on $1 $2: $3" || error "asset on $1 $2: got '$got', want $3"
done
got="$(lib MINGW64_NT-10.0 x86_64 'gitleaks_cache_path')"
[[ "$got" == */gitleaks.exe ]] && note "Windows: cached as gitleaks.exe" || error "Windows cache path: $got"
lib FreeBSD x86_64 'gitleaks_asset' >/dev/null 2>&1 && error "FreeBSD: an asset was named" || note "unsupported platform: no asset (3)"

# 2. A matching archive installs; gitleaks_bin finds it in the cache.
rc=0
out="$(CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64="$GOOD_SHA" lib Linux x86_64 'gitleaks_install && gitleaks_bin' 2>&1)" || rc=$?
if [[ $rc -eq 0 && "$out" == *"$tmp/cache/script-helpers/gitleaks/v8.30.1/gitleaks" ]] \
   && grep -q "releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz" "$tmp/curl.log"; then
  note "install: pinned URL, checksum ok, binary in the cache"
else
  error "install: rc=$rc out='$out'"
fi

# 3. A mismatching archive is refused and nothing is left behind.
rm -rf "$tmp/cache"
rc=0
out="$(lib Linux x86_64 'gitleaks_install' 2>&1)" || rc=$?
if [[ $rc -eq 1 && "$out" == *"does not match the pinned SHA-256"* && -z "$(find "$tmp/cache" -type f 2>/dev/null)" ]]; then
  note "checksum mismatch: refused, nothing installed"
else
  error "mismatch: rc=$rc out='$out' left='$(find "$tmp/cache" -type f 2>/dev/null)'"
fi

# 4. A gitleaks on PATH wins: nothing is downloaded.
mkdir -p "$tmp/onpath"; cp "$tmp/rel/gitleaks" "$tmp/onpath/gitleaks"
got="$(PATH="$tmp/onpath:$tmp/bin" XDG_CACHE_HOME="$tmp/cache" bash -c "source '$ROOT_DIR/lib/logging.sh'; source '$ROOT_DIR/lib/foxguard.sh'; source '$ROOT_DIR/lib/gitleaks.sh'; gitleaks_bin")"
[[ "$got" == "$tmp/onpath/gitleaks" ]] && note "gitleaks on PATH is used first" || error "PATH: got '$got'"

# 5. preflight installs a missing gitleaks, and the scan then blocks a secret.
r="$tmp/repo"; git init -q "$r"
git -C "$r" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
printf 'token = LEAKME\n' > "$r/creds.txt"; git -C "$r" add -A
git -C "$r" -c user.name=t -c user.email=t@example.com commit -q -m c
rm -rf "$tmp/cache"; : > "$tmp/curl.log"
rc=0
# Every pin is the fake archive's, so this runs on whatever the host is; on
# Windows the asset is a .zip, which the fake tar.gz is not, so it is skipped.
out="$(cd "$r" && CI="" PREFLIGHT_NO_INSTALL="" \
  CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64="$GOOD_SHA" CI_DEFAULT_GITLEAKS_SHA256_LINUX_ARM64="$GOOD_SHA" \
  CI_DEFAULT_GITLEAKS_SHA256_DARWIN_X64="$GOOD_SHA" CI_DEFAULT_GITLEAKS_SHA256_DARWIN_ARM64="$GOOD_SHA" \
  XDG_CACHE_HOME="$tmp/cache" PATH="$tmp/bin" bash "$ROOT_DIR/scripts/preflight.sh" --security-only 2>&1)" || rc=$?
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) win=true ;; *) win=false ;; esac
if $win; then
  note "SKIP preflight install case on Windows: the fake archive is a tar.gz"
elif [[ $rc -ne 0 && "$out" == *"installing the pinned v8.30.1"* && "$out" == *"FAIL  security scan"* ]]; then
  note "preflight: installs a missing gitleaks, then a committed secret fails"
else
  error "preflight install: rc=$rc out='$(printf '%s' "$out" | tail -6)'"
fi

# 6. PREFLIGHT_NO_INSTALL=1: no download, a SKIP line instead.
rm -rf "$tmp/cache"; : > "$tmp/curl.log"
rc=0
out="$(cd "$r" && CI="" PREFLIGHT_NO_INSTALL=1 XDG_CACHE_HOME="$tmp/cache" PATH="$tmp/bin" \
  bash "$ROOT_DIR/scripts/preflight.sh" --security-only 2>&1)" || rc=$?
if [[ ! -s "$tmp/curl.log" && "$out" == *"SKIP  gitleaks secret scan"* ]]; then
  note "PREFLIGHT_NO_INSTALL=1: nothing downloaded, SKIP reported"
else
  error "no-install: rc=$rc curl='$(cat "$tmp/curl.log")' out='$(printf '%s' "$out" | tail -4)'"
fi

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
