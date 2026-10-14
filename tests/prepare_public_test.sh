#!/usr/bin/env bash
# SCRIPT: prepare_public_test.sh
# DESCRIPTION: scripts/prepare_public.sh finds a private name anywhere in history, leaves the source alone, and verify passes only on a cleaned copy.
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
grep -q 'secretproj' "$tmp/out/w/report.txt" && ls "$tmp/out/w"/source-*.tar.gz >/dev/null 2>&1 \
  && ok "audit: readable report and the mirror archived" || error "report.txt or archive missing"
[[ "$(snapshot)" == "$before" ]] && ok "the source repository is unchanged" || error "the source changed"
[[ -z "$(git -C "$tmp/out/w/source.git" remote)" ]] && ok "the mirror has no remote back to the source" || error "mirror kept a remote"

rc=0; bash "$pp" audit --source "$tmp/src" --work "$tmp/out/w" "${names[@]}" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && ok "audit refuses an existing work directory" || error "existing work: rc=$rc"
rc=0; bash "$pp" audit --source "$tmp/src" --work "$tmp/src/w" "${names[@]}" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 && ! -e "$tmp/src/w" ]] && ok "audit refuses a work directory inside a checkout" || error "work in checkout: rc=$rc"
rc=0; bash "$pp" verify --work "$tmp/src" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && ok "verify refuses a directory audit did not make" || error "foreign work: rc=$rc"

rc=0; out="$(GITLEAKS_BIN="$tmp/bin/none" bash "$pp" audit --source "$tmp/src" --work "$tmp/out/w2" "${names[@]}" 2>&1)" || rc=$?
[[ $rc -eq 2 && "$out" == *"NOT a clean result"* ]] && ok "gitleaks unavailable: exit 2, never clean" || error "no gitleaks: rc=$rc out=$out"

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

  printf 'ref refs/heads/main\n' > "$tmp/plan2"
  bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan2" >/dev/null 2>&1
  rc=0; bash "$pp" verify --work "$tmp/out/w" "${names[@]}" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 1 ]] && ok "verify: a name left out of the replacements is exit 1" || error "unreplaced name: rc=$rc"
  [[ -z "$(git -C "$tmp/out/w/public.git" for-each-ref refs/tags)" ]] && ok "clean keeps only the refs the plan names" || error "unlisted tag kept"

  printf 'ref refs/heads/main\ndrop notes.txt\nreplace secretproj==>R-001\n' > "$tmp/plan3"
  rc=0; bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan3" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 0 && -z "$(git -C "$tmp/out/w/public.git" log --all --format=%H -- notes.txt)" ]] \
    && ok "drop removes a path from all history" || error "drop: rc=$rc"
  printf 'bogus x\n' > "$tmp/plan4"
  rc=0; bash "$pp" clean --work "$tmp/out/w" --plan "$tmp/plan4" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] && ok "an unknown plan directive is refused" || error "bad plan: rc=$rc"
fi

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
