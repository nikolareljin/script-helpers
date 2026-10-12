#!/usr/bin/env bash
# SCRIPT: gate_tempdir_test.sh
# DESCRIPTION: The security gates refuse when they cannot make a private temp directory, and leave nothing behind.
# USAGE: bash tests/gate_tempdir_test.sh
# ----------------------------------------------------
# A gate whose mktemp fails must not scan from "" (that wrote /hard, /entries
# and passed over an empty list). Every scratch file lives in one mktemp -d.
# ----------------------------------------------------
set -uo pipefail

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

bad_tmp="$tmp/does-not-exist"

# check_private_names.sh: text that names the private repo, no temp dir.
rc=0; printf 'see zorblatt-core\n' | TMPDIR="$bad_tmp" bash "$ROOT_DIR/scripts/check_private_names.sh" --stdin --names zorblatt-core >"$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]] && grep -q 'private temp directory' "$tmp/out"; then ok "check_private_names refuses (2) without a temp dir"
else error "check_private_names without a temp dir: rc=$rc, want 2"; sed 's/^/    /' "$tmp/out" >&2; fi

rc=0; printf 'hello\n' | TMPDIR="$bad_tmp" bash "$ROOT_DIR/scripts/check_sensitive.sh" --stdin >"$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]] && grep -q 'private temp directory' "$tmp/out"; then ok "check_sensitive refuses (2) without a temp dir"
else error "check_sensitive without a temp dir: rc=$rc, want 2"; sed 's/^/    /' "$tmp/out" >&2; fi

# pre-push: an empty refs path would read no refs and skip every check.
repo="$tmp/repo"; git init -q "$repo"
rc=0; (cd "$repo" && printf 'refs/heads/x %s refs/heads/x %s\n' "$(printf 'a%.0s' {1..40})" "$(printf '0%.0s' {1..40})" \
  | TMPDIR="$bad_tmp" bash "$ROOT_DIR/scripts/git-hooks/pre-push" origin https://example.invalid/r.git) >"$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'private temp directory' "$tmp/out"; then ok "pre-push refuses without a temp dir"
else error "pre-push without a temp dir: rc=$rc, want non-zero"; sed 's/^/    /' "$tmp/out" >&2; fi

# Nothing is left in TMPDIR after a normal run, and no bare files are made there.
own_tmp="$tmp/own-tmp"; mkdir -p "$own_tmp"
printf 'hello\n' | TMPDIR="$own_tmp" bash "$ROOT_DIR/scripts/check_private_names.sh" --stdin --names zorblatt-core >/dev/null 2>&1
printf 'hello\n' | TMPDIR="$own_tmp" bash "$ROOT_DIR/scripts/check_sensitive.sh" --stdin >/dev/null 2>&1
left="$(find "$own_tmp" -mindepth 1 | head -5)"
if [[ -z "$left" ]]; then ok "no temp files left behind"; else error "left in TMPDIR: $left"; fi

# Source check: the hook-path scripts never make a bare temp file.
for f in scripts/check_private_names.sh scripts/check_sensitive.sh scripts/security_hooks.sh \
         scripts/git-hooks/pre-push scripts/global-hooks/dispatch.sh scripts/claude-hooks/pretooluse_private_names.sh; do
  if grep -nE '\$\(mktemp( [^-]|\))' "$ROOT_DIR/$f" >/dev/null; then error "$f uses a bare mktemp file"; else ok "$f: mktemp -d only"; fi
done

if [[ "$failures" -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
