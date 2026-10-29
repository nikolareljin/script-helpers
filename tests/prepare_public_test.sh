#!/usr/bin/env bash
# SCRIPT: prepare_public_test.sh
# DESCRIPTION: scripts/prepare_public.sh finds a listed name anywhere in history, leaves the source alone, and verify passes only on a cleaned copy.
# USAGE: bash tests/prepare_public_test.sh
# ----------------------------------------------------
set -uo pipefail
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pp="$root_dir/scripts/prepare_public.sh"
failures=0
note()  { echo "[prepare_public_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[prepare_public_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }
py="$(command -v python3 || true)"
[[ -n "$py" ]] || { note "SKIP: python3 not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
# git filter-repo is often a pip --user install: keep the real user site visible.
export PYTHONUSERBASE="${PYTHONUSERBASE:-${HOME:-}/.local}"
export HOME="$tmp/home" XDG_CACHE_HOME="$tmp/home/.cache" XDG_CONFIG_HOME="$tmp/home/.config"
export GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin" "$tmp/out"
g() { git -c user.email=dev@users.noreply.github.com -c user.name=dev -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

# gitleaks stand-in, new-style CLI, finds nothing. The credential scan itself is
# check_sensitive's and has its own tests; here it only has to run.
cat > "$tmp/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/gitleaks"
export GITLEAKS_BIN="$tmp/bin/gitleaks"

# The source: the name is in a file later deleted, in a commit message and in a tag message.
git init -q -b main "$tmp/src" && cd "$tmp/src" || exit 1
echo "hello" > README.md && g add . && g commit -qm "start"
printf 'see the secretproj notes\n' > notes.txt && g add . && g commit -qm "add notes"
added="$(git rev-parse HEAD)"
g rm -q notes.txt && g commit -qm "drop the secretproj notes"
msg_commit="$(git rev-parse HEAD)"
g tag -a 1.0.0 -m "release, built for secretproj"
# Places a line scan of contents never sees: an empty file's name, an author.
: > secretproj.cfg && g add . && git -c user.email=dev@users.noreply.github.com -c user.name="secretproj bot" -c commit.gpgsign=false commit -qm "config"
path_commit="$(git rev-parse HEAD)"
# Planted PII, written in two parts so this file itself carries none.
g tag -a 1.0.1 -m "contact jane.roe@""corp-mail.org"
snapshot() { (cd "$tmp/src" && git for-each-ref && git rev-parse HEAD && git status --porcelain && find .git -type f ! -name index | LC_ALL=C sort | xargs cat | cksum); }
before="$(snapshot)"
cd "$tmp/out" || exit 1

names=(--names secretproj)
rc=0; out="$(bash "$pp" audit --source "$tmp/src" --work "$tmp/out/w" "${names[@]}" 2>&1)" || rc=$?
summary="$("$py" -c '
import json,sys
d = json.load(open(sys.argv[1]))
seen = sorted(set((h["check"], h["kind"], h["commit"][:7]) for h in d["hits"]))
print(d["complete"], " ".join("%s:%s@%s" % s for s in seen))' "$tmp/out/w/report.json" 2>&1)"
want="True names:commit-message@${msg_commit:0:7} names:file@${added:0:7} names:identity@ names:path@${path_commit:0:7} names:tag-message@ sensitive:tag-text@"
[[ $rc -eq 1 && "$summary" == "$want" ]] \
  && ok "audit: the name in a deleted file, a commit message, a tag message, a file name and an author, and PII in a tag; exit 1" \
  || error "audit: rc=$rc summary='$summary' want='$want' out=$out"
named="$("$py" -c '
import json,sys
d = json.load(open(sys.argv[1]))
print(all(h.get("names") == ["secretproj"] for h in d["hits"] if h["check"] == "names"), d.get("terms", {}).get("secretproj", {}).get("hits"))' "$tmp/out/w/report.json" 2>&1)"
[[ "$named" == "True 5" ]] && grep -q '^Names found: secretproj 5' "$tmp/out/w/report.txt" \
  && ok "each name hit says which name matched, and the report sums them up" || error "names per hit: '$named'"
grep -q 'secretproj' "$tmp/out/w/report.txt" && ls "$tmp/out/w"/source-*.tar.gz >/dev/null 2>&1 \
  && ok "audit: readable report and the mirror archived" || error "report.txt or archive missing"
[[ "$(snapshot)" == "$before" ]] && ok "the source repository is unchanged" || error "the source changed"
[[ -z "$(git -C "$tmp/out/w/source.git" remote)" ]] && ok "the mirror has no remote back to the source" || error "mirror kept a remote"

rc=0; bash "$pp" audit --source "$tmp/src" --work "$tmp/out/w" "${names[@]}" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && ok "audit refuses an existing work directory" || error "existing work: rc=$rc"
rc=0; bash "$pp" audit --source "$tmp/src" --work "$tmp/src/w" "${names[@]}" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 && ! -e "$tmp/src/w" ]] && ok "audit refuses a work directory inside a checkout" || error "work in checkout: rc=$rc"
rc=0; bash "$pp" audit --source "$tmp/nope" --work "$tmp/out/w3" "${names[@]}" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 && ! -e "$tmp/out/w3" ]] && ok "a source that cannot be cloned leaves no work directory" || error "bad source: rc=$rc"
rc=0; bash "$pp" audit --source "$tmp/src" --work "$tmp/src/.git/w" "${names[@]}" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 && ! -e "$tmp/src/.git/w" ]] && ok "audit refuses a work directory inside the source's .git" || error "work in .git: rc=$rc"
rc=0; bash "$pp" verify --work "$tmp/src" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && ok "verify refuses a directory audit did not make" || error "foreign work: rc=$rc"

