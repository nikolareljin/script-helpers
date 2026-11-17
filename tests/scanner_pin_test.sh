#!/usr/bin/env bash
# SCRIPT: scanner_pin_test.sh
# DESCRIPTION: Tests that foxguard and gitleaks are resolved to the pinned version only: never another cached version, never an unpinned foxguard on PATH.
# USAGE: bash tests/scanner_pin_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/scanner_pin_test.sh
# ----------------------------------------------------
#
# Stub scanners only: each logs its own label, so a case can tell which binary
# ran. The pinned SHA-256 is set to a stub's own hash where a case needs a
# cached binary to pass the check. Nothing goes to the network.
set -uo pipefail
unset CI GITHUB_ACTIONS FOXGUARD_CMD GITLEAKS_BIN SCRIPT_HELPERS_FOXGUARD_BLOCK SCRIPT_HELPERS_SECURITY_DIR
unset CI_DEFAULT_FOXGUARD_VERSION CI_DEFAULT_GITLEAKS_VERSION
# The hooks would download a missing scanner; tests never do.
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1 PREFLIGHT_NO_INSTALL=1
# shellcheck disable=SC2046  # the output is a list: one variable name per word
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

failures=0
note()  { echo "[scanner_pin_test] $*"; }
error() { echo "[scanner_pin_test][ERROR] $*" >&2; failures=$((failures+1)); }
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
export FOX_LOG="$tmp/fox.log" GL_LOG="$tmp/gl.log"
cd "$tmp" || exit 1
gc() { git -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null "$@"; }

# A PATH without foxguard and gitleaks: every other command linked from the real PATH.
mkdir -p "$tmp/clean" "$tmp/onpath"
IFS=: read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [[ "$n" == foxguard* || "$n" == gitleaks* || -e "$tmp/clean/$n" || ! -x "$f" ]] && continue
    ln -s "$f" "$tmp/clean/$n" 2>/dev/null || true
  done
done
export PATH="$tmp/clean"
WITH_PATH_FOX="$tmp/onpath:$tmp/clean"

PIN="$(source "$ROOT_DIR/lib/ci_defaults.sh" && printf '%s' "$CI_DEFAULT_FOXGUARD_VERSION")"
GL_PIN="$(source "$ROOT_DIR/lib/ci_defaults.sh" && printf '%s' "$CI_DEFAULT_GITLEAKS_VERSION")"
STALE=0.0.1    # sorts before any real pin, as 0.14.0 does before 0.14.1
cache="$XDG_CACHE_HOME/script-helpers"
fox_name=foxguard
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) fox_name=foxguard.exe ;; esac

# mkfox <file> <label> <version>: a foxguard that logs <label> when it scans,
# reports <version>, and writes an empty report where --output names one.
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
# mkgl <file> <label>: a gitleaks that logs <label> and finds nothing.
mkgl() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\necho "%s" >> "$GL_LOG"\nexit 0\n' "$2" > "$1"
  chmod +x "$1"
}
reset() { rm -rf "$cache" "$tmp/onpath"; mkdir -p "$tmp/onpath"; : > "$FOX_LOG"; : > "$GL_LOG"; : > "$tmp/out"; }

# The pin, set to a stub's own hash: the cached stub then passes the check.
SHA=()
sha_of() { ( source "$ROOT_DIR/helpers.sh" >/dev/null 2>&1 && shlib_import logging foxguard >/dev/null 2>&1 && foxguard_sha256 "$1" ) 2>/dev/null; }
pin_to() {  # <file>: pin every platform's SHA-256 to that file's
  local s; s="$(sha_of "$1")"
  SHA=(CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64="$s" CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64="$s"
       CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64="$s" CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64="$s"
       CI_DEFAULT_FOXGUARD_SHA256_WINDOWS_X86_64="$s")
}
have_sha=false
printf 'x' > "$tmp/probe"
[[ -n "$(sha_of "$tmp/probe")" ]] && have_sha=true
platform=true
( source "$ROOT_DIR/lib/foxguard.sh" && foxguard_asset >/dev/null ) || platform=false

