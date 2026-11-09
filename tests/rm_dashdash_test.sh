#!/usr/bin/env bash
# Every rm that runs on this machine takes its paths after `--`, so a path that
# starts with `-` is not read as an option. 0.61.2 added that to every call it
# found; this keeps the next one from being written without it.
#
# Excluded: rm inside `adb shell` (the phone's rm, not ours) and `docker run
# --rm`, which is not rm at all. A comment line is not a call.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[rm_dashdash_test] $*"; }
error() { echo "[rm_dashdash_test][ERROR] $*" >&2; failures=$((failures+1)); }

# An rm with options and then a quoted or unquoted expansion as its first path,
# without `--` between. `(^|[^-[:alnum:]_])` keeps `--rm` and `xrm` out.
pattern='(^|[^-[:alnum:]_])rm[[:space:]]+-[a-zA-Z]+[[:space:]]+["'"'"']?\$'

hits="$(grep -n -E "$pattern" "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/lib/*.sh 2>/dev/null \
  | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -v -E 'adb[[:space:]].*shell[[:space:]]+rm|shell[[:space:]]+rm[[:space:]]' \
  | grep -v -E 'rm[[:space:]]+-[a-zA-Z]+[[:space:]]+--[[:space:]]' || true)"

if [[ -n "$hits" ]]; then
  error "rm without -- before its paths:"
  printf '%s\n' "$hits" | sed "s|^$ROOT_DIR/||" >&2
else
  note "PASS: every local rm in scripts/ and lib/ takes its paths after --"
fi

# The pattern itself: it must see a bare call and leave the guarded forms alone.
probe="$(mktemp)"
printf '%s\n' 'rm -rf "$tmp"' 'rm -f $x' "trap 'rm -f \"\$f\"' EXIT" > "$probe"
n="$(grep -c -E "$pattern" "$probe")"
[[ "$n" == 3 ]] && note "PASS: the pattern sees three unguarded calls" || error "the pattern saw $n of 3 unguarded calls"
printf '%s\n' 'rm -rf -- "$tmp"' 'docker run --rm -t x' '  # rm -f "$old" was here' 'adb -s "$s" shell rm -f "$remote"' > "$probe"
n="$(grep -E "$pattern" "$probe" | grep -v -E '^[[:space:]]*#' | grep -v -E 'shell[[:space:]]+rm[[:space:]]' | grep -c -E -v 'rm[[:space:]]+-[a-zA-Z]+[[:space:]]+--[[:space:]]')"
[[ "$n" == 0 ]] && note "PASS: the pattern leaves --, docker --rm, a comment and adb shell alone" || error "the pattern flagged $n guarded or excluded lines"
rm -f -- "$probe"

if [[ "$failures" -gt 0 ]]; then
  note "FAILED ($failures)"
  exit 1
fi
note "ALL PASSED"
