#!/usr/bin/env bash
# SCRIPT: foxguard_push_compare_test.sh
# DESCRIPTION: Tests how scripts/foxguard_push_compare.py reads --base-unscanned.
# USAGE: ./tests/foxguard_push_compare_test.sh
# PARAMETERS: None.
# EXAMPLE: bash tests/foxguard_push_compare_test.sh
# ----------------------------------------------------
# Needs no foxguard: the reports are written here. The hook passes one
# --base-unscanned after each --base whose scan skipped files.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$ROOT_DIR/scripts/foxguard_push_compare.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

run() {  # <description> <want rc> <want verdict prefix or -> args...
  local desc="$1" want="$2" verdict="$3" rc=0
  shift 3
  "$py" -I "$helper" --level high --tip "$tmp/tip.json" "$@" > "$tmp/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then error "$desc: want exit $want, got $rc"; sed 's/^/    | /' "$tmp/out" >&2; return; fi
  if [[ "$verdict" != - ]] && ! grep -q "^$verdict	" "$tmp/out"; then error "$desc: no $verdict line"; sed 's/^/    | /' "$tmp/out" >&2; return; fi
  ok "$desc"
}

run "a file the only base skipped warns" 0 WARN --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
run "a file over 1 MB at the base warns" 0 WARN --base "$tmp/clean.json" --base-unscanned "$tmp/skip_big"
run "a skip of another file does not hide it" 3 BLOCK --base "$tmp/clean.json" --base-unscanned "$tmp/skip_other"
run "no skip list: a new finding blocks" 3 BLOCK --base "$tmp/clean.json"
run "a second base that scanned the file still blocks it" 3 BLOCK \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json"
run "the same, with the readable base first" 3 BLOCK \
  --base "$tmp/clean.json" --base "$tmp/clean.json" --base-unscanned "$tmp/skip"
run "every base skipped it: it warns" 0 WARN \
  --base "$tmp/clean.json" --base-unscanned "$tmp/skip" --base "$tmp/clean.json" --base-unscanned "$tmp/skip_big"
run "a skip list with no base refuses" 2 - --base-unscanned "$tmp/skip"
run "a missing skip list refuses" 2 - --base "$tmp/clean.json" --base-unscanned "$tmp/missing"
run "a malformed skip list refuses" 2 - --base "$tmp/clean.json" --base-unscanned "$tmp/bad"
: > "$tmp/empty"
run "an empty skip list hides nothing" 3 BLOCK --base "$tmp/clean.json" --base-unscanned "$tmp/empty"

if [[ "$failures" -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