rc=0; out="$(GITLEAKS_BIN="$tmp/bin/none" bash "$pp" audit --source "$tmp/src" --work "$tmp/out/w2" "${names[@]}" 2>&1)" || rc=$?
[[ $rc -eq 2 && "$out" == *"NOT a clean result"* ]] && ok "gitleaks unavailable: exit 2, never clean" || error "no gitleaks: rc=$rc out=$out"

# A name the machine's allowlist frees as a word is listed in the report as checked only in
# repository shape, not passed silently.
mkdir -p "$XDG_CONFIG_HOME/script-helpers" && echo otherproj > "$XDG_CONFIG_HOME/script-helpers/private-names-allow"
rc=0; bash "$pp" audit --source "$tmp/src" --work "$tmp/out/w5" --names secretproj,otherproj >/dev/null 2>&1 || rc=$?
skipped="$("$py" -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["names_allowed_as_words"]))' "$tmp/out/w5/report.json" 2>&1)"
[[ "$skipped" == otherproj ]] && grep -q 'checked only as a repository reference: otherproj' "$tmp/out/w5/report.txt" \
  && ok "a name an allowlist frees is reported as checked only in repository shape" || error "allowed-words: skipped='$skipped'"
rm -f "$XDG_CONFIG_HOME/script-helpers/private-names-allow"

# The repository's own name, in the clone line of its own README, is not a hit.
git init -q -b main "$tmp/selfproj" && printf 'git clone https://example.org/me/selfproj.git\ncd selfproj\n' > "$tmp/selfproj/README.md"
g -C "$tmp/selfproj" add . && g -C "$tmp/selfproj" commit -qm start
rc=0; bash "$pp" audit --source "$tmp/selfproj" --work "$tmp/out/w6" --names selfproj,otherproj >/dev/null 2>&1 || rc=$?
own="$("$py" -c 'import json,sys; print(len([h for h in json.load(open(sys.argv[1]))["hits"] if h["check"] == "names"]))' "$tmp/out/w6/report.json" 2>&1)"
[[ $rc -eq 0 && "$own" == 0 ]] && ok "the repository's own name in its clone line is not a hit" || error "own name: rc=$rc hits='$own'"

