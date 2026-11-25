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
# skipfox: every file unparseable. noisefox: a file below vendor/ is noise,
# and clean as a copy below d_vendor/. stillnoisefox: noise under any name.
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
case "$1" in vendor/*) echo "Skipped 1 file: 1 noise path." >&2 ;; esac
EOF
cat > "$tmp/stillnoisefox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": []}\n' > "$out"; echo "Skipped 1 file: 1 noise path." >&2
EOF
cat > "$tmp/norerunfox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
case "$1" in vendor/*) printf '{"findings": []}\n' > "$out"; echo "Skipped 1 file: 1 noise path." >&2; exit 0 ;; esac
exit 1
EOF
# cxxfox: knows .c, not .C, and what it is given does not parse as C.
# pathfox: a/build/ is noise, and a .conf is read only below a directory.
cat > "$tmp/cxxfox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": []}\n' > "$out"
case "$1" in
  *.c) printf 'warning: skipping %s (parse error)\nSkipped 1 file: 1 parse error.\n' "$1" >&2 ;;
  *) echo "Skipped 1 file: 1 unsupported extension." >&2 ;;
esac
EOF
cat > "$tmp/pathfox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": []}\n' > "$out"
case "$1" in
  */build/*) echo "Skipped 1 file: 1 noise path." >&2 ;;
  */*) printf '{"findings": [{"rule_id": "r", "file": "%s"}]}\n' "$1" > "$out"; exit 1 ;;
  *) echo "Skipped 1 file: 1 unsupported extension." >&2 ;;
esac
EOF
# namefox: as foxguard, a .conf is read only with nginx in its name, another
# is an unsupported extension, and a name with .min. in it is noise.
# lostfox: the file is noise where it is, and no copy of it is read.
cat > "$tmp/namefox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": []}\n' > "$out"
case "${1##*/}" in
  *nginx*.min.*.conf|*nginx*.min.conf) echo "Skipped 1 file: 1 noise path." >&2 ;;
  *nginx*.conf) printf '{"findings": [{"rule_id": "r", "file": "%s"}]}\n' "$1" > "$out"; exit 1 ;;
  *) echo "Skipped 1 file: 1 unsupported extension." >&2 ;;
esac
EOF
cat > "$tmp/lostfox" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do [[ "$1" == --output ]] && out="$2"; shift; done
printf '{"findings": []}\n' > "$out"
case "$1" in
  vendor/b.py) echo "Skipped 1 file: 1 noise path." >&2 ;;
  *) echo "Skipped 1 file: 1 unsupported extension." >&2 ;;
