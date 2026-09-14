#!/usr/bin/env bash
# SCRIPT: packaging_test.sh
# DESCRIPTION: Tests for lib/packaging.sh list helpers (pkg_join_list, pkg_quote_list, pkg_render_lines).
# USAGE: ./tests/packaging_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/packaging_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[packaging_test] $*"; }
error() { echo "[packaging_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging packaging

# expect <description> <want> <cmd...>: output and stderr of cmd, which must succeed.
expect() {
  local desc="$1" want="$2" got err_file rc
  shift 2
  err_file="$(mktemp)"
  set +e
  got="$("$@" 2>"$err_file")"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    error "$desc: exited $rc ($(cat "$err_file"))"
  elif [[ -s "$err_file" ]]; then
    error "$desc: printed to stderr: $(cat "$err_file")"
  elif [[ "$got" != "$want" ]]; then
    error "$desc: got [$got], expected [$want]"
  fi
  rm -f "$err_file"
}

expect "join" "a, b c" pkg_join_list "a | b c" ", "
expect "quote" "'a' 'b c'" pkg_quote_list "a|b c"
expect "render" "$(printf 'Depends: a\nDepends: b')" pkg_render_lines "Depends: " "a|b"
note "non-empty lists render as before"

# An empty list left `items` an empty array, and bash 3.2 (macOS) treats
# "${items[@]}" on one as unbound under set -u.
expect "join empty" "" pkg_join_list "" ", "
expect "quote empty" "" pkg_quote_list ""
expect "render empty" "" pkg_render_lines "Depends: " ""
note "empty lists render nothing without an unbound-variable error"

items="caller"
pkg_join_list "x|y" "," >/dev/null
[[ "$items" == "caller" ]] || error "pkg_join_list overwrote the caller's \$items"
note "list helpers keep their array local"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
