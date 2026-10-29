#!/usr/bin/env bash
# SCRIPT: foxguard_report_test.sh
# DESCRIPTION: scripts/foxguard_report.sh runs foxguard once per file and writes one formatted JSON report with every finding.
# USAGE: bash tests/foxguard_report_test.sh
# ----------------------------------------------------
set -uo pipefail
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[foxguard_report_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[foxguard_report_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }
py="$(command -v python3 || command -v python || true)"
[[ -n "$py" ]] || { note "SKIP: python not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$tmp/home" XDG_CACHE_HOME="$tmp/home/.cache"
mkdir -p "$HOME" "$tmp/bin"
g() { git -c user.email=t@localhost -c user.name=t -c commit.gpgsign=false "$@"; }

# Like the real foxguard: one path per run (more is exit 2), JSON with -f json,
# and exit 0 whatever it finds. bad.sh has one finding, broken.sh fails.
cat > "$tmp/bin/foxguard" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo "foxguard 9.9.9"; exit 0; }
paths=()
while [[ $# -gt 0 ]]; do case "$1" in -f) shift ;; -q) ;; *) paths+=("$1") ;; esac; shift; done
[[ ${#paths[@]} -eq 1 ]] || { echo "error: unexpected argument" >&2; exit 2; }
case "${paths[0]}" in
  *broken.sh) echo "error: cannot read" >&2; exit 2 ;;
  *bad.sh) printf '{"findings":[{"rule_id":"bash/taint-command-injection","severity":"critical","line":2,"snippet":"eval \\"$x\\""}]}\n' ;;
  *) printf '{"findings":[]}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/foxguard"
export PATH="$tmp/bin:$PATH"

git init -q "$tmp/r" && cd "$tmp/r" || exit 1
echo base > base.txt && g add . && g commit -qm base
base="$(git rev-parse HEAD)"
printf 'x="$1"\neval "$x"\n' > bad.sh; printf 'echo ok\n' > good.sh; printf 'name with space\n' > "a b.sh"
g add . && g commit -qm change

rc=0; out="$(bash "$root_dir/scripts/foxguard_report.sh" --base "$base" --output "$tmp/r.json" 2>&1)" || rc=$?
summary="$("$py" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["files"]), d["finding_counts"]["total"], d["findings"][0]["file"], d["findings"][0]["severity"], len(d["errors"]), d["version"])' "$tmp/r.json" 2>&1)"
[[ $rc -eq 1 && "$summary" == "3 1 bad.sh critical 0 foxguard 9.9.9" ]] && ok "every changed file scanned (one per run), the finding kept with its file; exit 1" \
  || error "report: rc=$rc summary='$summary' out=$out"
grep -q '^  "files"' "$tmp/r.json" && ok "the JSON is formatted (indented)" || error "JSON not indented"

printf 'cat nothing\n' > broken.sh && g add . && g commit -qm broken
rc=0; bash "$root_dir/scripts/foxguard_report.sh" --output "$tmp/r2.json" -- broken.sh good.sh >/dev/null 2>&1 || rc=$?
summary="$("$py" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["files"]), len(d["errors"]), d["errors"][0]["file"])' "$tmp/r2.json" 2>&1)"
[[ $rc -eq 2 && "$summary" == "1 1 broken.sh" ]] && ok "a file foxguard cannot scan is listed under errors, the others scanned; exit 2, not clean" \
  || error "errors: rc=$rc summary='$summary'"

rc=0; out="$(bash "$root_dir/scripts/foxguard_report.sh" --base HEAD --output "$tmp/r3.json" 2>&1)" || rc=$?
[[ $rc -eq 0 && "$out" == *"no files to scan"* && ! -f "$tmp/r3.json" ]] && ok "nothing changed: says so, writes nothing, exit 0" \
  || error "empty range: rc=$rc out=$out"

rc=0; bash "$root_dir/scripts/foxguard_report.sh" --base no-such-ref >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && ok "an unknown base is a usage error (2)" || error "bad base: rc=$rc"

orphan="$(printf 'x\n' | git hash-object -w --stdin)"
orphan="$(printf '100644 blob %s\tx\n' "$orphan" | git mktree)"
orphan="$(git -c user.email=t@localhost -c user.name=t commit-tree "$orphan" -m orphan)"
rc=0; out="$(bash "$root_dir/scripts/foxguard_report.sh" --base "$orphan" --output "$tmp/r4.json" 2>&1)" || rc=$?
[[ $rc -eq 2 && "$out" == *"share no history"* ]] && ok "a base with no common history is exit 2, not a clean empty scan" \
  || error "unrelated base: rc=$rc out=$out"

rc=0; bash "$root_dir/scripts/foxguard_report.sh" --output "$tmp/no/such/dir/r.json" -- good.sh >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && ok "a report that cannot be written is exit 2, not 1 (findings)" || error "unwritable output: rc=$rc"

rm -f "$tmp/bin/foxguard"
# Hide a real foxguard too: one in ~/.local/bin made this pass as installed. A PATH
# entry holding it is replaced by a mirror of its other commands, so a foxguard in
# /usr/bin does not take bash and git with it.
no_fox_path=""; i=0
IFS=: read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  if [[ -x "$d/foxguard" ]]; then
    i=$((i+1)); mkdir -p "$tmp/nofox$i"
    for f in "$d"/*; do [[ "${f##*/}" == foxguard ]] || ln -s "$f" "$tmp/nofox$i/" 2>/dev/null; done
    d="$tmp/nofox$i"
  fi
  no_fox_path="${no_fox_path:+$no_fox_path:}$d"
done
rc=0; out="$(PATH="$no_fox_path" bash "$root_dir/scripts/foxguard_report.sh" -- good.sh 2>&1)" || rc=$?
[[ $rc -eq 3 && "$out" == *"not installing"* ]] && ok "foxguard missing with SCRIPT_HELPERS_NO_AUTO_INSTALL=1: nothing downloaded, exit 3" \
  || error "no-auto-install: rc=$rc out=$out"

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
