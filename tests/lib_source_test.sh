#!/usr/bin/env bash
# SCRIPT: lib_source_test.sh
# DESCRIPTION: Sourcing helpers.sh or any lib/*.sh module prints nothing, does not exit, and leaves shell options alone.
# USAGE: bash tests/lib_source_test.sh
# ----------------------------------------------------
# A library is sourced into someone else's shell. An `exit` at top level kills
# the caller, output pollutes its stdout, and a stray `set -e` changes how the
# caller's own errors behave.
# Collect every failure, not just the first: no -e.
set -uo pipefail
root_dir="${LIB_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail=0; count=0
for f in "$root_dir"/helpers.sh "$root_dir"/lib/*.sh; do
  [[ -f "$f" ]] || continue
  count=$((count + 1))
  # The subshell prints a marker after sourcing; no marker means the module exited.
  # shellcheck disable=SC2016
  out="$(bash -c '
    before="$-|$(set -o | grep -E "^(errexit|nounset|pipefail)")"
    source "$1" </dev/null
    after="$-|$(set -o | grep -E "^(errexit|nounset|pipefail)")"
    printf "__SOURCED__\n"
    [[ "$before" == "$after" ]] || printf "__OPTIONS_CHANGED__\n"
  ' _ "$f" 2>&1)"
  name="${f#"$root_dir"/}"
  if [[ "$out" != *__SOURCED__* ]]; then
    echo "[lib_source_test][ERROR] $name: sourcing exited the shell" >&2; fail=1; continue
  fi
  if [[ "$out" == *__OPTIONS_CHANGED__* ]]; then
    echo "[lib_source_test][ERROR] $name: sourcing changed set -e/-u/pipefail in the caller" >&2; fail=1
  fi
  rest="${out%%__SOURCED__*}"
  if [[ -n "$rest" ]]; then
    echo "[lib_source_test][ERROR] $name: sourcing printed: $(printf '%s' "$rest" | sed -n 1,2p)" >&2; fail=1
  fi
done
if [[ $fail -ne 0 ]]; then exit 1; fi
echo "[lib_source_test] PASS: $count modules source silently, without exit or option changes"
