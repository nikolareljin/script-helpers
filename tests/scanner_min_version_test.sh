#!/usr/bin/env bash
# SCRIPT: scanner_min_version_test.sh
# DESCRIPTION: Tests that a gitleaks or foxguard on PATH is used only at the pinned version or newer: an older one is replaced by the pinned release in the cache, a newer breaking series runs with a warning.
# USAGE: bash tests/scanner_min_version_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/scanner_min_version_test.sh
# ----------------------------------------------------
#
# Stub scanners only: each prints the version it was made with and logs its
# label when it scans. curl is a stub that copies a local fake release, whose
# SHA-256 the pins are set to. Nothing goes to the network, and the pins are
# fixed here, so a pin bump in lib/ci_defaults.sh changes no case.
set -uo pipefail
unset CI GITHUB_ACTIONS FOXGUARD_CMD GITLEAKS_BIN SCRIPT_HELPERS_FOXGUARD_BLOCK SCRIPT_HELPERS_SECURITY_DIR
unset SCRIPT_HELPERS_NO_AUTO_INSTALL PREFLIGHT_NO_INSTALL
# shellcheck disable=SC2046  # the output is a list: one variable name per word
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

failures=0
note()  { echo "[scanner_min_version_test] $*"; }
error() { echo "[scanner_min_version_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }
expect() {  # <description> <want> <got>
  if [[ "$2" == "$3" ]]; then ok "$1"; return 0; fi
  error "$1: want '$2', got '$3'"
  [[ -f "$tmp/out" ]] && sed 's/^/    | /' "$tmp/out" | tail -12 >&2
  return 0
}
has() {  # <description> <fixed text>
  if grep -qF -- "$2" "$tmp/out"; then ok "$1"; else error "$1: no '$2' in: $(tail -8 "$tmp/out")"; fi
}
hasnt() {  # <description> <fixed text>
  if grep -qF -- "$2" "$tmp/out"; then error "$1: '$2' in: $(tail -8 "$tmp/out")"; else ok "$1"; fi
}

# Hermetic: no real config, cache or identity of this machine.
export HOME="$tmp/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export FOX_LOG="$tmp/fox.log" GL_LOG="$tmp/gl.log" CURL_LOG="$tmp/curl.log"
# The pins every case is written against.
export CI_DEFAULT_GITLEAKS_VERSION=v8.30.1 CI_DEFAULT_FOXGUARD_VERSION=0.14.1
GL_PIN="$CI_DEFAULT_GITLEAKS_VERSION"; FOX_PIN="$CI_DEFAULT_FOXGUARD_VERSION"
cd "$tmp" || exit 1

# A PATH without the scanners and without a real downloader: every other
# command linked from the real PATH, and the stub curl in front.
mkdir -p "$tmp/clean" "$tmp/onpath" "$tmp/stub" "$tmp/rel"
IFS=: read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [[ "$n" == foxguard* || "$n" == gitleaks* || "$n" == curl || "$n" == wget || -e "$tmp/clean/$n" || ! -x "$f" ]] && continue
    ln -s "$f" "$tmp/clean/$n" 2>/dev/null || true
  done
done
NO_SCANNER="$tmp/stub:$tmp/clean"
WITH_PATH="$tmp/onpath:$tmp/stub:$tmp/clean"
export PATH="$NO_SCANNER"
cache="$XDG_CACHE_HOME/script-helpers"

# mkgl <file> <label> <version text>: a gitleaks that prints <version text> for
# `gitleaks version`, else logs <label> and finds nothing.
mkgl() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\nif [[ "${1:-}" == version ]]; then printf "%%s\\n" "%s"; exit 0; fi\necho "%s" >> "$GL_LOG"\nexit 0\n' "$3" "$2" > "$1"
  chmod +x "$1"
}
# mkfox <file> <label> <version text>: a foxguard that prints "foxguard
# <version text>" for --version, else logs <label> and writes an empty report.
mkfox() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == --version ]]; then echo "foxguard $3"; exit 0; fi
echo "$2" >> "\$FOX_LOG"
while [[ \$# -gt 0 ]]; do [[ "\$1" == --output ]] && printf '{"findings": []}\n' > "\$2"; shift; done
exit 0
EOF
  chmod +x "$1"
}
reset() {
  rm -rf "$cache" "$tmp/onpath"; mkdir -p "$tmp/onpath"
  : > "$FOX_LOG"; : > "$GL_LOG"; : > "$CURL_LOG"; : > "$tmp/out"
}

# The fake releases the stub curl serves, and their SHA-256 as the pins.
mkgl "$tmp/rel/gitleaks" installed "8.30.1"
tar -czf "$tmp/rel/gitleaks.tar.gz" -C "$tmp/rel" gitleaks
mkfox "$tmp/rel/foxguard" installed "$FOX_PIN"
printf 'not the release\n' > "$tmp/rel/wrong"
cat > "$tmp/stub/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [[ \$# -gt 0 ]]; do case "\$1" in -o) out="\$2"; shift 2;; -*) shift;; *) url="\$1"; shift;; esac; done
echo "\$url" >> "\$CURL_LOG"
[[ "\${CURL_OFFLINE:-}" == 1 ]] && exit 6
if [[ "\${CURL_WRONG:-}" == 1 ]]; then cp "$tmp/rel/wrong" "\$out"; exit 0; fi
case "\$url" in
  *gitleaks*) cp "$tmp/rel/gitleaks.tar.gz" "\$out" ;;
  *foxguard*) cp "$tmp/rel/foxguard" "\$out" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$tmp/stub/curl"
