#!/usr/bin/env bash
# SCRIPT: foxguard_push_compare_test.sh
# DESCRIPTION: Tests how scripts/foxguard_push_compare.py reads --base-unscanned and --base-absent.
# USAGE: ./tests/foxguard_push_compare_test.sh
# PARAMETERS: None.
# EXAMPLE: bash tests/foxguard_push_compare_test.sh
# ----------------------------------------------------
# Needs no foxguard: the reports are written here. The hook passes one
# --base-unscanned after each --base whose scan skipped files, and one
# --base-absent after each --base that lacks some of the changed files.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$ROOT_DIR/scripts/foxguard_push_compare.py"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

failures=0
note()  { echo "[foxguard_push_compare_test] $*"; }
error() { echo "[foxguard_push_compare_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }

py="$(command -v python3 || true)"
if [[ -z "$py" ]]; then note "SKIP: python3 not found"; exit 0; fi

cat > "$tmp/tip.json" <<'EOF'
{"findings":[{"rule_id":"py/no-yaml-load","severity":"high","file":"loader.py","line":3,"snippet":"yaml.load(x)","description":"d"}]}
EOF
echo '{"findings":[]}' > "$tmp/clean.json"
printf 'warning: skipping loader.py (parse error)\n' > "$tmp/skip"
printf 'warning: skipping other.py (parse error)\n' > "$tmp/skip_other"
printf 'warning: skipping loader.py (1600001 bytes exceeds --max-file-size)\n' > "$tmp/skip_big"
printf 'not a skip line\n' > "$tmp/bad"

tip="$tmp/tip.json"
run() {  # <description> <want rc> <want verdict prefix or -> args...
  local desc="$1" want="$2" verdict="$3" rc=0
  shift 3
  "$py" -I "$helper" --level high --tip "$tip" "$@" > "$tmp/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then error "$desc: want exit $want, got $rc"; sed 's/^/    | /' "$tmp/out" >&2; return; fi
  if [[ "$verdict" != - ]] && ! grep -q "^$verdict	" "$tmp/out"; then error "$desc: no $verdict line"; sed 's/^/    | /' "$tmp/out" >&2; return; fi
  ok "$desc"
}

run "a file the only base skipped blocks without the override" 3 BLOCK --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
grep -qF "push with SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1" "$tmp/out" && ok "the block names the override" || error "the block does not name the override"
run "with --allow-unscanned it warns" 0 WARN --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
grep -qF "allowed by SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1" "$tmp/out" && ok "the warning names the override" || error "the warning does not name the override"
run "a file over 1 MB at the base warns with --allow-unscanned" 0 WARN --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/skip_big"
run "with --allow-unscanned, a skip of another file does not hide it" 3 BLOCK --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/skip_other"
run "no skip list: a new finding blocks" 3 BLOCK --allow-unscanned --base "$tmp/clean.json"
run "a second base that scanned the file still blocks it" 3 BLOCK --allow-unscanned \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json"
run "the same, with the readable base first" 3 BLOCK --allow-unscanned \
  --base "$tmp/clean.json" --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
run "every base skipped it: it warns with --allow-unscanned" 0 WARN --allow-unscanned \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json" --base-unscanned "$tmp/skip_big"
run "below the level it warns" 0 WARN --level critical --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
run "a skip list with no base refuses" 2 - --allow-unscanned --base-unscanned "$tmp/skip"
run "a missing skip list refuses, even with --allow-unscanned" 2 - --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/missing"
run "a malformed skip list refuses, even with --allow-unscanned" 2 - --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/bad"
: > "$tmp/empty"
run "an empty skip list hides nothing" 3 BLOCK --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/empty"
# A base that is not among the reports skipped nothing.
run "a base left out: the file blocks, even with --allow-unscanned" 3 BLOCK --allow-unscanned --base-incomplete \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
grep -qF "another base was not scanned, so SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1 does not apply" "$tmp/out" \
  && ok "the block says the override does not apply" || error "the block does not say the override does not apply"
# A base that does not have the file neither read nor skipped it: the file
# is unscanned when another base skipped it, and new when no base has it.
printf 'loader.py\n' > "$tmp/absent"
printf 'other.py\n' > "$tmp/absent_other"
run "skipped by one base, absent from the other: it blocks without the override" 3 BLOCK \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json" --base-absent "$tmp/absent"
grep -qF "could not be scanned (parse error); review the file, then push with SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1" "$tmp/out" \
  && ok "the block names the reason and the override" || error "skipped and absent: the block does not name the override"
run "skipped by one base, absent from the other: it warns with --allow-unscanned" 0 WARN --allow-unscanned \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json" --base-absent "$tmp/absent"
run "the same, with the base that lacks it first" 0 WARN --allow-unscanned \
  --base "$tmp/clean.json" --base-absent "$tmp/absent" --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
run "skipped by one, absent from one, scanned by a third: it blocks" 3 BLOCK --allow-unscanned \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json" --base-absent "$tmp/absent" --base "$tmp/clean.json"
run "absent from every base: it is new, with --allow-unscanned too" 3 BLOCK --allow-unscanned \
  --base "$tmp/clean.json" --base-absent "$tmp/absent" --base "$tmp/clean.json" --base-absent "$tmp/absent"
grep -q "	new	" "$tmp/out" && ok "and it is named new" || error "a file no base has is not named new"
run "a base that lacks another file still judges this one" 3 BLOCK --allow-unscanned \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json" --base-absent "$tmp/absent_other"
run "skipped and absent, with a base left out: it blocks" 3 BLOCK --allow-unscanned --base-incomplete \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json" --base-absent "$tmp/absent"
run "an absent list with no base refuses" 2 - --allow-unscanned --base-absent "$tmp/absent"
run "a missing absent list refuses" 2 - --allow-unscanned --base "$tmp/clean.json" --base-absent "$tmp/missing"
# One line names one file: junk<CR>loader.py is not loader.py.
printf 'junk\rloader.py\n' > "$tmp/absent_cr"
run "a carriage return in an absent name does not name a second file" 3 BLOCK --allow-unscanned \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json" --base-absent "$tmp/absent_cr"
# A control character in a file name is printed escaped: on a terminal a
# carriage return or an escape sequence would draw over the verdict.
printf '{"findings":[{"rule_id":"r","severity":"high","file":"a\\rb\\u001b[2K.py","line":3,"snippet":"s","description":"d"}]}\n' > "$tmp/tip_ctl.json"
tip="$tmp/tip_ctl.json"
run "a file name with control characters blocks" 3 BLOCK --base "$tmp/clean.json"
tip="$tmp/tip.json"
if grep -qF 'a\x0db\x1b[2K.py:3' "$tmp/out" && ! LC_ALL=C grep -q "$(printf '[\r\033]')" "$tmp/out"; then
  ok "and is printed with them escaped"
else
  error "control characters reach the terminal: $(cat -v "$tmp/out")"
fi
# So are the C1 controls and the characters that reorder the text.
printf '{"findings":[{"rule_id":"r","severity":"high","file":"a\\u009bb\\u202ec d.py","line":3,"snippet":"s","description":"d"}]}\n' > "$tmp/tip_c1.json"
tip="$tmp/tip_c1.json"
run "a file name with U+009B and U+202E blocks" 3 BLOCK --base "$tmp/clean.json"
if grep -qF 'a\x9bb\u202ec d.py:3' "$tmp/out"; then ok "and is printed with them escaped, a space as it is"
else error "U+009B or U+202E reaches the terminal: $(cat -v "$tmp/out")"; fi
# A finding with no rule keeps its column: the hook splits the line on tabs,
# and two tabs in a row would move the reason into the rule.
printf '{"findings":[{"severity":"high","file":"loader.py","line":3,"snippet":"s","description":"d"}]}\n' > "$tmp/tip_norule.json"
tip="$tmp/tip_norule.json"
run "a finding with no rule blocks" 3 BLOCK --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
if [[ "$(awk -F'\t' '{ print $4 }' "$tmp/out")" == - ]]; then ok "and its rule column is not empty"
else error "an empty rule column: $(cat -v "$tmp/out")"; fi
# The lines are UTF-8 whatever the locale says: a name outside the locale's
# encoding (cp1252 on Windows) must not fail the comparison. Nor do they end
# in a carriage return, as text written by a Windows Python does.
cat > "$tmp/as_ascii.py" <<'PYEOF'
import io, runpy, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="ascii", newline="\r\n")
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
PYEOF
printf '{"findings":[{"rule_id":"r","severity":"high","file":"\\u0436.py","line":3,"snippet":"s","description":"d"}]}\n' > "$tmp/tip_cyr.json"
rc=0; "$py" -I "$tmp/as_ascii.py" "$helper" --level high --tip "$tmp/tip_cyr.json" --base "$tmp/clean.json" > "$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -eq 3 ]] && grep -q "^BLOCK	high	$(printf '\320\266').py:3" "$tmp/out"; then ok "a name outside the locale's encoding is printed as UTF-8"
else error "a name outside the locale's encoding: exit $rc: $(cat -v "$tmp/out")"; fi
if LC_ALL=C grep -q "$(printf '\r')" "$tmp/out"; then error "a line ends in a carriage return: $(cat -v "$tmp/out")"; else ok "and no line ends in a carriage return"; fi
tip="$tmp/tip.json"
# --names: the changed paths, checked before foxguard is handed any.
names() {  # <description> <want rc> <list>
  local rc=0
  "$py" -I "$helper" --names "$3" > "$tmp/out" 2>&1 || rc=$?
  if [[ "$rc" == "$2" ]]; then ok "$1"; else error "$1: want exit $2, got $rc"; sed 's/^/    | /' "$tmp/out" >&2; fi
}
printf 'loader.py\nsrc/%s.py\n' "$(printf '\320\266')" > "$tmp/names_ok"
printf 'loader.py\na\377b.py\nc\033\376.py\n' > "$tmp/names_bad"
names "--names: paths that are UTF-8 pass" 0 "$tmp/names_ok"
[[ ! -s "$tmp/out" ]] && ok "and print nothing" || error "--names printed: $(cat -v "$tmp/out")"
names "--names: a path that is not UTF-8 is exit 4" 4 "$tmp/names_bad"
if [[ "$(cat "$tmp/out")" == 'a\xffb.py'$'\n''c\x1b\xfe.py' ]]; then ok "and each such path is printed, escaped"
else error "--names printed: $(cat -v "$tmp/out")"; fi
names "--names: a list that cannot be read refuses" 2 "$tmp/missing"
rc=0; "$py" -I "$helper" --names "$tmp/names_ok" --level high > "$tmp/out" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && ok "--names with a comparison argument refuses" || error "--names --level: exit $rc"
rc=0; "$py" -I "$helper" --level high > "$tmp/out" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && ok "no --tip refuses" || error "no --tip: exit $rc"
# One skip line names one file: a carriage return in a name starts no line.
printf 'warning: skipping junk (a)\rwarning: skipping loader.py (parse error)\n' > "$tmp/skip_cr"
run "a carriage return in a skipped name does not name a second file" 3 BLOCK --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/skip_cr"
# <n>.path names a file scanned from its own directory. A carriage return in
# it is part of the name: vendor/x.py<CR> is not the skipped vendor/x.py.
mkdir -p "$tmp/tip_cr" "$tmp/tip_cr2"
cp "$tmp/tip.json" "$tmp/tip_cr/1.json"; cp "$tmp/tip.json" "$tmp/tip_cr2/1.json"
printf 'vendor/x.py\r\n' > "$tmp/tip_cr/1.path"
printf 'vendor/c\rd.py\n' > "$tmp/tip_cr2/1.path"
printf 'warning: skipping vendor/x.py (parse error)\n' > "$tmp/skip_vendor"
printf 'warning: skipping vendor/c\rd.py (parse error)\n' > "$tmp/skip_vendor_cr"
tip="$tmp/tip_cr"
run "a name ending in a carriage return is not the skipped file" 3 BLOCK --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/skip_vendor"
tip="$tmp/tip_cr2"
run "a skipped name with a carriage return is matched as written" 0 WARN --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/skip_vendor_cr"
tip="$tmp/tip.json"
# Windows, also under MSYS or Cygwin where os.sep is "/": a\b.py is a/b.py.
cat > "$tmp/as_cygwin.py" <<'PYEOF'
import runpy, sys
sys.platform = "cygwin"
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
PYEOF
cat > "$tmp/tip_win.json" <<'EOF'
{"findings":[{"rule_id":"py/no-yaml-load","severity":"high","file":"a\\b.py","line":3,"snippet":"yaml.load(x)","description":"d"}]}
EOF
printf 'warning: skipping a/b.py (parse error)\n' > "$tmp/skip_slash"
rc=0; "$py" -I "$tmp/as_cygwin.py" "$helper" --level high --tip "$tmp/tip_win.json" --allow-unscanned \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip_slash" > "$tmp/out" 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "^WARN	.*a/b.py:3" "$tmp/out"; then ok "under Cygwin Python a\\b.py is the skipped a/b.py"
else error "under Cygwin Python a\\b.py is not read as a/b.py (exit $rc)"; sed 's/^/    | /' "$tmp/out" >&2; fi
# Where / separates directories, a\b.py is not a/b.py.
if [[ "$("$py" -I -c 'import os; print(os.sep)')" == / ]]; then
  cat > "$tmp/tip_dir.json" <<'EOF'
{"findings":[{"rule_id":"py/no-yaml-load","severity":"high","file":"a/b.py","line":3,"snippet":"yaml.load(x)","description":"d"}]}
EOF
  cat > "$tmp/base_backslash.json" <<'EOF'
{"findings":[{"rule_id":"py/no-yaml-load","severity":"high","file":"a\\b.py","line":3,"snippet":"yaml.load(x)","description":"d"}]}
EOF
  printf 'warning: skipping a\\b.py (parse error)\n' > "$tmp/skip_backslash"
  tip="$tmp/tip_dir.json"
  run "a skipped a\\b.py does not cover a/b.py" 3 BLOCK --allow-unscanned --base "$tmp/clean.json" --base-unscanned "$tmp/skip_backslash"
  run "a finding in a\\b.py at the base does not vouch for a/b.py" 3 BLOCK --base "$tmp/base_backslash.json"
  tip="$tmp/tip.json"