# Ref names, binary files and LFS pointers: each a place the line scan never reads.
git init -q -b main "$tmp/src2" && cd "$tmp/src2" || exit 1
echo "hello" > README.md && g add . && g commit -qm "start"
g branch feat/secretproj-work
printf 'PK\001\000secretproj build\000\002' > doc.bin && g add . && g commit -qm "a binary file"
# A binary changed only in a merge: the combined diff prints no path for it.
g checkout -qb side && printf 'B\000side\n' > m.bin && g add . && g commit -qm side
g checkout -q main && printf 'C\000main\n' > m.bin && g add . && g commit -qm main
g merge -q side >/dev/null 2>&1; printf 'D\000secretproj merged\n' > m.bin && g add . && g commit -qm merge
cd "$tmp/out" || exit 1
rc=0; bash "$pp" audit --source "$tmp/src2" --work "$tmp/out/r5" "${names[@]}" >/dev/null 2>&1 || rc=$?
kinds="$("$py" -c 'import json,sys; print(" ".join(sorted({h["kind"] for h in json.load(open(sys.argv[1]))["hits"]})))' "$tmp/out/r5/report.json" 2>&1)"
merged="$("$py" -c 'import json,sys; print(sum(1 for h in json.load(open(sys.argv[1]))["hits"] if h["path"] == "m.bin"))' "$tmp/out/r5/report.json" 2>&1)"
[[ "$merged" -ge 1 ]] && ok "a name in a binary file changed only in a merge is a hit" || error "merge binary: '$merged'"
[[ $rc -eq 1 && "$kinds" == "binary-file ref" ]] && ok "a name in a branch name and inside a binary file is a hit" \
  || error "ref/binary: rc=$rc kinds='$kinds'"
perm() { ls -ld "$1" | cut -c1-10; }
[[ "$(perm "$tmp/out/r5")" == drwx------ && "$(perm "$tmp/out/r5/source.git")" == drwx------ \
   && "$(perm "$tmp/out/r5/report.json")" == -rw------- && "$(perm "$(ls "$tmp/out/r5"/source-*.tar.gz)")" == -rw------- ]] \
  && ok "the work directory, mirror, archive and report are readable by the owner only" \
  || error "modes: $(perm "$tmp/out/r5") $(perm "$tmp/out/r5/report.json")"

git init -q -b main "$tmp/src3" && cd "$tmp/src3" || exit 1
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 12\n' 0 > big.bin
g add . && g commit -qm "lfs"
cd "$tmp/out" || exit 1
rc=0; out="$(bash "$pp" audit --source "$tmp/src3" --work "$tmp/out/r6" "${names[@]}" 2>&1)" || rc=$?
[[ $rc -eq 2 && "$out" == *"LFS"*"big.bin"* ]] && ok "a Git LFS file is reported as not checked: exit 2, never clean" \
  || error "lfs: rc=$rc out=$out"

git init -q -b main "$tmp/src4" && cd "$tmp/src4" || exit 1
printf 'caf\351 secretproj\n' > latin1.txt && g add . && g commit -qm "latin-1 text"
echo "other" > other.txt && git -c user.email=dev@build-box.local -c user.name=dev -c commit.gpgsign=false add . \
  && git -c user.email=dev@build-box.local -c user.name=dev -c commit.gpgsign=false commit -qm "from a laptop"
parents_commit="$(git rev-parse HEAD)"
cd "$tmp/out" || exit 1
utf8="$(locale -a 2>/dev/null | grep -i -E '^(c|en_us)\.utf-?8$' | sed -n 1p || true)"
if [[ -n "$utf8" ]]; then
  rc=0; out="$(LC_ALL="$utf8" bash "$pp" audit --source "$tmp/src4" --work "$tmp/out/r10" "${names[@]}" 2>&1)" || rc=$?
  [[ $rc -eq 1 && "$out" != *"NOT read"* && "$out" != *INCOMPLETE* ]] \
    && ok "a file that is not UTF-8, audited in a UTF-8 locale: the name is found, the result is complete" \
    || error "latin-1 in $utf8: rc=$rc out=$out"