sha_of() { ( source "$ROOT_DIR/lib/foxguard.sh" >/dev/null 2>&1 && foxguard_sha256 "$1" ) 2>/dev/null; }
GL_SHA="$(sha_of "$tmp/rel/gitleaks.tar.gz")"; FOX_SHA="$(sha_of "$tmp/rel/foxguard")"
can_install=true
[[ ${#GL_SHA} -eq 64 && ${#FOX_SHA} -eq 64 ]] || can_install=false
# The stub release is a tar.gz and a plain binary: not what Git Bash installs.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) can_install=false ;; esac
( source "$ROOT_DIR/lib/foxguard.sh" && foxguard_asset >/dev/null ) || can_install=false
export CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64="$GL_SHA" CI_DEFAULT_GITLEAKS_SHA256_LINUX_ARM64="$GL_SHA" \
       CI_DEFAULT_GITLEAKS_SHA256_DARWIN_X64="$GL_SHA" CI_DEFAULT_GITLEAKS_SHA256_DARWIN_ARM64="$GL_SHA"
export CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64="$FOX_SHA" CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64="$FOX_SHA" \
       CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64="$FOX_SHA" CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64="$FOX_SHA"
gl_cached="$cache/gitleaks/$GL_PIN/gitleaks"
fox_cached="$cache/foxguard/$FOX_PIN/foxguard"
HINT_GL="bash $ROOT_DIR/scripts/setup-hooks.sh --install-gitleaks"
HINT_FOX="bash $ROOT_DIR/scripts/setup-hooks.sh --install-foxguard"

# lib <code> [VAR=value ...]: <code> with the libraries loaded; stdout in OUT,
# stderr in $tmp/out, exit code in RC.
lib() {
  local code="$1"; shift
  RC=0
  OUT="$(env "$@" bash -c 'source "$1/helpers.sh" && shlib_import logging version foxguard gitleaks && eval "$2"' _ "$ROOT_DIR" "$code" 2>"$tmp/out")" || RC=$?
}

git init -q "$tmp/repo"
gc() { git -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null "$@"; }
gc -C "$tmp/repo" commit -q --allow-empty -m init
printf 'echo one\n' > "$tmp/repo/a.sh" && gc -C "$tmp/repo" add a.sh && gc -C "$tmp/repo" commit -q -m change
printf 'plain text\n' > "$tmp/note.txt"

# ------------------------------------------------------------ the comparison
while IFS='|' read -r v min want; do
  lib "version_at_least '$v' '$min'"
  expect "version_at_least '$v' '$min'" "$want" "$RC"
done <<'EOF'
8.30.1|v8.30.1|0
v8.30.1|8.30.1|0
V8.30.1|8.30.1|0
8.30.2|v8.30.1|0
8.31.0|v8.30.1|0
9.0.0|v8.30.1|0
8.100.0|v8.30.1|0
8.30.0|v8.30.1|1
8.9.9|v8.30.1|1
7.99.99|v8.30.1|1
0.9.9|0.10.0|1
08.030.01|8.30.1|0
8.31.0-rc1|v8.30.1|3
8.30.1+build5|v8.30.1|3
8.30|v8.30.1|3
8.30.1.2|v8.30.1|3
8.30.1.|v8.30.1|3
.8.30.1|v8.30.1|3
8..1|v8.30.1|3
version is set by build process|v8.30.1|3
|v8.30.1|3
8.30.1||3
8.30.1|latest|3
1234567890.0.0|v8.30.1|3
EOF
while IFS='|' read -r a b want; do
  lib "version_same_series '$a' '$b'"
  expect "version_same_series '$a' '$b'" "$want" "$RC"
done <<'EOF'
8.44.0|v8.30.1|0
9.0.0|v8.30.1|1
7.0.0|v8.30.1|1
0.14.9|0.14.1|0
0.15.0|0.14.1|1
1.0.0|0.14.1|1
1.2.0|1.9.0|0
dev|0.14.1|3
EOF

# ------------------------------------------- which scanner on PATH is used
# <tool>|<version text>|<want: path, none>|<what>
while IFS='|' read -r tool ver want what; do
  reset
  if [[ "$tool" == gitleaks ]]; then mkgl "$tmp/onpath/gitleaks" path "$ver"; else mkfox "$tmp/onpath/foxguard" path "$ver"; fi
  lib "${tool}_bin" PATH="$WITH_PATH"
  case "$want" in
    path) expect "$tool '$ver' on PATH ($what): used" "0:$tmp/onpath/$tool" "$RC:$OUT" ;;
    none) expect "$tool '$ver' on PATH ($what): not used" 3 "$RC" ;;
  esac
done <<'EOF'
gitleaks|8.30.0|none|older patch
gitleaks|8.18.4|none|older minor
gitleaks|7.6.1|none|older major
gitleaks|8.30.1|path|equal
gitleaks|v8.30.1|path|equal, v prefix
gitleaks|8.30.2|path|newer patch
gitleaks|8.44.0|path|newer minor
gitleaks|9.0.0|path|newer major
gitleaks|8.31.0-rc1|none|prerelease
gitleaks|version is set by build process|none|dev build
gitleaks||none|no version
foxguard|0.14.0|none|older patch
foxguard|0.9.7|none|older minor
foxguard|0.14.1|path|equal
foxguard|v0.14.1|path|equal, v prefix
foxguard|0.14.2|path|newer patch
foxguard|0.15.0|path|newer 0.x minor
foxguard|1.0.0|path|newer major
foxguard|0.15.0-beta.1|none|prerelease
foxguard|unknown|none|garbage
foxguard||none|no version
EOF
# gitleaks.exe prints a carriage return; a stub that fails prints nothing.
reset
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == version ]]; then printf "8.30.1\\r\\n"; exit 0; fi\nexit 0\n' > "$tmp/onpath/gitleaks"; chmod +x "$tmp/onpath/gitleaks"
lib gitleaks_bin PATH="$WITH_PATH"
expect "gitleaks: a version line ending in CR is read" "0:$tmp/onpath/gitleaks" "$RC:$OUT"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/onpath/gitleaks"
lib gitleaks_bin PATH="$WITH_PATH"
expect "gitleaks: a binary that fails on 'version' is not used" 3 "$RC"
printf '#!/usr/bin/env bash\nprintf "9.9.9\\033[31m\\n"\n' > "$tmp/onpath/gitleaks"
lib gitleaks_missing_reason PATH="$WITH_PATH"
expect "gitleaks: control characters never reach the message" "$tmp/onpath/gitleaks reports no usable version ('9.9.9[31m'); the minimum is gitleaks $GL_PIN" "$OUT"

