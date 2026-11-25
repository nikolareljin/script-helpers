#!/usr/bin/env bash
# SCRIPT: foxguard_block_test.sh
# DESCRIPTION: Tests the foxguard block levels of the pre-push hook (security.foxguardBlock).
# USAGE: ./tests/foxguard_block_test.sh
# PARAMETERS: No required parameters. FOXGUARD_REQUIRE=1 turns a missing foxguard
#             into a failure instead of skipping the cases that need it.
# EXAMPLE: bash tests/foxguard_block_test.sh
# ----------------------------------------------------
# The cases with findings run the real foxguard (the pinned one in the cache,
# else foxguard on PATH): a stub would only encode what we believe it reports.
# The level, fail-closed and precedence cases need no foxguard.
set -uo pipefail
unset CI GITHUB_ACTIONS FOXGUARD_CMD SCRIPT_HELPERS_FOXGUARD_BLOCK SCRIPT_HELPERS_SECURITY_DIR
# The hooks would download a missing foxguard; tests never do.
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The real foxguard, found before HOME and the cache are replaced below.
real_fox="$(source "$ROOT_DIR/lib/foxguard.sh" >/dev/null 2>&1 && foxguard_bin 2>/dev/null || true)"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

failures=0
note()  { echo "[foxguard_block_test] $*"; }
error() { echo "[foxguard_block_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }
expect() {  # <description> <want rc> <got rc>
  if [[ "$2" == "$3" ]]; then ok "$1"; return 0; fi
  error "$1: want exit $2, got $3"
  sed 's/^/    | /' "$tmp/out" | tail -20 >&2
}
has() {  # <description> <fixed text>
  if grep -qF -- "$2" "$tmp/out"; then ok "$1"; else error "$1: no '$2' in: $(tail -8 "$tmp/out")"; fi
}

# Hermetic: no real config, cache or identity of this machine.
export HOME="$tmp/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
cd "$tmp" || exit 1
gc() { git -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null "$@"; }

# A PATH without foxguard: every other command linked from the real PATH.
mkdir -p "$tmp/nofox"
IFS=: read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [[ "$n" == foxguard* || -e "$tmp/nofox/$n" || ! -x "$f" ]] && continue
    ln -s "$f" "$tmp/nofox/$n" 2>/dev/null || true
  done
done

# Sample code foxguard flags: yaml.load is high, md5 medium.
high_code='import yaml
def load(x):
    return yaml.load(x)'
medium_code='import hashlib
def digest(x):
    return hashlib.md5(x)'

# A repository with an origin it has pushed to and fetched from.
setup() {
  rm -rf "$tmp/remote.git" "$tmp/repo"
  git init -q --bare "$tmp/remote.git"
  git init -q "$tmp/repo"
  gc -C "$tmp/repo" commit -q --allow-empty -m init
  git -C "$tmp/repo" remote add origin "$tmp/remote.git"
}
commit() {  # <file> <content>
  printf '%s\n' "$2" > "$tmp/repo/$1" && gc -C "$tmp/repo" add "$1" && gc -C "$tmp/repo" commit -q -m "change $1"
}
publish() { gc -C "$tmp/repo" push -q origin HEAD:refs/heads/main && git -C "$tmp/repo" fetch -q origin; }
# check [env...]: the foxguard step for HEAD -> main, against origin's main.
# Like scripts/git-hooks/pre-push: set -euo pipefail.
check() {
  local base
  base="$(git -C "$tmp/repo" rev-parse -q --verify refs/remotes/origin/main || echo 0000000000000000000000000000000000000000)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" "$base" > "$tmp/refs"
  (cd "$tmp/repo" && env "$@" bash -c 'set -euo pipefail; source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
  echo $?
}

# ------------------------------------------------------------ the level
level() { (cd "$tmp/repo" && env "$@" bash -c 'source "$1/scripts/security_hooks.sh" && sec_foxguard_level' _ "$ROOT_DIR") 2>"$tmp/out"; }
setup
[[ "$(level)" == high ]] && ok "no setting: high" || error "default level: '$(level)'"
[[ "$(level SCRIPT_HELPERS_FOXGUARD_BLOCK=off)" == off ]] && ok "environment only: off" || error "env off"
git -C "$tmp/repo" config security.foxguardBlock ' Critical '
[[ "$(level)" == critical ]] && ok "git config only, case and spaces ignored: critical" || error "config critical: '$(level)'"
[[ "$(level SCRIPT_HELPERS_FOXGUARD_BLOCK=off)" == critical ]] && ok "environment off cannot weaken git config critical" || error "env weakened config"
[[ "$(level SCRIPT_HELPERS_FOXGUARD_BLOCK=medium)" == medium ]] && ok "environment medium tightens git config critical" || error "env could not tighten"
git -C "$tmp/repo" config security.foxguardBlock off
[[ "$(level SCRIPT_HELPERS_FOXGUARD_BLOCK=high)" == high ]] && ok "git config off, environment high: high" || error "config off env high"
git -C "$tmp/repo" config security.foxguardBlock bogus
level >/dev/null; expect "an unknown git config value is refused" 2 "$?"
has "and named" "git config security.foxguardBlock is 'bogus'"
git -C "$tmp/repo" config --unset security.foxguardBlock
level SCRIPT_HELPERS_FOXGUARD_BLOCK=none >/dev/null; expect "an unknown environment value is refused" 2 "$?"

# ------------------------------------------------- setup-hooks.sh --status
status() { (cd "$tmp/repo" && env "$@" bash "$ROOT_DIR/scripts/setup-hooks.sh" --status --porcelain) 2>/dev/null; }
[[ "$(status)" == *$'\t'"foxguard_block=high" ]] && ok "--status --porcelain: foxguard_block=high by default" || error "porcelain: '$(status)'"
git -C "$tmp/repo" config security.foxguardBlock critical
[[ "$(status SCRIPT_HELPERS_FOXGUARD_BLOCK=off)" == *$'\t'"foxguard_block=critical" ]] && ok "--status --porcelain: the effective level" || error "porcelain effective: '$(status SCRIPT_HELPERS_FOXGUARD_BLOCK=off)'"
git -C "$tmp/repo" config security.foxguardBlock bogus
[[ "$(status)" == *$'\t'"foxguard_block=invalid" ]] && ok "--status --porcelain: invalid" || error "porcelain invalid: '$(status)'"
(cd "$tmp/repo" && bash "$ROOT_DIR/scripts/setup-hooks.sh" --status) >"$tmp/out" 2>&1
has "--status names an invalid level" "foxguard block level: INVALID"
git -C "$tmp/repo" config --unset security.foxguardBlock
(cd "$tmp/repo" && bash "$ROOT_DIR/scripts/setup-hooks.sh" --status) >"$tmp/out" 2>&1
has "--status shows the level" "foxguard block level: high"

# ------------------------------------------------- fail closed, no foxguard
commit app.py "$high_code"
expect "an unknown level refuses the push" 1 "$(check SCRIPT_HELPERS_FOXGUARD_BLOCK=sometimes PATH="$tmp/nofox")"
expect "foxguard missing at the default level: refused" 1 "$(check PATH="$tmp/nofox")"
has "with how to install it" "--install-foxguard"
has "in the local notice style" "Foxguard check failed: foxguard is not installed."
expect "foxguard missing at off: the push goes on" 0 "$(check PATH="$tmp/nofox" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
has "with a warning" "the foxguard scan did NOT run"
# A foxguard whose report the comparison cannot read: refused, never a pass.
cat > "$tmp/oddfox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": [42]}\n' > "$out"; exit 1
EOF
chmod +x "$tmp/oddfox"
expect "an unreadable foxguard report is refused" 1 "$(check FOXGUARD_CMD="$tmp/oddfox")"
has "and says so" "could not be compared"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$tmp/brokenfox"; chmod +x "$tmp/brokenfox"
expect "a failing foxguard at high: refused" 1 "$(check FOXGUARD_CMD="$tmp/brokenfox")"
has "and says so" "the foxguard scan failed"

# --------------------------------- a list that cannot be written fails closed
# sec_foxguard_scan with stand-in scanners: what is tested is what the hook
# does when one of its own writes fails, not what foxguard reports.
# skipfox: every file unparseable. noisefox: a path with a directory is noise,
# then clean from its own directory. stillnoisefox: noise under any name.
# norerunfox: noise, then a rerun that fails without a report.
cat > "$tmp/skipfox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": []}\n' > "$out"; printf 'warning: skipping %s (parse error)\n' "$1" >&2
EOF
cat > "$tmp/noisefox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": []}\n' > "$out"
case "$1" in */*) echo "Skipped 1 file: 1 noise path." >&2 ;; esac
EOF
cat > "$tmp/stillnoisefox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": []}\n' > "$out"; echo "Skipped 1 file: 1 noise path." >&2
EOF
cat > "$tmp/norerunfox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
case "$1" in */*) printf '{"findings": []}\n' > "$out"; echo "Skipped 1 file: 1 noise path." >&2; exit 0 ;; esac
exit 1
EOF
chmod +x "$tmp/skipfox" "$tmp/noisefox" "$tmp/stillnoisefox" "$tmp/norerunfox"
# scan <fox> [<shell code run first, $2 is the work directory>]: the exit
# status of sec_foxguard_scan on vendor/b.py; its lists are $tmp/u/out.*.
scan() {
  rm -rf "$tmp/u"; mkdir -p "$tmp/u/tree/vendor"; printf 'x = 1\n' > "$tmp/u/tree/vendor/b.py"
  printf 'vendor/b.py\n' > "$tmp/u/list"; printf '{}\n' > "$tmp/u/config"
  ln -s "$tmp/$1" "$tmp/u/fox"; printf '%s\n' "${2:-:}" > "$tmp/u/first"
  bash -c 'source "$1/scripts/security_hooks.sh"; source "$2/first"; sec_foxguard_scan "$2/fox" "$2/config" "$2/tree" "$2/out" "$2/list"' \
    _ "$ROOT_DIR" "$tmp/u" >"$tmp/out" 2>&1
  echo $?
}
expect "a skipped file: the scan itself succeeds" 0 "$(scan skipfox)"
[[ "$(cat "$tmp/u/out.skipped" 2>/dev/null)" == "warning: skipping vendor/b.py (parse error)" ]] \
  && ok "and the skip is listed" || error "skip list: '$(cat "$tmp/u/out.skipped" 2>&1)'"