fi

# The hook prints some names itself (sec_foxguard_show) and the helper prints
# the rest (shown): a character one of them hides must not get through the
# other. Every code point from U+0080 up goes through the hook's filter: each
# one of the list below is replaced, and nothing the helper would print is.
# -B: importing the helper must not leave a __pycache__ in scripts/.
cat > "$tmp/points.py" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from foxguard_push_compare import shown
MUST = [0xAD, 0x61C, 0x6DD, 0x70F, 0x890, 0x891, 0x8E2, 0x180E, 0xFEFF, 0x110BD, 0x110CD, 0xE0001]
for lo, hi in ((0x80, 0x9F), (0x600, 0x605), (0x200B, 0x200F), (0x2028, 0x202E), (0x2060, 0x206F), (0xFFF9, 0xFFFB),
               (0x13430, 0x1343F), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A), (0xE0020, 0xE007F)):
    MUST.extend(range(lo, hi + 1))
points = [cp for cp in range(0x80, 0x30000) if not 0xD800 <= cp <= 0xDFFF] + list(range(0xE0000, 0xE0080))
if sys.argv[2] == "write":
    with open(sys.argv[3], "w", encoding="utf-8", newline="\n") as out:
        for cp in points:
            out.write(f"{cp:06X} {chr(cp)}\n")
    sys.exit(0)