# ----------------------------------------------------------- the reasons
reset
lib gitleaks_missing_reason
expect "gitleaks: none anywhere" "gitleaks is not installed" "$OUT"
mkgl "$tmp/onpath/gitleaks" path 8.18.4
lib gitleaks_missing_reason PATH="$WITH_PATH"
expect "gitleaks: the reason names the path, the found version and the minimum" "$tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN" "$OUT"
mkgl "$tmp/onpath/gitleaks" path "version is set by build process"
lib gitleaks_missing_reason PATH="$WITH_PATH"
expect "gitleaks: the reason for a version that cannot be read" "$tmp/onpath/gitleaks reports no usable version ('version is set by build process'); the minimum is gitleaks $GL_PIN" "$OUT"
mkfox "$tmp/onpath/foxguard" path 0.13.9
lib foxguard_missing_reason PATH="$WITH_PATH"
expect "foxguard: the reason names the path, the found version and the minimum" "$tmp/onpath/foxguard is foxguard 0.13.9, older than the minimum $FOX_PIN" "$OUT"

# ------------------------------------------------- the cache and the order
reset
mkgl "$tmp/onpath/gitleaks" path 8.18.4
mkgl "$gl_cached" cached 8.30.1
lib gitleaks_bin PATH="$WITH_PATH"
expect "gitleaks: older on PATH, pinned in the cache: the cached one" "0:$gl_cached" "$RC:$OUT"
mkgl "$tmp/onpath/gitleaks" path 8.44.0
lib gitleaks_bin PATH="$WITH_PATH"
expect "gitleaks: newer, same major, on PATH: before the cache" "0:$tmp/onpath/gitleaks" "$RC:$OUT"
mkgl "$tmp/onpath/gitleaks" path 9.0.0
lib gitleaks_bin PATH="$WITH_PATH"
expect "gitleaks: newer major on PATH, pinned in the cache: the cached one" "0:$gl_cached" "$RC:$OUT"
lib gitleaks_version_warning PATH="$WITH_PATH"
expect "and no warning for the cached one" "" "$OUT"