expect "a skip list that cannot be created fails the scan" 1 "$(scan skipfox 'mkdir "$2/out.skipped"')"
expect "a skip line that cannot be written fails the scan" 1 \
  "$(scan skipfox 'printf() { case "${2:-}" in "warning: skipping "*) return 1 ;; esac; builtin printf "$@"; }')"
expect "a file scanned from its own directory: the scan succeeds" 0 "$(scan noisefox)"
[[ "$(cat "$tmp/u/out/1.path" 2>/dev/null)" == vendor/b.py ]] && ok "and its real name is kept" || error "no out/1.path"
expect "a real name that cannot be written fails the scan" 1 "$(scan noisefox 'mkdir -p "$2/out/1.path"')"
expect "a file that is noise under any name: the scan succeeds" 0 "$(scan stillnoisefox)"
[[ "$(cat "$tmp/u/out.skipped" 2>/dev/null)" == "warning: skipping vendor/b.py (noise path)" ]] \
  && ok "and it is listed as skipped" || error "noise skip list: '$(cat "$tmp/u/out.skipped" 2>&1)'"
expect "a noise skip that cannot be written fails the scan" 1 \
  "$(scan stillnoisefox 'printf() { case "$1" in *"(noise path)"*) return 1 ;; esac; builtin printf "$@"; }')"
