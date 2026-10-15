#!/usr/bin/env bash
# SCRIPT: gate_tempdir_test.sh
# DESCRIPTION: The security gates refuse when they cannot make a private temp directory, and leave nothing behind.
# USAGE: bash tests/gate_tempdir_test.sh
# ----------------------------------------------------
# A gate whose mktemp fails must not scan from "" (that wrote /hard, /entries
# and passed over an empty list). Every scratch file lives in one mktemp -d.
# ----------------------------------------------------
set -uo pipefail
# The hooks would download a missing gitleaks or foxguard; tests never do.
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[gate_tempdir_test] $*"; }
error() { echo "[gate_tempdir_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }
command -v python3 >/dev/null 2>&1 || { note "SKIP: python3 not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
: > "$tmp/no-machine-ids"
export SENSITIVE_MACHINE_IDS_FILE="$tmp/no-machine-ids" PRIVATE_NAMES_AUTO_REFRESH=false
unset SCRIPT_HELPERS_OWNERS SECURITY_GATE_ALLOW_UNCHECKED SENSITIVE_ALLOW_UNCHECKED PRIVATE_NAMES_FILE

# A mktemp that always fails. A missing TMPDIR is not enough: BSD mktemp
# (macOS) falls back to its own directory and succeeds.
shim="$tmp/shim"; mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/mktemp"; chmod +x "$shim/mktemp"
no_tmp_path="$shim:$PATH"

# A single --names value is checked: read once dropped a last line without a newline.
rc=0; printf 'see zorblatt-core\n' | bash "$ROOT_DIR/scripts/check_private_names.sh" --stdin --names zorblatt-core >"$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then ok "check_private_names finds a single --names value"
else error "check_private_names --names zorblatt-core: rc=$rc, want 1"; sed 's/^/    /' "$tmp/out" >&2; fi

# check_private_names.sh: text that names the private repo, no temp dir.
rc=0; printf 'see zorblatt-core\n' | PATH="$no_tmp_path" bash "$ROOT_DIR/scripts/check_private_names.sh" --stdin --names zorblatt-core >"$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]] && grep -q 'private temp directory' "$tmp/out"; then ok "check_private_names refuses (2) without a temp dir"
else error "check_private_names without a temp dir: rc=$rc, want 2"; sed 's/^/    /' "$tmp/out" >&2; fi

rc=0; printf 'hello\n' | PATH="$no_tmp_path" bash "$ROOT_DIR/scripts/check_sensitive.sh" --stdin >"$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]] && grep -q 'private temp directory' "$tmp/out"; then ok "check_sensitive refuses (2) without a temp dir"
else error "check_sensitive without a temp dir: rc=$rc, want 2"; sed 's/^/    /' "$tmp/out" >&2; fi

# pre-push: an empty refs path would read no refs and skip every check.
repo="$tmp/repo"; git init -q "$repo"
rc=0; (cd "$repo" && printf 'refs/heads/x %s refs/heads/x %s\n' "$(printf 'a%.0s' {1..40})" "$(printf '0%.0s' {1..40})" \
  | PATH="$no_tmp_path" bash "$ROOT_DIR/scripts/git-hooks/pre-push" origin https://example.invalid/r.git) >"$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'private temp directory' "$tmp/out"; then ok "pre-push refuses without a temp dir"
else error "pre-push without a temp dir: rc=$rc, want non-zero"; sed 's/^/    /' "$tmp/out" >&2; fi

# Nothing is left in TMPDIR after a normal run, and no bare files are made there.
own_tmp="$tmp/own-tmp"; mkdir -p "$own_tmp"
printf 'hello\n' | TMPDIR="$own_tmp" bash "$ROOT_DIR/scripts/check_private_names.sh" --stdin --names zorblatt-core >/dev/null 2>&1
printf 'hello\n' | TMPDIR="$own_tmp" bash "$ROOT_DIR/scripts/check_sensitive.sh" --stdin >/dev/null 2>&1
left="$(find "$own_tmp" -mindepth 1 | head -5)"
if [[ -z "$left" ]]; then ok "no temp files left behind"; else error "left in TMPDIR: $left"; fi

# preflight.sh and ci_security.sh refuse without a temp dir (CI unset: both
# refuse to run in CI before anything else).
for s in preflight.sh ci_security.sh; do
  rc=0; (cd "$repo" && CI='' PATH="$no_tmp_path" bash "$ROOT_DIR/scripts/$s" --help) >"$tmp/out" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'private temp directory' "$tmp/out"; then ok "$s refuses without a temp dir"
  else error "$s without a temp dir: rc=$rc, want non-zero"; sed 's/^/    /' "$tmp/out" >&2; fi
done

# A commit, a refused commit and a push through the hooks, and a preflight run,
# leave nothing under TMPDIR. Exit codes are not under test here (no gitleaks
# in CI); what is left behind is.
hook_tmp="$tmp/hook-tmp"; mkdir -p "$hook_tmp"
hr="$tmp/hookrepo"; git init -q "$hr"; git init -q --bare "$tmp/remote.git"
hg() { git -C "$hr" -c user.name=T -c user.email=t@example.com -c core.hooksPath="$ROOT_DIR/scripts/git-hooks" "$@"; }
git -C "$hr" remote add origin "$tmp/remote.git"
(
  export TMPDIR="$hook_tmp"
  printf 'key = %s\n' "AKIA""QYLPMN5HHHFPZAM2" > "$hr/b.txt"; hg add b.txt
  hg commit -q -m "add b"; hg reset -q --hard 2>/dev/null; rm -f "$hr/b.txt"
  printf 'hello\n' > "$hr/a.txt"; hg add a.txt; hg commit -q -m "add a"
  hg push -q origin HEAD:main
  cd "$hr" && CI='' PREFLIGHT_NO_INSTALL=1 bash "$ROOT_DIR/scripts/preflight.sh" --security-only
) >/dev/null 2>&1
left="$(find "$hook_tmp" -mindepth 1 | head -5)"
if [[ -z "$left" ]]; then ok "commit, refused commit, push and preflight leave nothing in TMPDIR"
else error "left in TMPDIR by commit/push/preflight: $left"; fi

# Interrupted mid-scan (SIGTERM while foxguard runs), ci_security.sh and
# preflight.sh still leave nothing. Before, foxguard's three files stayed.
mkdir -p "$tmp/slowbin"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "foxguard 0.14.0"; exit 0; }\nsleep 30\n' > "$tmp/slowbin/foxguard"
chmod +x "$tmp/slowbin/foxguard"
# term_mid_scan <label> <command...>: start it, wait (up to 15s) until a file
# exists under TMPDIR, TERM its whole process tree at once (what a terminal's
# Ctrl-C does to the foreground group; setsid is not on macOS), then check
# TMPDIR is empty.
proc_tree() {  # proc_tree <pid>: the pid and all its descendants
  local c
  printf '%s\n' "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do proc_tree "$c"; done
}
term_mid_scan() {
  local label="$1" sig_tmp="$tmp/sig-tmp" pid left; shift
  rm -rf "$sig_tmp"; mkdir -p "$sig_tmp"
  ( cd "$hr" && TMPDIR="$sig_tmp" CI='' PATH="$tmp/slowbin:$PATH" "$@" ) >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 150); do
    [[ -n "$(find "$sig_tmp" -type f 2>/dev/null | head -1)" ]] && break
    sleep 0.1
  done
  if [[ -z "$(find "$sig_tmp" -type f 2>/dev/null | head -1)" ]]; then
    kill "$pid" 2>/dev/null; pkill -f "$tmp/slowbin/foxguard" 2>/dev/null; wait "$pid" 2>/dev/null
    error "$label: no scratch file appeared, so the interrupt was not tested"; return
  fi
  # shellcheck disable=SC2046  # one pid per word
  kill -TERM $(proc_tree "$pid") 2>/dev/null
  wait "$pid" 2>/dev/null
  for _ in $(seq 1 50); do [[ -z "$(find "$sig_tmp" -mindepth 1 | head -1)" ]] && break; sleep 0.1; done
  left="$(find "$sig_tmp" -mindepth 1 | head -5)"
  if [[ -z "$left" ]]; then ok "$label: interrupted mid-scan, nothing left in TMPDIR"
  else error "$label: interrupted mid-scan, left in TMPDIR: $left"; fi
}
if command -v pgrep >/dev/null 2>&1; then
  term_mid_scan "ci_security.sh" bash "$ROOT_DIR/scripts/ci_security.sh" --no-docker --skip-python --skip-node --skip-gitleaks
  term_mid_scan "preflight.sh" bash "$ROOT_DIR/scripts/preflight.sh" --security-only
else
  note "SKIP: pgrep not available; the interrupt cases did not run"
fi

# Source check: the hook-path scripts never make a bare temp file.
for f in scripts/check_private_names.sh scripts/check_sensitive.sh scripts/security_hooks.sh \
         scripts/preflight.sh scripts/ci_security.sh \
         scripts/git-hooks/pre-push scripts/global-hooks/dispatch.sh scripts/claude-hooks/pretooluse_private_names.sh; do
  if grep -nE '\$\(mktemp( [^-]|\))' "$ROOT_DIR/$f" >/dev/null; then error "$f uses a bare mktemp file"; else ok "$f: mktemp -d only"; fi
done

if [[ "$failures" -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