esac
EOF
chmod +x "$tmp/skipfox" "$tmp/noisefox" "$tmp/stillnoisefox" "$tmp/norerunfox" "$tmp/cxxfox" "$tmp/pathfox" "$tmp/namefox" "$tmp/lostfox"
# scan <fox> [<shell code run first, $2 is the work directory>] [<file>]: the
# exit status of sec_foxguard_scan on <file> (vendor/b.py); its lists are
# $tmp/u/out.*.
scan() {
  local f="${3:-vendor/b.py}"
  rm -rf "$tmp/u"; mkdir -p "$tmp/u/tree/$(dirname "$f")"; printf 'x = 1\n' > "$tmp/u/tree/$f"
  printf '%s\n' "$f" > "$tmp/u/list"; printf '{}\n' > "$tmp/u/config"
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
expect "a file in a noise path, scanned as a copy: the scan succeeds" 0 "$(scan noisefox)"
[[ -e "$tmp/u/out.skipped" && ! -s "$tmp/u/out.skipped" ]] && ok "and it is not a skip" || error "skip list: '$(cat "$tmp/u/out.skipped" 2>&1)'"
[[ "$(cat "$tmp/u/out/1.path" 2>/dev/null)" == vendor/b.py ]] && ok "and its real name is kept" || error "no out/1.path"
expect "a real name that cannot be written fails the scan" 1 "$(scan noisefox 'mkdir -p "$2/out/1.path"')"
expect "a copy that cannot be written fails the scan" 1 "$(scan noisefox 'mkdir -p "$2/out/1.d/d_vendor/b.py"')"
expect "a file that is noise under any name: the scan succeeds" 0 "$(scan stillnoisefox)"
[[ "$(cat "$tmp/u/out.skipped" 2>/dev/null)" == "warning: skipping vendor/b.py (noise path)" ]] \
  && ok "and it is listed as skipped" || error "noise skip list: '$(cat "$tmp/u/out.skipped" 2>&1)'"
expect "a noise skip that cannot be written fails the scan" 1 \
  "$(scan stillnoisefox 'printf() { case "$1" in *"(noise path)"*) return 1 ;; esac; builtin printf "$@"; }')"
expect "a rerun that writes no report is not read as the first, empty one" 1 "$(scan norerunfox)"
# A .C that does not parse as C is C++: on its own list, not a skip.
expect "a .C that is not C: the scan succeeds" 0 "$(scan cxxfox : src/b.C)"
[[ "$(cat "$tmp/u/out.cxx" 2>/dev/null)" == "warning: skipping src/b.C (parse error)" ]] \
  && ok "and it is listed as C++, under its own name" || error "C++ list: '$(cat "$tmp/u/out.cxx" 2>&1)'"
[[ -e "$tmp/u/out.skipped" && ! -s "$tmp/u/out.skipped" ]] && ok "and not as a skip" || error "skip list: '$(cat "$tmp/u/out.skipped" 2>&1)'"
expect "a C++ list that cannot be created fails the scan" 1 "$(scan cxxfox 'mkdir "$2/out.cxx"' src/b.C)"
expect "a C++ line that cannot be written fails the scan" 1 \
  "$(scan cxxfox 'printf() { case "${2:-}" in "warning: skipping "*) return 1 ;; esac; builtin printf "$@"; }' src/b.C)"
# A file told by its path, in a noise path: its own directory alone would
# leave it unread, and nothing would say so.
expect "a file foxguard tells by its path, in a noise path: the scan succeeds" 0 "$(scan pathfox : nginx/build/site.conf)"
grep -q '"rule_id": "r"' "$tmp/u/out/1.json" 2>/dev/null && ok "and it is read with its directories" || error "report: '$(cat "$tmp/u/out/1.json" 2>&1)'"
[[ "$(cat "$tmp/u/out/1.path" 2>/dev/null)" == nginx/build/site.conf ]] && ok "under its real name" || error "no out/1.path"
# A file told by its name, with a noise name: a copy named <n>.conf would be
# an unsupported extension, and nothing would say so.
expect "a file foxguard tells by its name, with a noise name: the scan succeeds" 0 "$(scan namefox : nginx.min.conf)"
grep -q '"rule_id": "r"' "$tmp/u/out/1.json" 2>/dev/null && ok "and it is read under a name that keeps what tells it" || error "report: '$(cat "$tmp/u/out/1.json" 2>&1)'"
[[ "$(cat "$tmp/u/out/1.path" 2>/dev/null)" == nginx.min.conf ]] && ok "under its real name" || error "no out/1.path"
# foxguard says "noise" only of a file type it knows: when no copy is read,
# whatever the last one was left out for, the file is a skip.
expect "a file that is noise, and unsupported as every copy: the scan succeeds" 0 "$(scan lostfox)"
[[ "$(cat "$tmp/u/out.skipped" 2>/dev/null)" == "warning: skipping vendor/b.py (noise path)" ]] \
  && ok "and it is listed as skipped" || error "lost skip list: '$(cat "$tmp/u/out.skipped" 2>&1)'"
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
# sec_foxguard_tree: a copy that is not the whole file would be scanned in
# its place, and two names that land on one file leave one of them unscanned.
commit other.py "x = 1"
tree() {  # <map, printf %b> [<shell code run first>]: its exit status; the tree is $tmp/u/tree
  rm -rf "$tmp/u"; mkdir -p "$tmp/u"; printf '%b' "$1" > "$tmp/u/map"; printf '%s\n' "${2:-:}" > "$tmp/u/first"
  (cd "$tmp/repo" && bash -c 'source "$1/scripts/security_hooks.sh"; source "$2/first"; rc=0
    sec_foxguard_tree HEAD "$2/map" "$2/tree" || rc=$?; printf "%s\n" "${SEC_FOXGUARD_CLASH:-}" > "$2/clash"; exit "$rc"' \
    _ "$ROOT_DIR" "$tmp/u") >"$tmp/out" 2>&1
  echo $?
}
expect "the files of a commit are written" 0 "$(tree 'app.py\tapp.py\nother.py\tother.py\n')"
cmp -s "$tmp/repo/app.py" "$tmp/u/tree/app.py" && ok "each whole" || error "tree/app.py is not the committed file"
# A sed that loses its output when it writes to a file, and says nothing.
expect "a copy that comes out short fails" 1 \
  "$(tree 'app.py\tapp.py\n' 'sed() { if [[ "$*" == *f0xguard* && ! -p /dev/stdout ]]; then command sed "$@" >/dev/null; printf short; return 0; fi; command sed "$@"; }')"
# What a case-insensitive file system does to App.py and app.py, on any
# file system: the second name is the first file.
expect "two names that are one file in the tree are refused" 2 "$(tree 'app.py\tsame.py\nother.py\tsame.py\n')"
[[ "$(cat "$tmp/u/clash" 2>/dev/null)" == same.py ]] && ok "and the name is kept for the message" || error "clash: '$(cat "$tmp/u/clash" 2>&1)'"
cmp -s "$tmp/repo/app.py" "$tmp/u/tree/same.py" && ok "the first file is not replaced" || error "tree/same.py is not the first file"
# The same clash one level up: A and a/x.py, where A is already a file.
expect "a file where a directory of the next name must be is refused too" 2 "$(tree 'app.py\tsame\nother.py\tsame/d/x.py\n')"
[[ "$(cat "$tmp/u/clash" 2>/dev/null)" == same/d/x.py ]] && ok "and the name is kept for the message" || error "clash: '$(cat "$tmp/u/clash" 2>&1)'"
# Through the hook: the refusal names the file and the remedy. A map that
# gives both pushed files one name stands in for the file system.
setup; publish; commit app.py "$high_code"; commit other.py "x = 1"
# An awk first on PATH, not an exported function: the bash that runs the hook
# may be another version than this one, and would not import it.
mkdir -p "$tmp/oneawk"
cat > "$tmp/oneawk/awk" <<EOF
#!/usr/bin/env bash
case "\$1" in *'print \$0 "\\t" \$0'*) shift; exec "$(command -v awk)" '{ print \$0 "\\tsame.py" }' "\$@" ;; esac
exec "$(command -v awk)" "\$@"
EOF
chmod +x "$tmp/oneawk/awk"
expect "two pushed names that are one file refuse the push" 1 "$(check FOXGUARD_CMD="$tmp/oddfox" PATH="$tmp/oneawk:$PATH")"
has "and says why" "two paths that are one file under"
has "the second name is given" "foxguard: same file here: same.py"
has "the remedy is to rename one" "Rename one of them, or point TMPDIR at a case-sensitive file system"
if grep -qF "Install the pinned foxguard" "$tmp/out"; then error "a name clash must not advise installing foxguard"; else ok "it does not advise installing foxguard"; fi
# sec_foxguard_show: what a printed name may not carry to the terminal, as
# bytes, with the sed and tr of this machine.
shown="$(printf 'a\302\233b\342\200\256c\342\201\246d caf\303\251\rz\033[2K\n' \
  | bash -c 'source "$1/scripts/security_hooks.sh"; sec_foxguard_show "p: "' _ "$ROOT_DIR" 2>&1)"
[[ "$shown" == "p: a?b?c?d caf$(printf '\303\251')?z?[2K" ]] && ok "a printed name loses its control characters, C1 controls and reordering characters, and keeps its letters" \
  || error "sec_foxguard_show printed: $(printf '%s' "$shown" | cat -v)"
# sec_foxguard_script_ext: the language of a script, from its first line.
# "-" stands for none: a file that is no script, or one in a language
# foxguard has no rules for.
mkdir -p "$tmp/sx"
while IFS='|' read -r first want; do
  printf '%b\n' "$first" 'eval "$1"' > "$tmp/sx/-s"
  got="$(cd "$tmp/sx" && bash -c 'source "$1/scripts/security_hooks.sh"; sec_foxguard_script_ext -s' _ "$ROOT_DIR" 2>&1)"
  [[ "${got:--}" == "$want" ]] && ok "a script that starts with '$first' is read as: $want" \
    || error "a script that starts with '$first': want $want, got '${got:--}'"
done <<'EOF'
#!/bin/sh|sh
#!/usr/bin/env bash|sh
#! /bin/bash -eu|sh
#!/bin/dash|sh
#!/usr/bin/env -S python3 -u|py
#!/usr/bin/env -i PATH=/usr/bin python|py
#!/usr/bin/env -u PYTHONPATH -C /srv python3|py
#!/usr/bin/env --unset=X --chdir=/srv ruby|rb
#!/bin/bash -u|sh
#!/usr/bin/python3.12|py
#!/usr/bin/env pypy3|py
#!/usr/bin/env ruby|rb
#!/usr/bin/env node|js
#!/usr/bin/nodejs|js
#!/usr/bin/php8.3|php
#!/usr/bin/env bash\r|sh
#!/bin/zsh|-
#!/usr/bin/perl -w|-
#!/usr/bin/env|-
#!|-
# !/bin/sh|-
echo #!/bin/sh|-
\0#!/bin/sh|-
|-
EOF
# A path that is not UTF-8: foxguard takes no such argument. Refused before
# any scan, with the path and a remedy that is not installing foxguard.
setup; publish
blob="$(printf '%s\n' "$high_code" | git -C "$tmp/repo" hash-object -w --stdin)"
gc -C "$tmp/repo" -c core.precomposeunicode=false update-index --add --cacheinfo "100644,$blob,$(printf 'a\377b.py')"
gc -C "$tmp/repo" commit -q -m "a name that is not UTF-8"
expect "a changed path that is not UTF-8 is refused" 1 "$(check FOXGUARD_CMD="$tmp/oddfox")"
has "and says why" "changes a path whose name is not valid UTF-8"
has "the path is named, its odd byte escaped" 'foxguard: not UTF-8: a\xffb.py'
has "the remedy is to rename it" "Rename each file named above"
if grep -qF "Install the pinned foxguard" "$tmp/out"; then error "a name that is not UTF-8 must not advise installing foxguard"; else ok "it does not advise installing foxguard"; fi

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
  # The directories of a copy get "d_" in front. "_" would make the noise
  # path __tests__ of _tests__, and refuse the file as one foxguard skipped.
  setup; publish; mkdir -p "$tmp/repo/src/_tests__/build"; commit src/_tests__/build/app.py "$high_code"; commit src/_tests__/Loader.PY "$high_code"
  expect "a new finding below _tests__, in a file scanned as a copy, blocks" 1 "$(check "$F")"
  has "as a finding, not as a skipped file" "BLOCK (foxguard): high src/_tests__/build/app.py:3 py/no-yaml-load (new)"
  has "with an upper-case extension too" "BLOCK (foxguard): high src/_tests__/Loader.PY:3 py/no-yaml-load (new)"
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
  # Nor is the UTF-8 form of a C1 control (U+009B starts an escape sequence
  # on some terminals) or of a character that reorders the text (U+202E).
  setup; printf 'def f(:\n    pass\n' > "$tmp/repo/$(printf 'c\302\233d\342\200\256e.py')"; gc -C "$tmp/repo" add -A; gc -C "$tmp/repo" commit -q -m c1
  expect "an unparseable file with U+009B and U+202E in its name is refused" 1 "$(check "$F")"
  has "named with both replaced" "foxguard: warning: skipping c?d?e.py (parse error)"
  # A name that is not UTF-8 at the base only (the push renames it) is no
  # reason to refuse: the old name is never handed to foxguard.
  setup
  blob="$(printf '%s\n' "$high_code" | git -C "$tmp/repo" hash-object -w --stdin)"
  gc -C "$tmp/repo" -c core.precomposeunicode=false update-index --add --cacheinfo "100644,$blob,$(printf 'a\377b.py')"
  gc -C "$tmp/repo" commit -q -m "a name that is not UTF-8"; publish
  gc -C "$tmp/repo" -c core.precomposeunicode=false update-index --force-remove "$(printf 'a\377b.py')"
  gc -C "$tmp/repo" update-index --add --cacheinfo "100644,$blob,renamed.py"; gc -C "$tmp/repo" commit -q -m "rename it"
  expect "a push that renames a file whose old name is not UTF-8 passes" 0 "$(check "$F")"
  has "its finding is the old one" "WARNING (foxguard): high renamed.py:3 py/no-yaml-load (already in the base)"
  # Two pushed names that differ only in case. Where they are two files, both
  # are scanned; where they are one (macOS, Windows), the push is refused:
  # one of them could not be scanned.
  setup; publish
  blob="$(printf '%s\n' "$high_code" | git -C "$tmp/repo" hash-object -w --stdin)"
  gc -C "$tmp/repo" -c core.ignorecase=false update-index --add --cacheinfo "100644,$blob,Case.py" --cacheinfo "100644,$blob,case.py"
  gc -C "$tmp/repo" -c core.ignorecase=false commit -q -m "two names, one case apart"
  [[ "$(git -C "$tmp/repo" ls-tree --name-only HEAD | grep -ci '^case\.py$')" == 2 ]] || error "the commit does not hold Case.py and case.py"
  : > "$tmp/CaseProbe"
  if [[ -e "$tmp/caseprobe" ]]; then
    expect "two names one case apart, on a case-insensitive file system: refused" 1 "$(check "$F")"
    has "and says why" "two paths that are one file under"
    has "the second name is given" "foxguard: same file here: case.py"
    if grep -qF "Install the pinned foxguard" "$tmp/out"; then error "a name clash must not advise installing foxguard"; else ok "it does not advise installing foxguard"; fi
  else
    expect "two names one case apart, on a case-sensitive file system: both findings block" 1 "$(check "$F")"
    has "the first is scanned" "BLOCK (foxguard): high Case.py:3 py/no-yaml-load (new)"
    has "and the second" "BLOCK (foxguard): high case.py:3 py/no-yaml-load (new)"
  fi
  # An extension foxguard knows in lower case only (it reads app.py, not
  # app.PY): the file runs all the same, so it is scanned, under its own name.
  setup; publish; commit Loader.PY "$high_code"; mkdir -p "$tmp/repo/vendor"; commit vendor/Mod.Py "$medium_code"
  expect "a new finding in a file with an upper-case extension blocks" 1 "$(check "$F")"
  has "under its own name" "BLOCK (foxguard): high Loader.PY:3 py/no-yaml-load (new)"
  has "one in a noise path too" "WARNING (foxguard): medium vendor/Mod.Py:3 py/no-weak-crypto (new, below the block level)"
  setup; commit Loader.PY "$high_code"; publish; commit Loader.PY "# moved
$high_code"
  expect "one the base already has only warns" 0 "$(check "$F")"
  has "as already in the base" "WARNING (foxguard): high Loader.PY:4 py/no-yaml-load (already in the base)"
  setup; publish; commit Broken.Py 'def f(:
    pass'
  expect "an unparseable file with an upper-case extension is a skip" 1 "$(check "$F")"
  has "named as it is" "foxguard: warning: skipping Broken.Py (parse error)"
  # .C and .H are C++ to a compiler, which foxguard has no rules for: as .c
  # and .h they would be parse errors, and refuse every push of C++.
  setup; publish; commit Tmpl.C 'template <class T> class A { public: T v; A() : v() {} };
namespace n { int f() { return 1; } }'; commit Tmpl.H 'namespace n { template <class T> class B { public: T v; }; }'; commit NOTES.TXT "plain text"
  expect "C++ named .C and .H, and a file type foxguard does not read in any case, pass" 0 "$(check "$F")"
  has "the C++ is named as not scanned" "foxguard: not scanned: warning: skipping Tmpl.C (parse error)"
  has "the header too" "foxguard: not scanned: warning: skipping Tmpl.H (parse error)"
  has "and counted" "2 .C or .H file(s) above do not parse as C and were not scanned"
  if grep -qF "NOTES.TXT" "$tmp/out"; then error "a file type foxguard does not read was named"; else ok "the text file is not named"; fi
  # C named .C is scanned as C: a finding there is not a silent pass.
  c_code='#include <stdlib.h>
int main(int argc, char **argv) { system(argv[1]); return 0; }'
  setup; publish; commit Util.C "$c_code"
  expect "a new finding in C code named .C blocks" 1 "$(check "$F")"
  has "under its own name" "Util.C:2 c/taint-command-injection (new)"
  # The base copy was C++, so never read: it vouches for nothing.
  setup; commit Util.C 'template <class T> class A { public: T v; A() : v() {} };'; publish; commit Util.C "$c_code"
  expect "a finding in a .C whose base copy was C++ blocks" 1 "$(check "$F")"
  has "as unscanned at the base" "Util.C:2 c/taint-command-injection (the base copy could not be scanned (parse error); review the file, then push with SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  expect "and is a warning with the override" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  # The same for a base copy with an upper-case extension that did not parse:
  # scanned as .py, skipped, and so no clean base.
  setup; commit Loader.PY 'def f(:
    pass'; publish; commit Loader.PY "$high_code"
  expect "a finding in a file whose upper-case base copy did not parse blocks" 1 "$(check "$F")"
  has "as unscanned at the base" "high Loader.PY:3 py/no-yaml-load (the base copy could not be scanned (parse error); review the file"
  has "the base skip is named" "foxguard: base: warning: skipping Loader.PY (parse error)"
  expect "and is a warning with the override" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1)"
  # foxguard tells an nginx config by its path. In a noise path it is scanned
  # from a copy, which must keep the directories.
  setup; publish; mkdir -p "$tmp/repo/deploy/nginx/build"; commit deploy/nginx/build/site.conf 'server { ssl_protocols SSLv3 TLSv1; }'
  expect "a finding in a file told by its path, in a noise path, blocks" 1 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=medium)"
  has "under its own name" "BLOCK (foxguard): medium deploy/nginx/build/site.conf:1 config/nginx-pq-vulnerable-tls (new)"
  # foxguard tells some files by their name (nginx.conf, Dockerfile.dev,
  # haproxy.cfg). With a noise name a copy named <n>.conf would be an
  # unsupported extension, and the finding would pass without a word.
  for p in nginx.min.conf deploy/my-nginx.min.conf deploy/nginx/site.min.conf; do
    setup; publish; mkdir -p "$tmp/repo/$(dirname "$p")"; commit "$p" 'server { ssl_protocols SSLv3 TLSv1; }'
    expect "a finding in $p blocks" 1 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=medium)"
    has "under its own name" "BLOCK (foxguard): medium $p:1 config/nginx-pq-vulnerable-tls (new)"
    expect "at off: the push goes on" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
    has "and the finding is shown" "config/nginx-pq-vulnerable-tls"
  done
  # The directories decide which config it is: from its own directory alone
  # nginx/build/apache.conf would be read as an Apache config, and found clean.
  setup; publish; mkdir -p "$tmp/repo/deploy/nginx/build"; commit deploy/nginx/build/apache.conf 'server { ssl_protocols SSLv3 TLSv1; }'
  expect "an nginx config named apache.conf, in a noise path, is read as nginx" 1 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=medium)"
  has "under its own name" "BLOCK (foxguard): medium deploy/nginx/build/apache.conf:1 config/nginx-pq-vulnerable-tls (new)"
  # Every name foxguard 0.14.2 reads, found by giving it each one: the
  # extensions, the files it tells by their name, the ones it tells by their
  # path. Each is pushed as it is, in a noise path, with a noise name and with
  # its extension in upper case. logfox is the real foxguard, and writes down
  # what it made of each file it was given. The last thing foxguard says of a
  # pushed file must not be "unsupported extension" or "noise path": that is
  # a file it reads, left out by the copy the hook scanned in its place.
  fox_exts="bash c cjs clj cljc cljs cls cs dart dockerfile edn ex exs gemspec go h hcl hs hsc htm html java js json jsx kt kts lhs mjs ml mli php py pyw rake rb rs sc scala sh sol swift tf tfvars trigger ts tsx xml yaml yml"
  fox_names="Dockerfile Dockerfile.dev nginx.conf my-nginx.conf apache2.conf httpd.conf haproxy.cfg requirements.txt Cargo.lock Pipfile.lock poetry.lock"
  fox_paths="nginx/site.conf conf.d/site.conf apache/site.conf httpd/site.conf sites-enabled/site.conf sites-available/site.conf mods-enabled/site.conf haproxy/site.cfg"
  cat > "$tmp/logfox" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do f="$a"; done