expect "a rerun that writes no report is not read as the first, empty one" 1 "$(scan norerunfox)"
# sec_foxguard_paths: a file it cannot add to the list would never be scanned.
setup; commit app.py "$high_code"
paths() {  # <shell code run first, $2 is the work directory>
  rm -rf "$tmp/u"; mkdir -p "$tmp/u"; printf '%s\n' "${1:-:}" > "$tmp/u/first"
  (cd "$tmp/repo" && bash -c 'source "$1/scripts/security_hooks.sh"; source "$2/first"; sec_foxguard_paths "" HEAD "$2/files" "$2/map"' \
    _ "$ROOT_DIR" "$tmp/u") >"$tmp/out" 2>&1
  echo $?
}
expect "the changed files are listed" 0 "$(paths)"
[[ "$(cat "$tmp/u/files" 2>/dev/null)" == app.py ]] && ok "by name" || error "files: '$(cat "$tmp/u/files" 2>&1)'"
expect "a file list that cannot be written fails" 1 "$(paths 'mkdir "$2/files"')"
expect "a file map that cannot be written fails" 1 "$(paths 'mkdir "$2/map"')"

# ---------------------------------------------------- with the real foxguard
if [[ -z "$real_fox" ]]; then
  if [[ "${FOXGUARD_REQUIRE:-0}" == 1 ]]; then
    error "foxguard is not installed and FOXGUARD_REQUIRE=1"
  else
    note "SKIP: foxguard is not installed; the finding cases did not run (FOXGUARD_REQUIRE=1 fails instead)"
  fi
else
  note "using $real_fox ($("$real_fox" --version 2>&1 | sed -n 1p))"
  F="FOXGUARD_CMD=$real_fox"

  setup; commit app.py "$high_code"
  expect "a new HIGH finding blocks at the default level" 1 "$(check "$F")"
  has "named as a block" "BLOCK (foxguard): high app.py:3 py/no-yaml-load (new)"
  expect "it passes at critical" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=critical)"
  has "as a warning" "WARNING (foxguard): high app.py:3 py/no-yaml-load (new, below the block level)"

  setup; commit hash.py "$medium_code"
  expect "a new MEDIUM finding passes at high" 0 "$(check "$F")"
  has "with a warning" "WARNING (foxguard): medium hash.py:3"
  expect "and blocks at medium" 1 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=medium)"

  # Pre-existing in a touched file, then moved down by new lines.
  setup; commit app.py "$high_code"; publish
  commit app.py "# a comment
