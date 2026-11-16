#!/usr/bin/env bash
# SCRIPT: setup_hooks_args_test.sh
# DESCRIPTION: Tests for the argument checks in scripts/setup-hooks.sh that guard rm -rf and mv.
# USAGE: ./tests/setup_hooks_args_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/setup_hooks_args_test.sh
# ----------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
ok()    { echo "[setup_hooks_args_test]   ok  $*"; }
error() { echo "[setup_hooks_args_test][ERROR] $*" >&2; failures=$((failures+1)); }

# The functions only: the script itself runs on load.
src="$(sed -n -e '/^dir_arg() {/,/^}/p' -e '/^key_arg() {/,/^}/p' -e '/^stage_and_swap() {/,/^}/p' scripts/setup-hooks.sh)"
if [[ -z "$src" ]]; then echo "[setup_hooks_args_test][ERROR] functions not found" >&2; exit 1; fi
eval "$src"
for fn in dir_arg key_arg stage_and_swap; do declare -F "$fn" >/dev/null || { echo "[setup_hooks_args_test][ERROR] $fn is missing" >&2; exit 1; }; done

for bad in '' /; do
  v="unset"; if dir_arg v "$bad"; then error "dir_arg took '$bad'"; elif [[ "$v" == unset ]]; then ok "dir_arg refuses '$bad'"; else error "dir_arg set v for '$bad'"; fi
done
if dir_arg v /tmp/x && [[ "$v" == /tmp/x ]]; then ok "dir_arg takes a directory"; else error "dir_arg refused /tmp/x"; fi
for bad in '' .x ../x a/b 'a b' $'a\nb'; do
  if key_arg v "$bad"; then error "key_arg took $(printf '%q' "$bad")"; else ok "key_arg refuses $(printf '%q' "$bad")"; fi
done
for good in claude-local-created codex-created-dir a.b_c; do
  if key_arg v "$good" && [[ "$v" == "$good" ]]; then ok "key_arg takes $good"; else error "key_arg refused $good"; fi
done

# stage_and_swap with an empty destination must not touch /scripts.old and friends.
rc=0; stage_and_swap "" /tmp >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" ]]; then ok "stage_and_swap refuses an empty destination"; else error "stage_and_swap '' rc=$rc"; fi

if [[ $failures -eq 0 ]]; then echo "[setup_hooks_args_test] all passed"; exit 0; fi
echo "[setup_hooks_args_test] $failures failure(s)"; exit 1
