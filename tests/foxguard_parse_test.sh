#!/usr/bin/env bash
# SCRIPT: foxguard_parse_test.sh
# DESCRIPTION: Fails when foxguard skips a tracked file for any reason but an unsupported extension.
# USAGE: ./tests/foxguard_parse_test.sh
# PARAMETERS: No required parameters. FOXGUARD_REQUIRE=1 turns a missing pinned
#             foxguard into a failure instead of a skip.
# EXAMPLE: bash tests/foxguard_parse_test.sh
# ----------------------------------------------------
# The pre-push hook and diff gates that run foxguard refuse a changed file
# foxguard skips (parse error, too large), so such a file cannot be pushed or
# vendored. Each tracked file is scanned on its own, the way the hook scans a
# changed file, so hidden paths, templates and fixtures are covered too.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
note() { echo "[foxguard_parse_test] $*"; }

# The pinned foxguard only: another version parses other files, so its answer
# says nothing about what the pre-push hook will refuse.
fox="$(source "$root_dir/lib/foxguard.sh" >/dev/null 2>&1 && foxguard_bin 2>/dev/null)" || fox=""
if [[ -z "$fox" ]]; then
  if [[ "${FOXGUARD_REQUIRE:-0}" == 1 ]]; then
    note "FAIL: the pinned foxguard is not installed and FOXGUARD_REQUIRE=1" >&2
    exit 1
  fi
  note "SKIP: the pinned foxguard is not installed; parse check not run"
  exit 0
fi
note "using $fox ($("$fox" --version 2>&1 | sed -n 1p))"

# fg <dir> <file>: foxguard on one file from <dir>; prints its messages.
# Exit 0 or 1 is a scan (1 = findings); anything else is a failed scan.
fg() { ( cd "$1" && "$fox" --quiet --format json --output /dev/null -- "$2" ) </dev/null 2>&1 >/dev/null; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
skipped=""
while IFS= read -r -d '' f; do
  [[ -f "$root_dir/$f" && ! -L "$root_dir/$f" ]] || continue
  rc=0; out="$(fg "$root_dir" "$f")" || rc=$?
  # A noise path (vendor/, build/, x.min.js) is dropped without a scan; the
  # pre-push hook scans it again from its own directory, then as a copy.
  if [[ $rc -le 1 ]] && grep -q 'noise path' <<<"$out"; then
    rc=0; out="$(fg "$root_dir/$(dirname "$f")" "${f##*/}")" || rc=$?
    out="${out//skipping ${f##*/} (/skipping $f (}"
    if [[ $rc -le 1 ]] && grep -q 'noise path' <<<"$out"; then
      x="${f##*/}"; x="copy.${x##*.}"
      cat < "$root_dir/$f" > "$tmp/$x"
      rc=0; out="$(fg "$tmp" "$x")" || rc=$?
      out="${out//skipping $x (/skipping $f (}"
      if grep -q 'noise path' <<<"$out"; then out+=$'\n'"warning: skipping $f (noise path)"; fi
    fi
  fi
  if [[ $rc -gt 1 ]]; then
    skipped+="$f (foxguard exit $rc)"$'\n'
  elif reason="$(grep -E '^warning: skipping .* \(.*\)$' <<<"$out" \
      | grep -v '(unsupported extension)$')"; then
    skipped+="$reason"$'\n'
  fi
done < <(cd "$root_dir" && git ls-files -z)
if [[ -n "$skipped" ]]; then
  note "FAIL: foxguard skips these tracked files:" >&2
  printf '%s' "$skipped" | sed 's/^/  /' >&2
  exit 1
fi
note "PASS: foxguard reads every tracked file it supports"