# and another
$high_code"
  expect "a pre-existing finding, moved by new lines, does not block" 0 "$(check "$F")"
  has "it is a warning" "WARNING (foxguard): high app.py:5 py/no-yaml-load (already in the base)"
  commit app.py "$high_code
def again(y):
    return yaml.load(y)"
  expect "a new finding next to a pre-existing one blocks" 1 "$(check "$F")"
  has "only the new one blocks" "BLOCK (foxguard): high app.py:"
  [[ "$(grep -c '^\[pre-push\] BLOCK' "$tmp/out")" == 1 ]] && ok "exactly one block" || error "block count: $(grep -c BLOCK "$tmp/out")"

  # A new branch: its base is where it left what the remote has.
  gc -C "$tmp/repo" reset -q --hard origin/main
  commit app.py "# moved
$high_code"
  printf 'refs/heads/topic %s refs/heads/topic %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" 0000000000000000000000000000000000000000 > "$tmp/refs"
  (cd "$tmp/repo" && env "$F" bash -c 'source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
  expect "a new branch: a finding the remote has does not block" 0 "$?"
  # A bare URL: no tracking refs, so no base: every finding is new.
  (cd "$tmp/repo" && env "$F" bash -c 'source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" "$3"' _ "$ROOT_DIR" "$tmp/refs" "$tmp/remote.git") >"$tmp/out" 2>&1
  expect "no remote information: the same finding blocks (fail-safe)" 1 "$?"

  # The config comes from the base, never from the push being checked.
  quiet_cfg='scan:
  disable_rules:
    - py/no-yaml-load'
  setup; publish; commit .foxguard.yml "$quiet_cfg"; commit app.py "$high_code"
  expect "a push that adds a config disabling the rule still blocks" 1 "$(check "$F")"
  has "and warns that the config is not used yet" "takes effect only after it lands on the remote"
  setup; commit .foxguard.yml "$quiet_cfg"; publish; commit app.py "$high_code"
  expect "a config the remote already has applies" 0 "$(check "$F")"
  grep -q "takes effect only after" "$tmp/out" && error "warned about an unchanged config" || ok "no config warning when it is unchanged"
  commit .foxguard.yml "scan:
  disable_rules:
    - py/no-eval"
  expect "a push that changes that config is checked with the remote's" 0 "$(check "$F")"
  has "and warns" "takes effect only after it lands on the remote"
  # No base (a bare URL): no config at all.
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" 0000000000000000000000000000000000000000 > "$tmp/refs"
  (cd "$tmp/repo" && env "$F" bash -c 'source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" "$3"' _ "$ROOT_DIR" "$tmp/refs" "$tmp/remote.git") >"$tmp/out" 2>&1
  expect "no base: no config, so the finding blocks" 1 "$?"

  # A merge whose resolution adds a finding neither parent has.
  setup; publish
  gc -C "$tmp/repo" checkout -q -b side; commit side.txt "side"
  gc -C "$tmp/repo" checkout -q main; commit main.txt "main"
  gc -C "$tmp/repo" merge -q --no-commit side >/dev/null 2>&1
  printf '%s\n' "$high_code" > "$tmp/repo/merged.py"; gc -C "$tmp/repo" add merged.py; gc -C "$tmp/repo" commit -q -m merge
  expect "a finding added in a merge commit blocks" 1 "$(check "$F")"
  has "it is named" "BLOCK (foxguard): high merged.py:3"
  # Two bases: a merge of two remote branches. side.py's finding is on the
  # remote's side branch, so it is not new, although main never had the file.
  setup; publish
  gc -C "$tmp/repo" checkout -q -b side; commit side.py "$high_code"
  gc -C "$tmp/repo" push -q origin side; git -C "$tmp/repo" fetch -q origin
  gc -C "$tmp/repo" checkout -q main; commit other.txt "other"; publish
  gc -C "$tmp/repo" checkout -q -b topic; gc -C "$tmp/repo" merge -q --no-edit side >/dev/null 2>&1
  printf 'refs/heads/topic %s refs/heads/topic %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" 0000000000000000000000000000000000000000 > "$tmp/refs"
  (cd "$tmp/repo" && env "$F" bash -c 'set -euo pipefail; source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
  expect "a finding one remote branch already has does not block a merge of both" 0 "$?"
  # The same, with the merge's tree equal to side's: nothing changed against
  # that base, so its file list starts empty.
  gc -C "$tmp/repo" checkout -q -B topic2 side; gc -C "$tmp/repo" merge -q --no-edit -s ours main >/dev/null 2>&1
  printf 'refs/heads/topic2 %s refs/heads/topic2 %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" 0000000000000000000000000000000000000000 > "$tmp/refs"
  (cd "$tmp/repo" && env "$F" bash -c 'set -euo pipefail; source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
  expect "a base with no changed files still holds the files" 0 "$?"
  # A symlink replaced by a regular file (a type change).
  setup; ln -s nowhere "$tmp/repo/t.py"; gc -C "$tmp/repo" add t.py; gc -C "$tmp/repo" commit -q -m link; publish
  rm -f "$tmp/repo/t.py"; commit t.py "$high_code"
  expect "a symlink turned into a file with a finding blocks" 1 "$(check "$F")"
  # A renamed file keeps its old findings: not new.
  setup; commit app.py "$high_code"; publish
  gc -C "$tmp/repo" mv app.py renamed.py; gc -C "$tmp/repo" commit -q -m rename
  expect "a renamed file's existing finding does not block" 0 "$(check "$F")"
  has "it is a warning" "WARNING (foxguard): high renamed.py:3 py/no-yaml-load (already in the base)"
  # A pushed .ignore cannot hide the files next to it.
  setup; publish; commit .ignore '*'; commit app.py "$high_code"
  expect "a pushed .ignore does not hide a finding" 1 "$(check "$F")"
  # A directory scan skips hidden paths and the ones foxguard calls noise
  # (vendor/, node_modules/, build/, dist/): each file must still be read.
  for p in .hidden.py .tools/app.py vendor/app.py src/node_modules/x/app.py src/vendor/app.py node_modules/app.py build/app.py dist/app.py; do
    setup; publish; mkdir -p "$tmp/repo/$(dirname "$p")"; commit "$p" "$high_code"
    expect "a new finding in $p blocks" 1 "$(check "$F")"
  done
  # foxguard calls a minified name (x.min.js) noise wherever it sits: it is
  # read under another name, so it neither escapes nor refuses a clean push.
  setup; publish; mkdir -p "$tmp/repo/static"; commit static/app.min.js 'document.body.innerHTML = location.hash;'
  expect "a new finding in static/app.min.js blocks" 1 "$(check "$F")"
  has "under its real name" "static/app.min.js:1"
  setup; publish; commit lib.min.js "var a = 1;"
  expect "a clean lib.min.js passes at high" 0 "$(check "$F")"
  # A skipped copy is named by its real path, so the advice to fix it is usable.
  setup; publish; mkdir -p "$tmp/repo/static"
  awk 'BEGIN { for (i = 0; i < 90000; i++) print "var a" i " = 1;" }' > "$tmp/repo/static/big.min.js"
  gc -C "$tmp/repo" add static/big.min.js; gc -C "$tmp/repo" commit -q -m big
  expect "an oversized big.min.js is refused at high" 1 "$(check "$F")"
  has "under its real name" "foxguard: warning: skipping static/big.min.js ("
  # Such a file keeps its real name, so a finding already at the base is matched.
  setup; mkdir -p "$tmp/repo/vendor"; commit vendor/app.py "$high_code"; publish
  commit vendor/app.py "# touched
$high_code"
  expect "a vendor/ finding already in the base does not block" 0 "$(check "$F")"
  has "under its real name" "WARNING (foxguard): high vendor/app.py:4 py/no-yaml-load (already in the base)"
  # An inline suppression comment in the pushed code cannot hide a new finding.
  setup; publish; commit app.py "import yaml
def load(x):
    return yaml.load(x)  # foxguard: ignore"
  expect "a new finding with an inline foxguard: ignore still blocks" 1 "$(check "$F")"
  setup; publish; commit app.py "import yaml
def load(x):
    # foxguard :ignore
    return yaml.load(x)"
  expect "a new finding under a foxguard:ignore line still blocks" 1 "$(check "$F")"
  # Other spellings: foxguard 0.14.1 honours none, so these guard a later one.
  for marker in "FOXGUARD: ignore" "Foxguard-ignore" "foxguard ignore"; do
    setup; publish; commit app.py "import yaml
def load(x):
    return yaml.load(x)  # $marker"
    expect "a new finding with '# $marker' still blocks" 1 "$(check "$F")"
  done
  # One the remote already suppresses is not new: it only warns.
  setup; commit app.py "import yaml
def load(x):
    return yaml.load(x)  # foxguard: ignore"; publish; commit app.py "# moved
import yaml
def load(x):
    return yaml.load(x)  # foxguard: ignore"
  expect "a suppressed finding already on the remote does not block" 0 "$(check "$F")"
  # A path with a tab cannot be scanned safely: refused.
  setup; publish; printf 'x\n' > "$tmp/repo/a$(printf '\t')b.py"; gc -C "$tmp/repo" add -A; gc -C "$tmp/repo" commit -q -m tab
  expect "a changed path with a tab is refused" 1 "$(check "$F")"
  has "and named" "a path with a tab or newline"
  # A relative TMPDIR still scans.
  setup; commit notes.txt "plain"
  mkdir -p "$tmp/repo/.git/reltmp"
  expect "a relative TMPDIR works" 0 "$(check "$F" TMPDIR=.git/reltmp)"

  # A changed file foxguard cannot parse.
  setup; commit broken.py 'def f(:
    pass'
  expect "a changed file foxguard skips (parse error) blocks at high" 1 "$(check "$F")"
  has "and says which" "skipping broken.py (parse error)"
  if grep -qF "Install the pinned foxguard" "$tmp/out"; then error "a skip must not advise installing foxguard"; else ok "a skip does not advise installing foxguard"; fi
  has "it says how to fix a skip" "so foxguard can read it"
  expect "and only warns at off" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
  # Fixed so foxguard can read it: the base copy was never scanned, so it
  # cannot vouch for what the tip finds there. That blocks unless the
  # operator opts in for the push; a new finding elsewhere blocks anyway.
  setup; commit loader.py "def f(:
    pass
$high_code"; publish
  commit loader.py "$high_code"
  expect "a finding in a file the base could not parse blocks" 1 "$(check "$F")"
  has "it names the reason and the override" "BLOCK (foxguard): high loader.py:3 py/no-yaml-load (the base copy could not be scanned (parse error); review the file, then push with SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "and the base skip is named" "foxguard: base: warning: skipping loader.py (parse error)"
  has "the refusal says how to re-run" "push again with SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1"
  expect "any value but 1 still blocks" 1 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=yes)"
  expect "with the override it passes" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "as a warning that names the override" "WARNING (foxguard): high loader.py:3 py/no-yaml-load (the base copy could not be scanned (parse error); allowed by SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  commit other.py "$high_code"
  expect "with the override, a new finding in another file still blocks" 1 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "the other file blocks" "BLOCK (foxguard): high other.py:3 py/no-yaml-load (new)"
  publish
  commit loader.py "$high_code
def again(y):
    return yaml.load(y)"
  expect "once the readable copy is on the remote, a new finding blocks even with the override" 1 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  # A base copy scanned from its own directory (foxguard calls src/dist/
  # noise) is listed under its real path: the override must not reach the
  # loader.py at the root, whose base copy was read.
  setup; mkdir -p "$tmp/repo/src/dist"; commit src/dist/loader.py "def f(:
    pass
$high_code"; commit loader.py "x = 1"; publish
  commit src/dist/loader.py "$high_code"; commit loader.py "$high_code"
  expect "with the override, a file named like a skipped one in another directory still blocks" 1 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "the base skip carries the real path" "foxguard: base: warning: skipping src/dist/loader.py (parse error)"
  has "the root file blocks as new" "BLOCK (foxguard): high loader.py:3 py/no-yaml-load (new)"
  has "the skipped file is the one allowed" "WARNING (foxguard): high src/dist/loader.py:3 py/no-yaml-load (the base copy could not be scanned (parse error); allowed by SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  # Two bases, both with the unparseable copy. Every base skipped it, so the
  # override applies; when the scan of one base fails, that base skipped
  # nothing and the override must not.
  setup; commit loader.py "def f(:
    pass
$high_code"; publish
  gc -C "$tmp/repo" checkout -q -b side; commit side.txt "side"
  gc -C "$tmp/repo" push -q origin side; git -C "$tmp/repo" fetch -q origin
  gc -C "$tmp/repo" checkout -q main; commit other.txt "other"; publish
  gc -C "$tmp/repo" checkout -q -b topic; gc -C "$tmp/repo" merge -q --no-edit side >/dev/null 2>&1
  commit loader.py "$high_code"
  topic_check() {  # [env...]
    printf 'refs/heads/topic %s refs/heads/topic %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" 0000000000000000000000000000000000000000 > "$tmp/refs"
    (cd "$tmp/repo" && env "$@" bash -c 'set -euo pipefail; source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
    echo $?
  }
  expect "two bases that both skipped the file: the override passes" 0 "$(topic_check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  printf '#!/usr/bin/env bash\ncase "$PWD" in */base2) exit 2 ;; esac\nexec "%s" "$@"\n' "$real_fox" > "$tmp/base2fox"; chmod +x "$tmp/base2fox"
  expect "the scan of one base fails: the override does not apply" 1 "$(topic_check FOXGUARD_CMD="$tmp/base2fox" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "the failed base is named" "failed; its findings count as new."
  has "the block says why the override does not apply" "BLOCK (foxguard): high loader.py:3 py/no-yaml-load (the base copy could not be scanned (parse error); another base was not scanned, so SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1 does not apply)"
  if grep -qF "push again with SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1" "$tmp/out"; then error "a block the override cannot lift must not advise it"; else ok "it does not advise the override"; fi
  # Over 8 bases: the ninth is never scanned, so it skipped nothing either.
  setup; commit loader.py "def f(:
    pass
$high_code"; publish
  for n in 1 2 3 4 5 6 7 8 9; do
    gc -C "$tmp/repo" checkout -q -b "b$n" origin/main; commit "b$n.txt" "$n"; gc -C "$tmp/repo" push -q origin "b$n"
  done
  git -C "$tmp/repo" fetch -q origin
  gc -C "$tmp/repo" checkout -q -b topic b1; gc -C "$tmp/repo" merge -q --no-edit b2 b3 b4 b5 b6 b7 b8 b9 >/dev/null 2>&1
  commit loader.py "$high_code"
  expect "nine bases, eight scanned: the override does not apply" 1 "$(topic_check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "the block says a base was not scanned" "another base was not scanned, so SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1 does not apply"
  # Two bases: main has the unparseable copy, side was cut before the file
  # existed. The base without the file read nothing and skipped nothing, so
  # the override applies; without it the finding blocks and names it.
  setup; commit seed.txt "seed"; publish
  gc -C "$tmp/repo" checkout -q -b side; commit side.txt "side"
  gc -C "$tmp/repo" push -q origin side; git -C "$tmp/repo" fetch -q origin
  gc -C "$tmp/repo" checkout -q main; commit loader.py "def f(:
    pass
$high_code"; publish
  gc -C "$tmp/repo" checkout -q -b topic; gc -C "$tmp/repo" merge -q --no-edit side >/dev/null 2>&1
  commit loader.py "$high_code"
  expect "skipped by one base, absent from the other: it blocks" 1 "$(topic_check "$F")"
  has "and the block names the override" "BLOCK (foxguard): high loader.py:3 py/no-yaml-load (the base copy could not be scanned (parse error); review the file, then push with SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  expect "skipped by one base, absent from the other: the override passes" 0 "$(topic_check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "as a warning that names the override" "WARNING (foxguard): high loader.py:3 py/no-yaml-load (the base copy could not be scanned (parse error); allowed by SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  commit fresh.py "$high_code"
  expect "with the override, a file no base has still blocks" 1 "$(topic_check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "it blocks as new" "BLOCK (foxguard): high fresh.py:3 py/no-yaml-load (new)"
  # The other base has a copy it read, with nothing in it: it still judges
  # the file, so the override does not apply.
  setup; commit seed.txt "seed"; publish
  gc -C "$tmp/repo" checkout -q -b side; commit loader.py "x = 1"
  gc -C "$tmp/repo" push -q origin side; git -C "$tmp/repo" fetch -q origin
  gc -C "$tmp/repo" checkout -q main; commit loader.py "def f(:
    pass
$high_code"; publish
  gc -C "$tmp/repo" checkout -q -b topic; gc -C "$tmp/repo" merge -q --no-edit -s ours side >/dev/null 2>&1
  commit loader.py "$high_code"
  expect "skipped by one base, read by the other: the override does not apply" 1 "$(topic_check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "it blocks as new" "BLOCK (foxguard): high loader.py:3 py/no-yaml-load (new)"
  # A file name that is pathspec magic to git (":(top)x.py", ":!x.py") is a
  # file like any other: it is scanned, and its finding blocks.
  for magic in ':(top)evil.py' ':!evil.py'; do
    setup; commit notes.txt "plain text"; publish
    printf '%s\n' "$high_code" > "$tmp/repo/$magic"
    gc -C "$tmp/repo" --literal-pathspecs add -- "$magic"; gc -C "$tmp/repo" commit -q -m "add $magic"
    expect "a new finding in a file named $magic blocks" 1 "$(check "$F")"
    has "under its own name" "BLOCK (foxguard): high $magic:3 py/no-yaml-load (new)"
  done
  # A directory whose name starts with a dash is a directory, also when the
  # file is scanned from inside it (vendor/ is a noise path).
  for dashed in '-z/app.py' '-z/vendor/y.py'; do
    setup; commit notes.txt "plain text"; publish
    mkdir -p "$tmp/repo/${dashed%/*}"; printf '%s\n' "$high_code" > "$tmp/repo/$dashed"
    gc -C "$tmp/repo" add -- "$dashed"; gc -C "$tmp/repo" commit -q -m "add $dashed"
    expect "a new finding in $dashed blocks" 1 "$(check "$F")"
    has "as a finding, not an unreadable file" "BLOCK (foxguard): high $dashed:3 py/no-yaml-load (new)"
  done
  # Its unparseable base copy is skipped under that name too.
  setup; printf 'def f(:\n    pass\n%s\n' "$high_code" > "$tmp/repo/:(top)evil.py"
  gc -C "$tmp/repo" --literal-pathspecs add -- ':(top)evil.py'; gc -C "$tmp/repo" commit -q -m "add"; publish
  printf '%s\n' "$high_code" > "$tmp/repo/:(top)evil.py"
  gc -C "$tmp/repo" --literal-pathspecs add -- ':(top)evil.py'; gc -C "$tmp/repo" commit -q -m "fix"
  expect "a magic-named file the base could not parse passes with the override" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  has "and is named" "WARNING (foxguard): high :(top)evil.py:3 py/no-yaml-load (the base copy could not be scanned (parse error); allowed by"
  # A parse error in a file with "noise path" in its name is one skip, not a
  # noise path as well.
  setup; commit "noise path.py" "def f(:
    pass"
  expect "an unparseable file named 'noise path.py' is refused" 1 "$(check "$F")"
  has "as one skipped file" "foxguard skipped 1 changed file(s)"
  if grep -qF "(noise path)" "$tmp/out"; then error "a parse error must not be listed as a noise path too"; else ok "it is not listed as a noise path"; fi
  # A carriage return in the name of a skipped file is not sent to the
  # terminal, where it would draw the name over the start of its line.
  setup; printf 'def f(:\n    pass\n' > "$tmp/repo/$(printf 'a\rb.py')"; gc -C "$tmp/repo" add -A; gc -C "$tmp/repo" commit -q -m cr
  expect "an unparseable file with a carriage return in its name is refused" 1 "$(check "$F")"
  has "named with the carriage return replaced" "foxguard: warning: skipping a?b.py (parse error)"
  if LC_ALL=C grep -q "$(printf '\r')" "$tmp/out"; then error "a carriage return reaches the terminal"; else ok "no carriage return is printed"; fi
  # A file of no language foxguard reads is not a skip.
  setup; commit notes.txt "plain text"
  expect "an unsupported file type passes at high" 0 "$(check "$F")"
  # A symlink's blob is its target path, not code: not scanned, so not a skip.
  ln -s ../elsewhere/target.py "$tmp/repo/link.py"; gc -C "$tmp/repo" add link.py; gc -C "$tmp/repo" commit -q -m link
  expect "a committed symlink named .py passes at high" 0 "$(check "$F")"

  # The hook's own working files. A write that fails must refuse the push:
  # an empty list reads as "nothing to scan" or "nothing skipped". Each
  # stand-in is a shell function the hook inherits in place of the tool.
  setup; publish; commit app.py "$high_code"
  expect "a map of the pushed files that comes out empty refuses the push" 1 \
    "$(awk() { case "$*" in *'print $0 "\t" $0'*) return 0 ;; esac; command awk "$@"; }; export -f awk; check "$F")"
  has "and says so" "the list of pushed files could not be written"
  expect "a file list that cannot be sorted refuses the push" 1 \
    "$(sort() { case "$*" in *" -o "*) return 1 ;; esac; command sort "$@"; }; export -f sort; check "$F")"
  has "and says so" "the list of changed files could not be sorted"
  has "with a remedy that is not installing foxguard" "is writable and has free space"
  expect "a base list that cannot be written refuses the push" 1 \
    "$(sed() { case "$*" in *"1,8p"*) return 4 ;; esac; command sed "$@"; }; export -f sed; check "$F")"
  has "and says so" "the base commits of refs/heads/main could not be listed"
  setup; publish; commit broken.py 'def f(:
    pass'
  expect "a skip of a pushed file that cannot be listed refuses the push" 1 \
    "$(printf() { case "${2:-}" in "warning: skipping "*) return 1 ;; esac; builtin printf "$@"; }; export -f printf; check "$F")"
  has "as a failed scan" "the foxguard scan failed"
  setup; commit .foxguard.yml "$quiet_cfg"; publish; commit app.py "$high_code"
  expect "a base config that cannot be read refuses the push" 1 \
    "$(git() { case "$*" in "cat-file blob "*":.foxguard.yml") return 1 ;; esac; command git "$@"; }; export -f git; check "$F")"
  has "and says so" "the foxguard config of the base could not be read"

  # Through the hook's own sequence: the refusal reaches _sec_pre_push.
  setup; commit app.py "$high_code"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" 0000000000000000000000000000000000000000 > "$tmp/refs"
  (cd "$tmp/repo" && env "$F" bash -c 'source "$1/scripts/security_hooks.sh"
    sec_scan_output() { return 0; }; sec_private_names() { return 0; }; sec_sensitive_push() { return 0; }
    _sec_pre_push "$2" origin x' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
  expect "_sec_pre_push returns the foxguard refusal" 1 "$?"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "[foxguard_block_test] $failures failure(s)" >&2
  exit 1
fi
note "all passed"
