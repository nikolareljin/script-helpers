#!/usr/bin/env bash
# SCRIPT: pre_commit_hook_test.sh
# DESCRIPTION: Tests the .env guard in scripts/git-hooks/pre-commit.
# USAGE: bash tests/pre_commit_hook_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/pre_commit_hook_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[pre_commit_hook_test] $*"; }
error() { echo "[pre_commit_hook_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
HOOK="$ROOT_DIR/scripts/git-hooks/pre-commit"

# hook_rc <path>: stage one file in a fresh repo and print the hook's exit code.
hook_rc() {
  local repo="$tmp/r$RANDOM$RANDOM"
  mkdir -p "$repo/$(dirname "$1")"
  git -C "$repo" init -q .
  printf 'X=1\n' > "$repo/$1"
  git -C "$repo" add -f "$1"
  ( cd "$repo" && bash "$HOOK" >/dev/null 2>&1 )
  echo "$?"
}

for f in .env .env.local .env.production app/.env app/.env.staging; do
  rc="$(hook_rc "$f")"
  if [[ "$rc" -eq 1 ]]; then note "blocks $f"; else error "$f was not blocked (exit $rc)"; fi
done

# git quotes these paths in plain --name-only output, and the closing quote
# hid the .env suffix from the guard.
for f in "ünï/.env" "ünï/.env.local" $'tab\tdir/.env' 'quo"te/.env' $'new\nline/.env'; do
  rc="$(hook_rc "$f")"
  shown="$(printf '%q' "$f")"
  if [[ "$rc" -eq 1 ]]; then note "blocks $shown"; else error "$shown was not blocked (exit $rc)"; fi
done

for f in "ünï/.env.example" .env.example .env.sample .env.template .env.dist app/.env.example \
         .env.local.example notes.env config.envrc; do
  rc="$(hook_rc "$f")"
  if [[ "$rc" -eq 0 ]]; then note "allows $f"; else error "$f was blocked (exit $rc)"; fi
done

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