with open(sys.argv[3], encoding="utf-8", newline="\n") as got:
    lines = got.read().split("\n")[:-1]
bad = []
if len(lines) != len(points):
    bad.append(f"{len(lines)} lines for {len(points)} code points")
for cp, line in zip(points, lines):
    if line == f"{cp:06X} ?":
        if shown(chr(cp)) == chr(cp):
            bad.append(f"U+{cp:04X} is hidden by the hook and printed by the helper")
    elif line != f"{cp:06X} {chr(cp)}":
        bad.append(f"U+{cp:04X} came out as {line!r}")
    elif cp in MUST:
        bad.append(f"U+{cp:04X} is printed by the hook")
    if cp in MUST and shown(chr(cp)) == chr(cp):
        bad.append(f"U+{cp:04X} is printed by the helper")
print("\n".join(bad[:10]))
sys.exit(1 if bad else 0)
EOF
"$py" -I -B "$tmp/points.py" "$ROOT_DIR/scripts" write "$tmp/points"
bash -c 'source "$1/scripts/security_hooks.sh"; sec_foxguard_show "" < "$2"' _ "$ROOT_DIR" "$tmp/points" 2> "$tmp/points.shown"
if "$py" -I -B "$tmp/points.py" "$ROOT_DIR/scripts" check "$tmp/points.shown" > "$tmp/out" 2>&1; then
  ok "the hook and the helper hide the same control, reordering and invisible characters, and no letter"
else
  error "sec_foxguard_show and shown() disagree: $(cat "$tmp/out")"
fi

if [[ "$failures" -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