# ------------------------------------------- a newer breaking series: warning
reset
mkgl "$tmp/onpath/gitleaks" path 9.1.0
lib gitleaks_version_warning PATH="$WITH_PATH"
expect "gitleaks: a newer major warns with both versions and the install command" \
  "WARNING: $tmp/onpath/gitleaks is gitleaks 9.1.0, a newer major version than the tested pin $GL_PIN; it may break. To use the pinned one: $HINT_GL" "$OUT"
lib gitleaks_resolve PATH="$WITH_PATH"
expect "gitleaks_resolve still returns it" "0:$tmp/onpath/gitleaks" "$RC:$OUT"
has "with the warning on stderr" "a newer major version than the tested pin $GL_PIN"
expect "and nothing was downloaded" "" "$(cat "$CURL_LOG")"
mkgl "$tmp/onpath/gitleaks" path 8.44.0
lib gitleaks_version_warning PATH="$WITH_PATH"
expect "gitleaks: a newer minor of the same major: no warning" "" "$OUT"
mkfox "$tmp/onpath/foxguard" path 0.15.0
lib foxguard_version_warning PATH="$WITH_PATH"
expect "foxguard: a newer 0.x minor warns" \
  "WARNING: $tmp/onpath/foxguard is foxguard 0.15.0, a newer 0.x minor version (breaking under semver) than the tested pin $FOX_PIN; it may break. To use the pinned one: $HINT_FOX" "$OUT"
mkfox "$tmp/onpath/foxguard" path 1.2.0
lib foxguard_version_warning PATH="$WITH_PATH"
expect "foxguard: a newer major warns" \
  "WARNING: $tmp/onpath/foxguard is foxguard 1.2.0, a newer major version than the tested pin $FOX_PIN; it may break. To use the pinned one: $HINT_FOX" "$OUT"
mkfox "$tmp/onpath/foxguard" path 0.14.7
lib foxguard_version_warning PATH="$WITH_PATH"
expect "foxguard: a newer patch: no warning" "" "$OUT"
mkfox "$tmp/onpath/foxguard" path 0.14.0
lib foxguard_version_warning PATH="$WITH_PATH"
expect "foxguard: an older one: no warning, it is not run" "" "$OUT"

