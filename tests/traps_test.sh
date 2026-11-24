#!/usr/bin/env bash
# SCRIPT: traps_test.sh
# DESCRIPTION: Tests lib/traps.sh: the setup_traps EXIT handler reports a non-zero exit code, stays quiet on exit 0, and keeps the script's exit status, with and without lib/trap_stack.sh in use.
# USAGE: bash tests/traps_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/traps_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[traps_test] $*"; }
error() { echo "[traps_test][ERROR] $*" >&2; failures=$((failures+1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/traps-test.XXXXXX")"
# Guarded: a subshell inherits this trap.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf -- "$work"; fi' EXIT

# run_case <label> <code> <with_stack 0|1>: a script that calls setup_traps
# (optionally pushes a trap_stack path) and exits <code>.
run_case() {
  local label="$1" code="$2" stack="$3" rc out
  cat >"$work/s.sh" <<SCRIPT
source "$ROOT_DIR/helpers.sh"
shlib_import logging traps trap_stack
setup_traps
if [[ $stack -eq 1 ]]; then
  mkdir "$work/d" && trap_stack_push "$work/d"
fi
exit $code
SCRIPT
  rm -rf -- "$work/d"
  bash "$work/s.sh" >"$work/out" 2>&1
  rc=$?
  out="$(cat "$work/out")"
  if [[ "$rc" -ne "$code" ]]; then
    error "$label: exit status $rc, want $code"
  fi
  if [[ "$code" -eq 0 ]]; then
    if [[ "$out" == *"Script failed"* ]]; then
      error "$label: exit 0 printed a failure line: $out"
    fi
  elif [[ "$out" != *"Script failed with exit code $code"* ]]; then
    error "$label: no 'Script failed with exit code $code' line; got: $out"
  fi
  if [[ "$stack" -eq 1 && -e "$work/d" ]]; then
    error "$label: trap_stack path was not removed"
  fi
}

run_case "exit 0" 0 0
run_case "exit 3" 3 0
run_case "exit 0 with trap_stack" 0 1
run_case "exit 3 with trap_stack" 3 1

# cleanup called with no argument still reads $? on entry.
out="$(bash -c 'source ./helpers.sh; shlib_import logging traps; (exit 5); cleanup' 2>&1)"
[[ "$out" == *"exit code 5"* ]] || error "cleanup without an argument: got: $out"

if [[ "$failures" -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
