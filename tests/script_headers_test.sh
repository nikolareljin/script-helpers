#!/usr/bin/env bash
# SCRIPT: script_headers_test.sh
# DESCRIPTION: Every command script has the full header, in order, in ASCII, closed by a ---- line.
# USAGE: bash tests/script_headers_test.sh
# ----------------------------------------------------
# Checks scripts/*.sh, scripts/*.ps1, ps/scripts/*.ps1 and the real-machine
# checks in tests/machine and ps/tests/machine. Fields, in order:
# SCRIPT, DESCRIPTION, USAGE, PARAMETERS, EXIT_CODES, EXAMPLE. The header is the
# comment block at the top (after an optional #! line) up to a "# ----" line;
# scripts/gen_command_reference.py builds docs/commands.md from it.
# Collect every failure, not just the first: no -e.
set -uo pipefail
root_dir="${SCRIPT_HEADERS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

check_file() {
  # Prints one line per problem; awk exits 1 when there was any.
  LC_ALL=C awk '
    BEGIN { n = split("SCRIPT DESCRIPTION USAGE PARAMETERS EXIT_CODES EXAMPLE", want, " "); got = 0; rule = 0; bad = 0 }
    NR == 1 && /^#!/ { next }
    !/^#/ { exit }
    /^#[ \t]*-----*/ { rule = 1; exit }
    {
      if ($0 ~ /[^\t -~]/) { print "non-ASCII in header line " NR; bad = 1 }
      if (match($0, /^#[ \t]*[A-Z_]+:/)) {
        key = substr($0, RSTART, RLENGTH); sub(/^#[ \t]*/, "", key); sub(/:$/, "", key)
        for (i = 1; i <= n; i++) if (want[i] == key) {
          if (i <= got) { print "field " key " out of order"; bad = 1 }
          else { for (j = got + 1; j < i; j++) { print "missing field " want[j] " (before " key ")"; bad = 1 } got = i }
        }
      }
    }
    END {
      for (j = got + 1; j <= n; j++) { print "missing field " want[j]; bad = 1 }
      if (!rule) { print "no \"# ----\" line closing the header"; bad = 1 }
      exit bad
    }' "$1"
}

fail=0; count=0
for f in "$root_dir"/scripts/*.sh "$root_dir"/scripts/*.ps1 "$root_dir"/ps/scripts/*.ps1 \
         "$root_dir"/tests/machine/*.sh "$root_dir"/ps/tests/machine/*.ps1; do
  [[ -f "$f" ]] || continue
  count=$((count + 1))
  if ! out="$(check_file "$f")"; then
    while IFS= read -r line; do
      echo "[script_headers_test][ERROR] ${f#"$root_dir"/}: $line" >&2
    done <<< "$out"
    fail=1
  fi
done
if [[ $fail -ne 0 ]]; then exit 1; fi
echo "[script_headers_test] PASS: $count command scripts have a complete, ordered, ASCII header"