rc=0; $REAL_FOX "$@" > "$FOX_LOG.out" 2> "$FOX_LOG.err" || rc=$?
v=read
if grep -q 'unsupported extension' "$FOX_LOG.out" "$FOX_LOG.err"; then v="unsupported extension"
elif grep -q 'noise path' "$FOX_LOG.out" "$FOX_LOG.err"; then v="noise path"
elif grep -q 'Skipped 1 file' "$FOX_LOG.out" "$FOX_LOG.err"; then v=skipped; fi
printf '%s\t%s\n' "$f" "$v" >> "$FOX_LOG"
cat "$FOX_LOG.out"; cat "$FOX_LOG.err" >&2
exit "$rc"
EOF
  chmod +x "$tmp/logfox"
  setup; publish
  : > "$tmp/enum.plain"; : > "$tmp/enum.all"; : > "$tmp/enum.other"
  for n in $(for e in $fox_exts; do printf 'x.%s\n' "$e"; done) $fox_names $fox_paths; do
    # <d>: its directory, "a" when it has none. <pre>: where a variant with
    # another name goes. An upper-case one goes to a directory u/: its copy
    # (d_u/x.py) must not be taken for the pushed x.py in the log, and on a
    # file system that ignores case x.PY beside x.py would be one file.
    d=a; b="$n"; pre=""
    case "$n" in */*) d="${n%/*}"; b="${n##*/}"; pre="$d/" ;; esac
    printf '%s\n' "$n" >> "$tmp/enum.plain"
    # A list in a variable (no name here has a space): the positional
    # parameters of this script stay empty for the cases below.
    vs="$n $d/build/$b"
    case "$b" in
      *.*)
        st="${b%.*}"; ex="${b##*.}"; ux="$(printf '%s' "$ex" | tr 'a-z' 'A-Z')"
        vs="$vs ${pre}u/$st.$ux $d/build/u/$st.$ux"
        # A name foxguard knows whole (Cargo.lock) is no longer it with .min.
        case "$b" in
          requirements.txt|*.lock) ;;
          *) vs="$vs $pre$st.min.$ex $d/build/$st.min.$ex ${pre}u/$st.min.$ux" ;;
        esac ;;
    esac
    for v in $vs; do
      mkdir -p "$tmp/repo/$(dirname "$v")"
      case "$v" in *.xml|*.XML) printf '<a/>\n' > "$tmp/repo/$v" ;; *) printf '\n' > "$tmp/repo/$v" ;; esac
      printf '%s\n' "$v" >> "$tmp/enum.all"
    done
  done
  # And files it has no rules for, in the same places: none is a skip.
  for v in notes.txt a/build/notes.txt notes.min.txt a/build/notes.min.TXT site.conf a/build/site.conf a/build/site.min.CONF a/build/logo.PNG; do
    printf 'plain text\n' > "$tmp/repo/$v"; printf '%s\n' "$v" >> "$tmp/enum.other"
  done
  gc -C "$tmp/repo" add -A; gc -C "$tmp/repo" commit -q -m "every name foxguard reads"
  # enum_left <log>: the pushed files foxguard did not read in the end, and
  # the plain names it did not read as they are (the list above is then not
  # what this foxguard knows).
  enum_left() {
    LC_ALL=C awk -F'\t' '
      FILENAME == ARGV[1] { plain[$0] = 1; next }
      FILENAME == ARGV[2] { real[$0] = 1; next }
      FILENAME == ARGV[3] { other[$0] = 1; next }
      { a = $1; sub(/^\.\//, "", a); if (a in real) cur = a; else if (a in other) cur = ""
        if (cur != "") { last[cur] = $2; n[cur]++ } }
      END {
        for (f in real) if (last[f] != "read") print f " (" ((f in last) ? last[f] : "never given to foxguard") ")"
        for (f in plain) if (n[f] != 1) print f " (not read as it is: is the list of names current?)"
      }' "$tmp/enum.plain" "$tmp/enum.all" "$tmp/enum.other" "$1" | LC_ALL=C sort -u
  }
  for level in high off; do
    : > "$tmp/enum.log"
    expect "at $level: every name foxguard reads, as $(wc -l < "$tmp/enum.all" | tr -d ' ') clean files, passes" 0 \
      "$(check FOXGUARD_CMD="$tmp/logfox" REAL_FOX="$real_fox" FOX_LOG="$tmp/enum.log" SCRIPT_HELPERS_FOXGUARD_BLOCK="$level")"
    left="$(enum_left "$tmp/enum.log")"
    [[ -s "$tmp/enum.log" && -z "$left" ]] && ok "and foxguard read each one, as it is or as a copy" \
      || error "at $level foxguard did not read: $(printf '%s' "$left" | tr '\n' ';' | cut -c1-600)"
    if grep -qE 'not scanned|skipping|NOT read' "$tmp/out"; then error "at $level a clean file was named: $(grep -E 'not scanned|skipping|NOT read' "$tmp/out" | sed -n 1,3p)"; else ok "and none is named as unread, nor a file foxguard has no rules for"; fi
  done
  # One verdict for each changed file, and the same findings for a copy as
  # for the file where foxguard reads it. cwdfox is the real foxguard, and
  # writes down where it ran and what it made of the file: a copy is scanned
  # from a directory of its own (<n>.d in the blocking scan, below
  # sh-foxguard.* at off).
  cat > "$tmp/cwdfox" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do f="$a"; done
rc=0; $REAL_FOX "$@" > "$FOX_LOG.out" 2> "$FOX_LOG.err" || rc=$?
v="$(cat "$FOX_LOG.out" "$FOX_LOG.err" | LC_ALL=C sed -n 's/^.*Skipped 1 file: 1 \([^.]*\)\..*$/\1/p' | tail -1)"
printf '%s\t%s\t%s\n' "$PWD" "$f" "${v:-read}" >> "$FOX_LOG"
cat "$FOX_LOG.out"; cat "$FOX_LOG.err" >&2
exit "$rc"
EOF
  chmod +x "$tmp/cwdfox"
  conf_code='server { ssl_protocols SSLv3 TLSv1; }
SSLProtocol SSLv3
ssl-default-bind-ciphers RC4-SHA'
  docker_code='FROM x
ENV NODE_TLS_REJECT_UNAUTHORIZED=0'
  sh_code='#!/usr/bin/env bash
eval "$1"'
  broken_code='def f(:
    pass'
  # put <path> <content> <verdict> <the path it must have the findings of>
  put() {
    mkdir -p "$tmp/repo/$(dirname -- "$1")" && printf '%s\n' "$2" > "$tmp/repo/$1" || error "could not write $1"
    printf '%s\t%s\t%s\n' "$1" "$3" "${4:-}" >> "$tmp/inv.want"
  }
  # places <dir> <name> <content> <verdict> [<path>]: the file as it is and
  # wherever a copy is scanned in its place: in noise paths, beside
  # directories named as the copies are, with a noise name, with the
  # extension in upper case. Each must have the findings of <path>; the
  # default is the file as it is.
  places() {
    local d="$1" b="$2" as="" st ex ux
    [[ "$4" == S ]] && as="${5:-$d/$b}"
    put "$d/$b" "$3" "$4" "$as"
    put "$d/build/$b" "$3" "$4" "$as"
    put "$d/w/node_modules/p k/$b" "$3" "$4" "$as"
    put "d_$d/d_build/$b" "$3" "$4" "$as"
    case "$b" in
      *.*)
        st="${b%.*}"; ex="${b##*.}"; ux="$(printf '%s' "$ex" | tr 'a-z' 'A-Z')"
        put "$d/u/$st.$ux" "$3" "$4" "$as"; put "$d/dist/u/$st.$ux" "$3" "$4" "$as"
        # A name foxguard knows whole is no longer it with .min.
        case "$b" in
          requirements.txt) ;;
          *) put "$d/$st.min.$ex" "$3" "$4" "$as"; put "$d/gen/$st.min.$ex" "$3" "$4" "$as"; put "$d/spec/u/$st.min.$ux" "$3" "$4" "$as" ;;
        esac ;;
    esac
  }
  # inv_fill <1: the files foxguard cannot read too>
  inv_fill() {
    setup; publish; : > "$tmp/inv.want"
    places a app.py "$high_code" S; places a 'sp ace (1).py' "$high_code" S; places a -dash.py "$high_code" S
    places a web.js 'document.body.innerHTML = location.hash;' S; places c util.c "$c_code" S
    places nginx site.conf "$conf_code" S; places etc/apache2/sites-enabled 000.conf "$conf_code" S
    places haproxy site.cfg "$conf_code" S; places x nginx.conf "$conf_code" S; places x httpd.conf "$conf_code" S
    places docker Dockerfile "$docker_code" S; places docker Dockerfile.dev "$docker_code" S
    places p requirements.txt 'rsa==4.0' S
    # A script foxguard does not read for its name: as the same code named .sh.
    put bin/deploy.sh "$sh_code" S bin/deploy.sh; places bin deploy "$sh_code" S bin/deploy.sh; places bin tool.cgi "$sh_code" S bin/deploy.sh
    # Two copies that would be one path in a directory for all of them.
    put a/build/d_x.min.js 'document.body.innerHTML = location.hash;' S a/web.js; put a/build/x._min.js/y.py "$high_code" S a/app.py
    if [[ "$1" == 1 ]]; then
      places b broken.py "$broken_code" K; places b brk "#!/bin/sh
if then" K
      places b latin.py "$(printf '# caf\351\nx = 1')" K
      put b/Tmpl.C 'template <class T> class A { public: T v; A() : v() {} };' K
      put b/build/Tmpl.H 'template <class T> class A { public: T v; A() : v() {} };' K
      places t notes.txt 'plain text' N; places t site.conf "$conf_code" N; places t LICENSE 'plain text' N
      places t z "#!/bin/zsh
for f (*.c) print \$f" N
    fi
    gc -C "$tmp/repo" add -A; gc -C "$tmp/repo" commit -q -m "one verdict each"
  }
  # inv_left: each file of inv.want that does not have exactly its verdict.
  # S: the last thing foxguard did with it or a copy of it is read it. K: the
  # hook names it as skipped or not scanned. N: foxguard has no rules for it,
  # under any name the hook gave it.
  inv_left() {
    LC_ALL=C awk -F'\t' '
      FILENAME == ARGV[1] { want[$1] = $2; next }
      FILENAME == ARGV[2] {
        if (sub(/^\[pre-push\] foxguard: (warning: skipping |not scanned: (warning: skipping )?)/, "") && match($0, /^.* \(/)) named[substr($0, 1, RLENGTH - 2)]++
        next }
      { cwd = $1; a = $2; sub(/^\.\//, "", a)
        if (cwd ~ /\/[0-9]+\.d$/ || cwd ~ /\/sh-foxguard\.[^\/]*\/[0-9]+$/) { if (cur != "") { last[cur] = $3; if ($3 != "unsupported extension") code[cur] = 1 } }
        else { cur = a; given[a]++; last[a] = $3; if ($3 != "unsupported extension") code[a] = 1 } }
      END {
        for (f in want) {
          v = ""
          if (last[f] == "read") v = v "S"
          if (named[f] == 1) v = v "K"; else if (named[f] > 1) v = v "K" named[f]
          if (last[f] == "unsupported extension" && !(f in code)) v = v "N"
          if (given[f] != 1) v = v "(given to foxguard as it is " (given[f] + 0) " times)"
          if (v != want[f]) print f ": want " want[f] ", got " (v == "" ? "none" : v)
        }
        for (f in named) if (!(f in want)) print f ": named, and not a pushed file"
      }' "$tmp/inv.want" "$tmp/out" "$tmp/inv.log" | LC_ALL=C sort
  }
  # inv_findings: each pushed file whose BLOCK lines are not those of the
  # file it must have the findings of (the same file where foxguard reads it
  # as it is), and each of those with none.
  inv_findings() {
    LC_ALL=C awk -F'\t' '
      FILENAME == ARGV[1] { pushed[$1] = 1; if ($3 != "") as[$1] = $3; next }
      index($0, "[pre-push] BLOCK (foxguard): ") == 1 && (i = index($0, " (new): ")) {
        s = substr($0, 30, i - 30); sev = s; sub(/ .*/, "", sev); rule = s; sub(/.* /, "", rule)
        loc = substr(s, length(sev) + 2, length(s) - length(sev) - length(rule) - 2)
        file = loc; sub(/:[0-9]+$/, "", file); line = substr(loc, length(file) + 2)
        got[file] = got[file] sev " " line " " rule ";" }
      END {
        for (f in as) {
          if (got[as[f]] == "") print as[f] ": no finding where foxguard reads it as it is"
          else if (got[f] != got[as[f]]) print f ": [" got[f] "], and " as[f] " has [" got[as[f]] "]"
        }
        for (f in got) if (!(f in pushed)) print f ": a finding in a file that was not pushed" }' "$tmp/inv.want" "$tmp/out" | LC_ALL=C sort
  }
  inv_fill 0; : > "$tmp/inv.log"
  expect "$(wc -l < "$tmp/inv.want" | tr -d ' ') files with a finding, most scanned as a copy: refused at low" 1 \
    "$(check FOXGUARD_CMD="$tmp/cwdfox" REAL_FOX="$real_fox" FOX_LOG="$tmp/inv.log" SCRIPT_HELPERS_FOXGUARD_BLOCK=low)"
  left="$(inv_findings)"
  [[ -z "$left" ]] && ok "each copy has the findings of the file where foxguard reads it as it is" \
    || error "a copy does not have the findings of its file: $(printf '%s' "$left" | tr '\n' ';' | cut -c1-900)"
  left="$(inv_left)"
  [[ -s "$tmp/inv.log" && -z "$left" ]] && ok "and each file was read, none named as skipped" \
    || error "not one verdict each: $(printf '%s' "$left" | tr '\n' ';' | cut -c1-900)"
  for level in low off; do
    inv_fill 1; : > "$tmp/inv.log"
    want_rc=1; [[ "$level" == off ]] && want_rc=0
    expect "at $level: $(wc -l < "$tmp/inv.want" | tr -d ' ') files, some that foxguard cannot read and some it has no rules for" "$want_rc" \
      "$(check FOXGUARD_CMD="$tmp/cwdfox" REAL_FOX="$real_fox" FOX_LOG="$tmp/inv.log" SCRIPT_HELPERS_FOXGUARD_BLOCK="$level")"
    left="$(inv_left)"
    [[ -s "$tmp/inv.log" && -z "$left" ]] && ok "and each has exactly one verdict: scanned, named as not read, or not code" \
      || error "at $level not one verdict each: $(printf '%s' "$left" | tr '\n' ';' | cut -c1-900)"
  done
  nk="$(grep -c "$(printf '\tK\t')" "$tmp/inv.want")"; ns="$(grep -c "$(printf '\tS\t')" "$tmp/inv.want")"; na="$(wc -l < "$tmp/inv.want" | tr -d ' ')"
  has "at off the files not read are counted" "foxguard did NOT read $nk of $na changed file(s)"
  has "and each file with a finding" "finding(s) in $ns of $na changed file(s)"
  # A script foxguard does not read for its name (bin/deploy) runs by its
  # first line: it is scanned as a copy named with that language's extension.
  setup; publish; mkdir -p "$tmp/repo/bin"; commit bin/deploy "$sh_code"
  expect "a new finding in a script with no extension blocks" 1 "$(check "$F")"
  has "under its own name" "BLOCK (foxguard): critical bin/deploy:2 bash/taint-command-injection (new)"
  expect "at off: the push goes on" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
  has "and the script is scanned, and named" "WARNING (foxguard): bin/deploy, scanned as d_bin/deploy.sh:"
  publish; commit bin/deploy "$sh_code
# touched"
  expect "a finding in such a script already in the base does not block" 0 "$(check "$F")"
  has "it is a warning" "WARNING (foxguard): critical bin/deploy:2 bash/taint-command-injection (already in the base)"
  setup; publish; commit tool.cgi "#!/usr/bin/env -S python3 -u
$high_code"
  expect "a new finding in a Python script named .cgi blocks" 1 "$(check "$F")"
  has "under its own name" "BLOCK (foxguard): high tool.cgi:4 py/no-yaml-load (new)"
  setup; publish; commit brk "#!/bin/sh
if then"
  expect "a script with no extension that does not parse is refused" 1 "$(check "$F")"
  has "and named" "foxguard: warning: skipping brk (parse error)"
  expect "at off: the push goes on" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
  has "and it is named as not scanned" "foxguard: not scanned: brk (parse error)"
  # No rules for zsh, and LICENSE is no script: neither is a skip.
  setup; publish; commit z "#!/bin/zsh
for f (*.c) print \$f"; commit LICENSE "plain text"
  for level in high off; do
    expect "at $level: a zsh script and a file that is no script pass" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK="$level")"
    if grep -qE 'not scanned|skipping|NOT read' "$tmp/out"; then error "at $level one of them was named: $(grep -E 'not scanned|skipping|NOT read' "$tmp/out" | sed -n 1,3p)"; else ok "and neither is named as unread"; fi
  done
  # A refused push names every file foxguard did not read, the C++ ones too.
  setup; publish; commit broken.py "$broken_code"; commit Tmpl.C 'template <class T> class A { public: T v; A() : v() {} };'
  expect "a push with a file that does not parse and a C++ file named .C is refused" 1 "$(check "$F")"
  has "the first is named" "foxguard: warning: skipping broken.py (parse error)"
  has "and the C++ file too" "foxguard: not scanned: warning: skipping Tmpl.C (parse error)"
  # At off each file has a directory of its own for its copies: in one for
  # all, the copy of the first file is where the second needs a directory.
  setup; publish; mkdir -p "$tmp/repo/a/build/x._min.js"
  commit a/build/d_x.min.js 'document.body.innerHTML = location.hash;'; commit a/build/x._min.js/y.py "$high_code"
  expect "at off: two files whose copies would be one path" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
  has "the first is scanned" "WARNING (foxguard): a/build/d_x.min.js, scanned as d_a/d_build/d_x._min.js:"
  has "and the second" "WARNING (foxguard): a/build/x._min.js/y.py, scanned as d_a/d_build/d_x._min.js/y.py:"
  if grep -qE 'not scanned|NOT read' "$tmp/out"; then error "one of them was not read: $(grep -E 'not scanned|NOT read' "$tmp/out" | sed -n 1,2p)"; else ok "and neither is named as not scanned"; fi
  # At off nothing blocks, and nothing is left out without a word either.
  setup; publish; commit Loader.PY "$high_code"; mkdir -p "$tmp/repo/a/build"; commit a/build/hash.py "$medium_code"
  commit Tmpl.C 'template <class T> class A { public: T v; A() : v() {} };'; commit broken.py 'def f(:
    pass'; commit NOTES.TXT "plain text"; commit a/build/Mod.Py "$high_code"
  mkdir -p "$tmp/repo/deploy/nginx/build"; commit deploy/nginx/build/site.conf 'server { ssl_protocols SSLv3 TLSv1; }'
  commit app.min.py "$high_code"; commit ./-dash.py "$medium_code"
  expect "at off: a push with files foxguard drops goes on" 0 "$(check "$F" SCRIPT_HELPERS_FOXGUARD_BLOCK=off)"
  has "the upper-case extension is scanned" "py/no-yaml-load"
  has "and named" "WARNING (foxguard): Loader.PY, scanned as Loader.py:"
  has "the noise path is scanned" "py/no-weak-crypto"
  has "and named" "WARNING (foxguard): a/build/hash.py, scanned as d_a/d_build/hash.py:"
  has "C++ named .C is named as not scanned" "foxguard: not scanned: Tmpl.C (parse error)"
  has "an unparseable file too" "foxguard: not scanned: broken.py (parse error)"
  has "and both are counted" "foxguard did NOT read 2 of 9 changed file(s)"
  has "a noise name is scanned" "WARNING (foxguard): app.min.py, scanned as app._min.py:"
  has "a name that starts with a dash too" "-dash.py"
  if grep -qF "the foxguard scan did NOT run" "$tmp/out"; then error "at off a scan failed: $(grep -F 'did NOT run' "$tmp/out")"; else ok "and no scan failed"; fi
  has "an upper-case extension in a noise path is scanned" "WARNING (foxguard): a/build/Mod.Py, scanned as d_a/d_build/Mod.py:"
  has "a file told by its path, in a noise path, too" "config/nginx-pq-vulnerable-tls"
  if grep -qF "NOTES.TXT" "$tmp/out"; then error "a file type foxguard does not read was named at off"; else ok "the text file is not named"; fi
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
  # A pattern of a case inside $( ) has its "(" too: without it bash 3.2
  # ends the command substitution at the ")" of the pattern.
  expect "a map of the pushed files that comes out empty refuses the push" 1 \
    "$(awk() { case "$*" in (*'print $0 "\t" $0'*) return 0 ;; esac; command awk "$@"; }; export -f awk; check "$F")"
  has "and says so" "the list of pushed files could not be written"
  expect "a file list that cannot be sorted refuses the push" 1 \
    "$(sort() { case "$*" in (*" -o "*) return 1 ;; esac; command sort "$@"; }; export -f sort; check "$F")"
  has "and says so" "the list of changed files could not be sorted"
  has "with a remedy that is not installing foxguard" "is writable and has free space"
  expect "a base list that cannot be written refuses the push" 1 \
    "$(sed() { case "$*" in (*"1,8p"*) return 4 ;; esac; command sed "$@"; }; export -f sed; check "$F")"
  has "and says so" "the base commits of refs/heads/main could not be listed"
  # Not every sed or awk reports a write that failed: the lists are counted.
  expect "a base list that comes out empty refuses the push" 1 \
    "$(sed() { case "$*" in (*"1,8p"*) return 0 ;; esac; command sed "$@"; }; export -f sed; check "$F")"
  has "and says so" "the base commits of refs/heads/main could not be listed"
  expect "a base file map that comes out empty refuses the push" 1 \
    "$(awk() { case "$*" in (*'FILENAME == ARGV[1]'*) return 0 ;; esac; command awk "$@"; }; export -f awk; check "$F")"
  has "and says so" "the base file map could not be built"
  setup; publish; commit broken.py 'def f(:
    pass'
  expect "a skip of a pushed file that cannot be listed refuses the push" 1 \
    "$(printf() { case "${2:-}" in ("warning: skipping "*) return 1 ;; esac; builtin printf "$@"; }; export -f printf; check "$F")"
  has "as a failed scan" "the foxguard scan failed"
  setup; commit .foxguard.yml "$quiet_cfg"; publish; commit app.py "$high_code"
  expect "a base config that cannot be read refuses the push" 1 \
    "$(git() { case "$*" in ("cat-file blob "*":.foxguard.yml") return 1 ;; esac; command git "$@"; }; export -f git; check "$F")"
  has "and says so" "the foxguard config of the base could not be read"
  expect "a base config that cannot be copied refuses the push" 1 \
    "$(cat() { case "$*" in (*/config) return 1 ;; esac; command cat "$@"; }; export -f cat; check "$F")"
  has "and says so" "the foxguard config of the base could not be copied"
  setup; publish; commit .foxguard.yml "$quiet_cfg"
  expect "a pushed config that cannot be read refuses the push" 1 \
    "$(git() { case "$*" in ("cat-file blob "*":.foxguard.yml") return 1 ;; esac; command git "$@"; }; export -f git; check "$F")"
  has "and says so" "the foxguard config of refs/heads/main could not be read"

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
