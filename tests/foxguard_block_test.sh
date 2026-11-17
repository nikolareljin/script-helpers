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
check() {
  local base
  base="$(git -C "$tmp/repo" rev-parse -q --verify refs/remotes/origin/main || echo 0000000000000000000000000000000000000000)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$tmp/repo" rev-parse HEAD)" "$base" > "$tmp/refs"
  (cd "$tmp/repo" && env "$@" bash -c 'source "$1/scripts/security_hooks.sh" && sec_foxguard_push "$2" origin' _ "$ROOT_DIR" "$tmp/refs") >"$tmp/out" 2>&1
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
printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$tmp/brokenfox"; chmod +x "$tmp/brokenfox"
expect "a failing foxguard at high: refused" 1 "$(check FOXGUARD_CMD="$tmp/brokenfox")"
has "and says so" "the foxguard scan failed"

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

  # A changed file foxguard cannot parse.
  setup; commit broken.py 'def f(:
    pass'
  expect "a changed file foxguard skips (parse error) blocks at high" 1 "$(check "$F")"
  has "and says which" "skipping ./broken.py (parse error)"
  expect "and only warns at off" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
  # A file of no language foxguard reads is not a skip.
  setup; commit notes.txt "plain text"
  expect "an unsupported file type passes at high" 0 "$(check "$F")"
  # A symlink's blob is its target path, not code: not scanned, so not a skip.
  ln -s ../elsewhere/target.py "$tmp/repo/link.py"; gc -C "$tmp/repo" add link.py; gc -C "$tmp/repo" commit -q -m link
  expect "a committed symlink named .py passes at high" 0 "$(check "$F")"

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