# -------------------------------------------- check_sensitive.sh and gitleaks
sens() { RC=0; (cd "$tmp/repo" && env "$@" bash "$ROOT_DIR/scripts/check_sensitive.sh" --no-machine --file "$tmp/note.txt") >"$tmp/out" 2>&1 || RC=$?; }
reset
mkgl "$tmp/onpath/gitleaks" old 8.18.4
sens PATH="$WITH_PATH" SCRIPT_HELPERS_NO_AUTO_INSTALL=1
expect "check_sensitive: older gitleaks, installs off: the scan cannot run" 2 "$RC"
has "naming the found version and the minimum" "[sensitive] $tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN: credentials NOT checked."
has "and the recovery command" "--install-gitleaks"
expect "the older one never scanned" "" "$(cat "$GL_LOG")"
expect "and nothing was downloaded" "" "$(cat "$CURL_LOG")"
sens PATH="$WITH_PATH" CI=true
expect "check_sensitive: older gitleaks in CI: the scan cannot run" 2 "$RC"
expect "and nothing was downloaded in CI" "" "$(cat "$CURL_LOG")"
mkgl "$tmp/onpath/gitleaks" garbage "version is set by build process"
sens PATH="$WITH_PATH" SCRIPT_HELPERS_NO_AUTO_INSTALL=1
expect "check_sensitive: a gitleaks with no usable version: the scan cannot run" 2 "$RC"
has "naming what it reported" "reports no usable version ('version is set by build process'); the minimum is gitleaks $GL_PIN"
expect "and it never scanned" "" "$(cat "$GL_LOG")"
for row in "8.30.1|equal" "v8.30.1|equal, v prefix" "8.44.0|newer minor"; do
  reset
  mkgl "$tmp/onpath/gitleaks" onpath "${row%%|*}"
  sens PATH="$WITH_PATH"
  expect "check_sensitive: gitleaks ${row%%|*} on PATH (${row#*|}): the scan runs with it" "0:onpath" "$RC:$(sort -u "$GL_LOG")"
  hasnt "silently" "WARNING"
  expect "and nothing was downloaded" "" "$(cat "$CURL_LOG")"
done
reset
mkgl "$tmp/onpath/gitleaks" major 9.0.0
sens PATH="$WITH_PATH"
expect "check_sensitive: a newer major on PATH: the scan runs with it" "0:major" "$RC:$(sort -u "$GL_LOG")"
has "with a warning" "[sensitive] WARNING: $tmp/onpath/gitleaks is gitleaks 9.0.0, a newer major version than the tested pin $GL_PIN; it may break."
# GITLEAKS_BIN is run as given: its version is not checked.
reset
mkgl "$tmp/owngl" own 7.0.0
sens GITLEAKS_BIN="$tmp/owngl"
expect "check_sensitive: GITLEAKS_BIN is run as given, whatever its version" "0:own" "$RC:$(sort -u "$GL_LOG")"

if [[ "$can_install" != true ]]; then
  note "SKIP: no SHA-256 tool, or a platform the stub release does not fit; the install cases did not run"