# lib <function>: a lib/foxguard.sh function, stdout captured, exit code in RC.
lib() {
  RC=0
  OUT="$(env "${SHA[@]+"${SHA[@]}"}" "${ENVV[@]+"${ENVV[@]}"}" bash -c 'source "$1/helpers.sh" && shlib_import logging foxguard && "$2"' _ "$ROOT_DIR" "$1" 2>"$tmp/out")" || RC=$?
}
# hook_cmd: sec_foxguard_cmd as the pre-push hook calls it.
hook_cmd() {
  RC=0
  OUT="$(cd "$tmp/repo" && env "${SHA[@]+"${SHA[@]}"}" "${ENVV[@]+"${ENVV[@]}"}" bash -c 'set -euo pipefail; source "$1/scripts/security_hooks.sh" && sec_foxguard_cmd' _ "$ROOT_DIR" 2>"$tmp/out")" || RC=$?
}
# push: the foxguard step of the pre-push hook for HEAD -> main; prints its exit code.
push() {
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" "$(git -C "$tmp/repo" rev-parse HEAD~1)" > "$tmp/refs"
  (cd "$tmp/repo" && env "${SHA[@]+"${SHA[@]}"}" "$@" bash -c 'set -euo pipefail; source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
  echo $?
}

git init -q "$tmp/repo"
gc -C "$tmp/repo" commit -q --allow-empty -m init
printf 'echo one\n' > "$tmp/repo/a.sh" && gc -C "$tmp/repo" add a.sh && gc -C "$tmp/repo" commit -q -m change

if [[ "$platform" != true ]]; then
  note "SKIP: foxguard has no release binary for $(uname -s) $(uname -m); the foxguard cases did not run"
else
  pinned="$cache/foxguard/$PIN/$fox_name"
  stale="$cache/foxguard/$STALE/$fox_name"

  # ------------------------------------------------ only another cached version
  reset; SHA=(); ENVV=()
  mkfox "$stale" stale "$STALE"
  lib foxguard_bin
  expect "lib: only another cached version: none found" 3 "$RC"
  hook_cmd
  expect "hook: only another cached version: none found" "1:" "$RC:$OUT"
  expect "hook: it is refused at the default level" 1 "$(push)"
  has "as not installed" "Foxguard check failed: foxguard is not installed."
  has "with how to install the pinned one" "Install the pinned foxguard: scripts/setup-hooks.sh --install-foxguard"
  expect "and the other version never ran" "" "$(cat "$FOX_LOG")"
  expect "hook: at off the push goes on" 0 "$(push SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
  has "with a warning" "the foxguard scan did NOT run: foxguard is not installed"
  expect "and the other version never ran at off" "" "$(cat "$FOX_LOG")"

  # ------------------------------------------- a foxguard on PATH, wrong version
  reset
  mkfox "$tmp/onpath/foxguard" path-old "$STALE"
  ENVV=(PATH="$WITH_PATH_FOX")
  lib foxguard_bin
  expect "lib: another version on PATH: none found" 3 "$RC"
  lib foxguard_missing_reason
  expect "lib: the reason names it" "$tmp/onpath/foxguard is not the pinned foxguard $PIN" "$OUT"
  hook_cmd
  expect "hook: another version on PATH: none found" "1:" "$RC:$OUT"
  expect "hook: it is refused at the default level" 1 "$(push PATH="$WITH_PATH_FOX")"
  has "naming the binary and the pin" "Foxguard check failed: $tmp/onpath/foxguard is not the pinned foxguard $PIN."
  expect "and it never scanned" "" "$(cat "$FOX_LOG")"
  expect "hook: at off the push goes on" 0 "$(push PATH="$WITH_PATH_FOX" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
  has "with a warning" "the foxguard scan did NOT run: $tmp/onpath/foxguard is not the pinned foxguard $PIN"
  expect "and it never scanned at off" "" "$(cat "$FOX_LOG")"
  (cd "$tmp/repo" && PATH="$WITH_PATH_FOX" bash "$ROOT_DIR/scripts/setup-hooks.sh" --status) >"$tmp/out" 2>&1
  has "setup-hooks.sh --status does not count it" "foxguard  WARN"

  # ------------------------------------------ a foxguard on PATH, pinned version
  reset
  mkfox "$stale" stale "$STALE"
  mkfox "$tmp/onpath/foxguard" path-pinned "$PIN"
  lib foxguard_bin
  expect "lib: the pinned version on PATH is used" "0:$tmp/onpath/foxguard" "$RC:$OUT"
  hook_cmd
  expect "hook: the pinned version on PATH is used, not the other cached one" "0:$tmp/onpath/foxguard" "$RC:$OUT"
  expect "hook: the push is scanned" 0 "$(push PATH="$WITH_PATH_FOX")"
  expect "by the PATH copy only" "path-pinned" "$(sort -u "$FOX_LOG")"
  (cd "$tmp/repo" && PATH="$WITH_PATH_FOX" bash "$ROOT_DIR/scripts/setup-hooks.sh" --status) >"$tmp/out" 2>&1
  has "setup-hooks.sh --status counts it" "foxguard  ok"

  # --------------------------------------------------------- FOXGUARD_CMD wins
  reset
  mkfox "$stale" stale "$STALE"
  mkfox "$tmp/ownfox" own "$STALE"
  ENVV=(FOXGUARD_CMD="$tmp/ownfox")
  hook_cmd
  expect "hook: FOXGUARD_CMD is used as given" "0:$tmp/ownfox" "$RC:$OUT"

  # ----------------------------------------- the pinned version's cached binary
  if [[ "$have_sha" != true ]]; then
    reset; SHA=(); ENVV=()
    mkfox "$pinned" pinned "$PIN"
    lib foxguard_bin
    expect "lib: no SHA-256 tool: a cached binary cannot be checked, so none found" 3 "$RC"
    lib foxguard_missing_reason
    [[ "$OUT" == "$pinned cannot be checked against the pinned SHA-256"* ]] && ok "lib: the reason says it cannot be checked" || error "no-sha reason: '$OUT'"
    note "SKIP: no SHA-256 tool; the cached-binary cases did not run"
  else
    # The issue: 0.14.0 and 0.14.1 both cached, and the glob gave the older one.
    reset; ENVV=()
    mkfox "$stale" stale "$STALE"
    mkfox "$pinned" pinned "$PIN"
    pin_to "$pinned"
    lib foxguard_bin
    expect "lib: two cached versions: the pinned one" "0:$pinned" "$RC:$OUT"
    hook_cmd
    expect "hook: two cached versions: the pinned one" "0:$pinned" "$RC:$OUT"
    expect "hook: the push is scanned" 0 "$(push)"
    expect "by the pinned binary only" "pinned" "$(sort -u "$FOX_LOG")"

    # Preferred over a pinned-version copy on PATH.
    mkfox "$tmp/onpath/foxguard" path-pinned "$PIN"
    ENVV=(PATH="$WITH_PATH_FOX")
    hook_cmd
    expect "hook: the cached pinned binary comes before PATH" "0:$pinned" "$RC:$OUT"

    # A binary in the pinned directory that is not the pinned release.
    reset; ENVV=()
    mkfox "$pinned" pinned "$PIN"
    pin_to "$pinned"
    mkfox "$pinned" tampered "$PIN"
    lib foxguard_bin
    expect "lib: a cached binary with another SHA-256: none found" 3 "$RC"
    lib foxguard_missing_reason
    expect "lib: the reason names it" "$pinned does not match the pinned SHA-256 of foxguard $PIN" "$OUT"
    hook_cmd
    expect "hook: a cached binary with another SHA-256: none found" "1:" "$RC:$OUT"
    expect "hook: it is refused at the default level" 1 "$(push)"
    has "naming the mismatch" "Foxguard check failed: $pinned does not match the pinned SHA-256 of foxguard $PIN."
    has "with how to install the pinned one" "--install-foxguard"
    expect "and it never ran" "" "$(cat "$FOX_LOG")"
    expect "hook: at off the push goes on" 0 "$(push SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
    has "with a warning" "the foxguard scan did NOT run"
    expect "and it never ran at off" "" "$(cat "$FOX_LOG")"
    # With the pinned version on PATH as well, that one runs.
    mkfox "$tmp/onpath/foxguard" path-pinned "$PIN"
    ENVV=(PATH="$WITH_PATH_FOX")
    hook_cmd
    expect "hook: a mismatched cache falls back to the pinned version on PATH" "0:$tmp/onpath/foxguard" "$RC:$OUT"

    # ci_security.sh and foxguard_report.sh resolve it the same way.
    reset; ENVV=()
    mkfox "$stale" stale "$STALE"
    mkfox "$tmp/onpath/foxguard" path-old "$STALE"
    RC=0; (cd "$tmp/repo" && PATH="$WITH_PATH_FOX" bash "$ROOT_DIR/scripts/ci_security.sh" --check-foxguard) >"$tmp/out" 2>&1 || RC=$?
    expect "ci_security.sh --check-foxguard: another version is not the pinned one" 3 "$RC"
    RC=0; (cd "$tmp/repo" && PATH="$WITH_PATH_FOX" bash "$ROOT_DIR/scripts/foxguard_report.sh" --output "$tmp/report.json" -- a.sh) >"$tmp/out" 2>&1 || RC=$?
    expect "foxguard_report.sh: another version is not run" 3 "$RC"
    has "and it names it" "$tmp/onpath/foxguard is not the pinned foxguard $PIN"
    expect "and nothing scanned" "" "$(cat "$FOX_LOG")"
  fi
fi

# ------------------------------------------------------------------ gitleaks
# check_sensitive.sh took the first cached gitleaks of any version.
printf 'plain text\n' > "$tmp/note.txt"
sens() { RC=0; (cd "$tmp/repo" && env "$@" bash "$ROOT_DIR/scripts/check_sensitive.sh" --no-machine --file "$tmp/note.txt") >"$tmp/out" 2>&1 || RC=$?; }
for gl_name in gitleaks gitleaks.exe; do
  reset
  mkgl "$cache/gitleaks/v0.0.1/$gl_name" stale
  sens
  expect "$gl_name: only another cached version: the credential scan cannot run" 2 "$RC"
  has "and it says so" "gitleaks is not installed: credentials NOT checked."
  expect "and the other version never ran" "" "$(cat "$GL_LOG")"
  mkgl "$cache/gitleaks/$GL_PIN/$gl_name" pinned
  sens
  expect "$gl_name: two cached versions: the scan runs" 0 "$RC"
  expect "with the pinned one only" "pinned" "$(sort -u "$GL_LOG")"
done
# The pin is read at run time: another pinned version, another directory.
reset
mkgl "$cache/gitleaks/$GL_PIN/gitleaks" pinned
sens CI_DEFAULT_GITLEAKS_VERSION=v9.9.9
expect "a changed pin: the old pinned directory is not used" 2 "$RC"
expect "and its binary never ran" "" "$(cat "$GL_LOG")"
# GITLEAKS_BIN and PATH keep their documented precedence.
: > "$GL_LOG"; mkgl "$tmp/onpath/gitleaks" onpath
sens PATH="$tmp/onpath:$tmp/clean"
expect "gitleaks on PATH comes before the cache" "0:onpath" "$RC:$(sort -u "$GL_LOG")"
: > "$GL_LOG"; mkgl "$tmp/owngl" own
sens PATH="$tmp/onpath:$tmp/clean" GITLEAKS_BIN="$tmp/owngl"
expect "GITLEAKS_BIN comes before both" "0:own" "$RC:$(sort -u "$GL_LOG")"

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