else
  rc=0; bash "$pp" audit --source "$tmp/src4" --work "$tmp/out/r10" "${names[@]}" >/dev/null 2>&1 || rc=$?
  note "SKIP: no UTF-8 locale; latin-1 audit rc=$rc"
fi
localid="$("$py" -c 'import json,sys; print(sum(1 for h in json.load(open(sys.argv[1]))["hits"] if h["kind"] == "identity" and "build-box.local" in h["text"]))' "$tmp/out/r10/report.json" 2>&1)"
[[ "$localid" == 1 ]] && ok "an author email at a machine-local domain (.local) is a hit" || error "local identity: '$localid'"

rc=0; bash "$pp" audit --source "--upload-pack=touch $tmp/pwned" --work "$tmp/out/r7" "${names[@]}" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 && ! -e "$tmp/pwned" ]] && ok "a source starting with a dash is a path, never a git option" || error "dash source: rc=$rc"
rc=0; bash "$pp" audit --source >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && ok "an option without its value is a usage error (2)" || error "missing value: rc=$rc"
rc=0; bash "$pp" audit --source="$tmp/src2" --work="$tmp/out/r8" --names=secretproj >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] && ok "--option=value works" || error "--opt=value: rc=$rc"
# Killed mid-run (gitleaks stand-in sleeps), the scratch copy of the history goes too.
mkdir -p "$tmp/tmpd"
printf '#!/usr/bin/env bash\nsleep 3\nexit 0\n' > "$tmp/bin/gitleaks-slow" && chmod +x "$tmp/bin/gitleaks-slow"
TMPDIR="$tmp/tmpd" GITLEAKS_BIN="$tmp/bin/gitleaks-slow" bash "$pp" audit --source "$tmp/src2" --work "$tmp/out/r9" "${names[@]}" >/dev/null 2>&1 &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -n "$(ls -A "$tmp/tmpd")" ]] && break; sleep 0.5; done
sleep 1; kill -TERM "$pid" 2>/dev/null; rc=0; wait "$pid" || rc=$?
[[ $rc -ne 0 && -z "$(ls -A "$tmp/tmpd")" ]] && ok "killed mid-run: no scratch copy of the history is left behind" || error "scratch left: rc=$rc $(ls -A "$tmp/tmpd")"

if ! git filter-repo --version >/dev/null 2>&1; then
  # CI installs it, so a skip there would hide the two steps that rewrite history.
  if [[ -n "${CI:-}" && "$(uname -s)" == Linux ]]; then error "git filter-repo missing on Linux CI"
  else note "SKIP: git filter-repo not installed; clean and verify not tested here"; fi