else
  # ------------------------------------ older on PATH: the pinned one is installed
  reset
  mkgl "$tmp/onpath/gitleaks" old 8.18.4
  before="$(sha_of "$tmp/onpath/gitleaks")"
  sens PATH="$WITH_PATH"
  expect "check_sensitive: older gitleaks: the pinned release is installed and the scan runs" 0 "$RC"
  has "saying it is older and what is installed" "[sensitive] $tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN; installing the pinned gitleaks $GL_PIN into the cache."
  expect "from the pinned release URL" "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/$(source "$ROOT_DIR/lib/gitleaks.sh" && gitleaks_asset)" "$(cat "$CURL_LOG")"
  expect "the installed one scanned, the older one did not" "installed" "$(sort -u "$GL_LOG")"
  [[ -x "$gl_cached" ]] && ok "it is in the cache" || error "no $gl_cached"
  expect "the copy on PATH is untouched" "$before" "$(sha_of "$tmp/onpath/gitleaks")"
  : > "$CURL_LOG"; : > "$GL_LOG"
  sens PATH="$WITH_PATH"
  expect "the next run uses the cached one" "0:installed" "$RC:$(sort -u "$GL_LOG")"
  expect "without another download" "" "$(cat "$CURL_LOG")"
  hasnt "and without the message" "installing the pinned"

  # ----------------------------------------- the install fails: refused as before
  reset
  mkgl "$tmp/onpath/gitleaks" old 8.18.4
  sens PATH="$WITH_PATH" CURL_WRONG=1
  expect "check_sensitive: the download does not match the pin: the scan cannot run" 2 "$RC"
  has "the mismatch is reported" "does not match the pinned SHA-256"
  has "and the reason stays the older version" "[sensitive] $tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN: credentials NOT checked."
  expect "nothing scanned" "" "$(cat "$GL_LOG")"
  [[ -z "$(find "$cache" -type f 2>/dev/null)" ]] && ok "and nothing is left in the cache" || error "left in the cache: $(find "$cache" -type f)"
  sens PATH="$WITH_PATH" CURL_OFFLINE=1
  expect "check_sensitive: offline: the scan cannot run" 2 "$RC"
  has "the failed download is reported" "gitleaks: download failed"
  expect "nothing scanned offline" "" "$(cat "$GL_LOG")"

  # --------------------------------------------------------- the same for foxguard
  reset
  mkfox "$tmp/onpath/foxguard" old 0.13.9
  lib foxguard_resolve PATH="$WITH_PATH"
  expect "foxguard_resolve: older foxguard: the pinned release is installed and used" "0:$fox_cached" "$RC:$OUT"
  has "saying it is older and what is installed" "$tmp/onpath/foxguard is foxguard 0.13.9, older than the minimum $FOX_PIN; installing the pinned foxguard $FOX_PIN into the cache."
  reset
  mkfox "$tmp/onpath/foxguard" old 0.13.9
  lib foxguard_resolve PATH="$WITH_PATH" CURL_WRONG=1
  expect "foxguard_resolve: the download does not match the pin: none" 3 "$RC"
  lib foxguard_resolve PATH="$WITH_PATH" SCRIPT_HELPERS_NO_AUTO_INSTALL=1
  expect "foxguard_resolve: installs off: none" 3 "$RC"
  expect "and nothing was downloaded" "" "$(grep -c . "$CURL_LOG" | sed 's/^1$//')"
  lib foxguard_resolve
  expect "foxguard_resolve: none on PATH at all: none, and no install" "3:" "$RC:$(sed -n 2p "$CURL_LOG")"

  # ------------------------------------------------ the pre-push hook, gitleaks
  # sec_sensitive_push with an older gitleaks: installed, then the scan runs.
  hookpush() {
    printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" "$(git -C "$tmp/repo" rev-parse HEAD~1)" > "$tmp/refs"
    RC=0
    (cd "$tmp/repo" && env "$@" bash -c 'set -uo pipefail; source "$1/scripts/security_hooks.sh" && sec_sensitive_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1 || RC=$?
  }
  reset
  mkgl "$tmp/onpath/gitleaks" old 8.18.4
  hookpush PATH="$WITH_PATH" SENSITIVE_NO_MACHINE=1
  has "hook: older gitleaks: it says so and installs the pinned one" "[pre-push] $tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN; installing the pinned release to run the credential scan."
  expect "the installed one scanned, the older one did not" "installed" "$(sort -u "$GL_LOG")"
  reset
  mkgl "$tmp/onpath/gitleaks" old 8.18.4
  hookpush PATH="$WITH_PATH" SENSITIVE_NO_MACHINE=1 SCRIPT_HELPERS_NO_AUTO_INSTALL=1
  [[ "$RC" -ne 0 ]] && ok "hook: older gitleaks, installs off: the push is refused" || error "hook: older gitleaks, installs off: rc=$RC"
  has "naming the found version and the minimum" "[pre-push] ERROR: $tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN; the credential scan cannot run."
  has "and the recovery command" "setup-hooks.sh --install-gitleaks"
  expect "nothing scanned" "" "$(cat "$GL_LOG")"
fi

# ------------------------------------------------------------- preflight.sh
# A scanner preflight reports as SKIP is not downloaded and run after all.
pf() { RC=0; (cd "$tmp/repo" && env "$@" bash "$ROOT_DIR/scripts/preflight.sh" --security-only) >"$tmp/out" 2>&1 || RC=$?; }
reset
mkgl "$tmp/onpath/gitleaks" pinned 8.30.1
mkfox "$tmp/onpath/foxguard" old 0.13.9
pf PATH="$WITH_PATH" PREFLIGHT_NO_INSTALL=1
has "preflight, installs off: an older foxguard is a SKIP naming it" "SKIP  foxguard code scan — $tmp/onpath/foxguard is foxguard 0.13.9, older than the minimum $FOX_PIN"
expect "and nothing was downloaded" "" "$(cat "$CURL_LOG")"
expect "and the older foxguard never scanned" "" "$(cat "$FOX_LOG")"
[[ -s "$GL_LOG" ]] && ok "while the pinned gitleaks on PATH scanned" || error "gitleaks did not scan: $(tail -5 "$tmp/out")"
reset
mkgl "$tmp/onpath/gitleaks" old 8.18.4
pf PATH="$WITH_PATH" PREFLIGHT_NO_INSTALL=1
has "preflight, installs off: an older gitleaks is a SKIP naming it" "SKIP  gitleaks secret scan — $tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN"
expect "and it never scanned" "" "$(cat "$GL_LOG")"
if [[ "$can_install" == true ]]; then
  reset
  mkgl "$tmp/onpath/gitleaks" old 8.18.4
  mkfox "$tmp/onpath/foxguard" old 0.13.9
  pf PATH="$WITH_PATH"
  has "preflight: an older gitleaks is replaced by the pinned one" "preflight: $tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN; installing the pinned $GL_PIN"
  has "preflight: an older foxguard is replaced by the pinned one" "preflight: $tmp/onpath/foxguard is foxguard 0.13.9, older than the minimum $FOX_PIN; installing the pinned $FOX_PIN"
  expect "the installed gitleaks scanned, the older one did not" "installed" "$(sort -u "$GL_LOG")"
  expect "the installed foxguard scanned, the older one did not" "installed" "$(sort -u "$FOX_LOG")"
fi

# ------------------------------------------------ the pre-push hook, foxguard
foxpush() {
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" "$(git -C "$tmp/repo" rev-parse HEAD~1)" > "$tmp/refs"
  (cd "$tmp/repo" && env "$@" bash -c 'set -euo pipefail; source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
  echo $?
}
if ( source "$ROOT_DIR/lib/foxguard.sh" && foxguard_asset >/dev/null ); then
  reset
  mkfox "$tmp/onpath/foxguard" breaking 0.15.0
  expect "hook: a newer 0.x minor of foxguard scans the push" 0 "$(foxpush PATH="$WITH_PATH")"
  expect "with the PATH copy" "breaking" "$(sort -u "$FOX_LOG")"
  has "and warns" "[pre-push] WARNING: $tmp/onpath/foxguard is foxguard 0.15.0, a newer 0.x minor version (breaking under semver) than the tested pin $FOX_PIN; it may break."
  reset
  mkfox "$tmp/onpath/foxguard" old 0.13.9
  expect "hook: an older foxguard, installs off: refused at the default level" 1 "$(foxpush PATH="$WITH_PATH" SCRIPT_HELPERS_NO_AUTO_INSTALL=1)"
  has "naming the found version and the minimum" "Foxguard check failed: $tmp/onpath/foxguard is foxguard 0.13.9, older than the minimum $FOX_PIN."
  expect "and it never scanned" "" "$(cat "$FOX_LOG")"
else
  note "SKIP: foxguard has no release binary for $(uname -s) $(uname -m); the foxguard hook cases did not run"
fi

# ----------------------------------- ci_security.sh and setup-hooks.sh --status
reset
mkgl "$tmp/onpath/gitleaks" old 8.18.4
RC=0; (cd "$tmp/repo" && PATH="$WITH_PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --check-gitleaks) >"$tmp/out" 2>&1 || RC=$?
expect "ci_security.sh --check-gitleaks: an older gitleaks does not count" 3 "$RC"
(cd "$tmp/repo" && PATH="$WITH_PATH" SCRIPT_HELPERS_NO_AUTO_INSTALL=1 bash "$ROOT_DIR/scripts/setup-hooks.sh" --status) >"$tmp/out" 2>&1
has "setup-hooks.sh --status: an older gitleaks is missing, with the reason" "gitleaks  MISSING: $tmp/onpath/gitleaks is gitleaks 8.18.4, older than the minimum $GL_PIN;"
mkgl "$tmp/onpath/gitleaks" ok 8.30.1
RC=0; (cd "$tmp/repo" && PATH="$WITH_PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --check-gitleaks) >"$tmp/out" 2>&1 || RC=$?
expect "ci_security.sh --check-gitleaks: the pinned version counts" 0 "$RC"
mkgl "$tmp/onpath/gitleaks" major 9.0.0
(cd "$tmp/repo" && PATH="$WITH_PATH" bash "$ROOT_DIR/scripts/setup-hooks.sh" --status) >"$tmp/out" 2>&1
has "setup-hooks.sh --status: a newer major counts" "gitleaks  ok"
has "with the warning" "WARNING: $tmp/onpath/gitleaks is gitleaks 9.0.0, a newer major version than the tested pin $GL_PIN"

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
