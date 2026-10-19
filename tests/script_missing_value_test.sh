#!/usr/bin/env bash
# SCRIPT: script_missing_value_test.sh
# DESCRIPTION: Every option a script header lists with a value is refused with exit 2 when the value is missing.
# USAGE: bash tests/script_missing_value_test.sh
# ----------------------------------------------------
# The options come from each header's PARAMETERS block: a line such as
# `--workdir <path>` or `-f, --file PATH` takes a value. Each is run as the last
# argument from an empty cwd with CI=true, so it must be refused before anything
# runs. Before require_value, `"$2"` under set -u crashed with exit 1, which a
# gate's caller reads as "found" or "failed", not "called wrongly".
# Collect every failure, not just the first: no -e.
set -uo pipefail
root_dir="${SCRIPT_MISSING_VALUE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
mkdir -p "$tmp/cwd" "$tmp/home"

limit=()
if command -v timeout >/dev/null 2>&1; then limit=(timeout 60); fi

value_options() { # value_options <script>: one option per line
  LC_ALL=C awk '
    NR == 1 && /^#!/ { next }
    !/^#/ { exit }
    /^#[ \t]*-----*/ { exit }
    /^#[ \t]*[A-Z_]+:/ { inp = ($0 ~ /^#[ \t]*PARAMETERS:/); next }
    inp && match($0, /^#[ \t]+-[-A-Za-z0-9]+(,[ \t]*--[-A-Za-z0-9]+)?[ =]+(<[^>]+>|[A-Z][A-Z_]+([ \t]|$))/) {
      s = substr($0, RSTART, RLENGTH); sub(/^#[ \t]+/, "", s)
      n = split(s, a, /[ ,=\t]+/); opt = a[1]
      for (i = 1; i <= n; i++) if (a[i] ~ /^--/) { opt = a[i]; break }
      print opt
    }' "$1"
}

fail=0; count=0
for f in "$root_dir"/scripts/*.sh "$root_dir"/tests/machine/*.sh; do
  [[ -f "$f" ]] || continue
  while IFS= read -r opt; do
    [[ -n "$opt" ]] || continue
    count=$((count + 1))
    rc=0
    out="$(cd "$tmp/cwd" && CI=true HOME="$tmp/home" ${limit[@]+"${limit[@]}"} bash "$f" "$opt" </dev/null 2>&1)" || rc=$?
    if [[ $rc -ne 2 ]]; then
      echo "[script_missing_value_test][ERROR] ${f#"$root_dir"/} $opt (no value) exited $rc, want 2: $(printf '%s' "$out" | tail -n 1)" >&2
      fail=1
    fi
  done < <(value_options "$f")
done
left="$(find "$tmp/cwd" -mindepth 1 -maxdepth 1 | sed "s|^$tmp/cwd/||" | tr '\n' ' ')"
if [[ -n "$left" ]]; then
  echo "[script_missing_value_test][ERROR] a refused option left files in the cwd: $left" >&2
  fail=1
fi
if [[ $count -eq 0 ]]; then echo "[script_missing_value_test][ERROR] no value options found in any header" >&2; fail=1; fi
if [[ $fail -ne 0 ]]; then exit 1; fi
echo "[script_missing_value_test] PASS: $count value options are refused with exit 2 when the value is missing"