else
  printf 'ref refs/heads/*\nref refs/tags/1.0.0\nreplace secretproj==>R-001\nrename secretproj.cfg==>app.cfg\nmailmap R-001 bot <dev@users.noreply.github.com> secretproj bot <dev@users.noreply.github.com>\n' > "$tmp/plan"
  rc=0; out="$(bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan" 2>&1)" || rc=$?
  [[ $rc -eq 0 ]] && grep -q 'message' "$tmp/out/w/changes.txt" \
    && ok "clean: public.git built, changes.txt lists the rewritten commits" || error "clean: rc=$rc out=$out"
  rc=0; out="$(bash "$pp" verify --work "$tmp/out/w" "${names[@]}" 2>&1)" || rc=$?
  total="$("$py" -c 'import json,sys; print(json.load(open(sys.argv[1]))["hit_counts"]["total"])' "$tmp/out/w/report-public.json" 2>&1)"
  [[ $rc -eq 0 && "$total" == 0 ]] && ok "verify: zero hits after the replacement; exit 0" || error "verify: rc=$rc total=$total out=$out"
  [[ "$(git -C "$tmp/out/w/public.git" for-each-ref --format='%(contents)' refs/tags/1.0.0)" == *R-001* ]] \
    && ok "the tag message is rewritten too" || error "tag message not rewritten"
  [[ "$(snapshot)" == "$before" ]] && ok "the source is still unchanged after clean" || error "the source changed after clean"

  printf 'ref refs/heads/main\nreplace secretproj==>R-001\n' > "$tmp/plan8"
  bash "$pp" clean --work "$tmp/out/r10" --plan "$tmp/plan8" >/dev/null 2>&1
  grep -q "^${parents_commit:0:12} [0-9a-f]\{12\} parents$" "$tmp/out/r10/changes.txt" \
    && ok "changes.txt: a commit rewritten only for its parent reads 'parents', not 'unchanged'" \
    || error "parents-only: $(cat "$tmp/out/r10/changes.txt" 2>&1)"

  printf 'ref refs/heads/main\n' > "$tmp/plan2"
  bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan2" >/dev/null 2>&1
  rc=0; bash "$pp" verify --work "$tmp/out/w" "${names[@]}" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 1 ]] && ok "verify: a name left out of the replacements is exit 1" || error "unreplaced name: rc=$rc"
  [[ -z "$(git -C "$tmp/out/w/public.git" for-each-ref refs/tags)" ]] && ok "clean keeps only the refs the plan names" || error "unlisted tag kept"

  printf 'ref refs/heads/main\ndrop notes.txt\nreplace secretproj==>R-001\n' > "$tmp/plan3"
  rc=0; bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan3" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 0 && -z "$(git -C "$tmp/out/w/public.git" log --all --format=%H -- notes.txt)" ]] \
    && ok "drop removes a path from all history" || error "drop: rc=$rc"
  printf 'ref refs/heads/main\ndrop notes.tx\n' > "$tmp/plan5"
  rc=0; out="$(bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan5" 2>&1)" || rc=$?
  [[ $rc -eq 2 && "$out" == *"not a path anywhere"* ]] && ok "a drop path that never existed is refused, not ignored" || error "drop typo: rc=$rc out=$out"
  printf 'ref refs/heads/main\ndrop *.txt\n' > "$tmp/plan7"
  rc=0; bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan7" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] && ok "a glob in drop is refused: filter-repo takes paths literally" || error "drop glob: rc=$rc"
  printf 'ref refs/heads/main \ndrop notes.txt  \nreplace secretproj==>R-001\n' > "$tmp/plan6"
  rc=0; bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan6" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 0 && -z "$(git -C "$tmp/out/w/public.git" log --all --format=%H -- notes.txt)" ]] \
    && ok "trailing spaces in a plan line are trimmed" || error "trailing space: rc=$rc"
  # An exported GIT_DIR (a hook, a wrapper) must not turn clean onto the source.
  rc=0; GIT_DIR="$tmp/src/.git" bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan2" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 0 && "$(snapshot)" == "$before" ]] && ok "an exported GIT_DIR does not reach the source" || error "GIT_DIR: rc=$rc, source changed?"
  printf 'bogus x\n' > "$tmp/plan4"
  rc=0; bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan4" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] && ok "an unknown plan directive is refused" || error "bad plan: rc=$rc"
  rc=0; bash "$pp" verify --work "$tmp/out/w" "${names[@]}" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] && ok "verify refuses public.git after a clean that did not finish" || error "verify after failed clean: rc=$rc"
  printf 'ref refs/heads/main\ndrop README.md\ndrop doc.bin\ndrop m.bin\n' > "$tmp/plan7"
  rc=0; out="$(bash "$pp" clean --work "$tmp/out/r5" --plan "$tmp/plan7" 2>&1)" || rc=$?
  [[ $rc -eq 2 && "$out" == *"no ref is left"* ]] && ok "a plan that empties the history is refused, not reported done" \
    || error "empty after plan: rc=$rc out=$out"
fi

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
