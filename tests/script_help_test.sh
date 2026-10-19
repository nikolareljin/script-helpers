#!/usr/bin/env bash
# SCRIPT: script_help_test.sh
# DESCRIPTION: Every scripts/*.sh and tests/machine/*.sh answers --help with usage and exit 0, run from a foreign directory.
# USAGE: bash tests/script_help_test.sh
# ----------------------------------------------------
# A script that is run, not sourced, must find its own library from any cwd and
# must not act on --help. Each runs with CI=true, an empty stdin, a scratch HOME
# and cwd, and a time limit, so one that ignores --help cannot reach anything real.
# Collect every failure, not just the first: no -e.
set -uo pipefail
root_dir="${SCRIPT_HELP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
mkdir -p "$tmp/cwd" "$tmp/home"

# timeout is GNU; macOS may not have it. Without it, run unbounded.
limit=()
if command -v timeout >/dev/null 2>&1; then limit=(timeout 60); fi

fail=0; count=0
for f in "$root_dir"/scripts/*.sh "$root_dir"/tests/machine/*.sh; do
  [[ -f "$f" ]] || continue
  count=$((count + 1))
  for flag in --help -h; do
    rc=0
    out="$(cd "$tmp/cwd" && CI=true HOME="$tmp/home" ${limit[@]+"${limit[@]}"} bash "$f" "$flag" </dev/null 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "[script_help_test][ERROR] ${f#"$root_dir"/} $flag exited $rc: $(printf '%s' "$out" | head -n 2)" >&2
      fail=1
    elif ! printf '%s' "$out" | grep -qi 'usage'; then
      echo "[script_help_test][ERROR] ${f#"$root_dir"/} $flag printed no usage" >&2
      fail=1
    fi
  done
done
left="$(find "$tmp/cwd" -mindepth 1 -maxdepth 1 | sed "s|^$tmp/cwd/||" | tr '\n' ' ')"
if [[ -n "$left" ]]; then
  echo "[script_help_test][ERROR] --help left files in the cwd: $left" >&2
  fail=1
fi
if [[ $fail -ne 0 ]]; then exit 1; fi
echo "[script_help_test] PASS: $count scripts answer --help and -h with usage and exit 0 from a foreign cwd"
