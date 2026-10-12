#!/usr/bin/env bash
# SCRIPT: hooks_coexistence_test.sh
# DESCRIPTION: The owner's rules for per-repository hooks: earlier hooks keep working, ours too, ours survive a later takeover (--repair), and uninstall restores what was there.
# USAGE: bash tests/hooks_coexistence_test.sh
# ----------------------------------------------------
# "Ours ran" is proved by a refusal: a staged email in an owner's repository
# must stop the commit. "Theirs ran" is proved by a marker file. Every case
# runs in a throwaway HOME with a stand-in gitleaks.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[hooks_coexistence_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[hooks_coexistence_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_DATA_HOME="$tmp/home/.local/share"
export LOCALAPPDATA="$XDG_DATA_HOME"
export GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset SCRIPT_HELPERS_OWNERS SCRIPT_HELPERS_HOOKS_HOME SCRIPT_HELPERS_REPO_HOOKS_HOME
mkdir -p "$HOME"
: > "$GIT_CONFIG_GLOBAL"
git config --global script-helpers.owners example-owner
printf 'private\tns\tzzq-private-thing\t-\t\n' > "$tmp/names.tsv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/gl-clean"; chmod +x "$tmp/gl-clean"
export PRIVATE_NAMES_FILE="$tmp/names.tsv" PRIVATE_NAMES_AUTO_REFRESH=false GITLEAKS_BIN="$tmp/gl-clean"
cd "$tmp" || exit 1
setup="$root_dir/scripts/setup-hooks.sh"
repo_hooks="$XDG_DATA_HOME/script-helpers/repo-hooks/hooks"
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
email="jane.roe""@""mailbox.org"

# marker_hook <path> <name>: a hook that appends <name> to $tmp/ran.
marker_hook() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\necho %s >> "%s/ran"\nexit 0\n' "$2" "$tmp" > "$1"
  chmod +x "$1"
}

# new_repo <name>: an owner's clone (origin under example-owner).
new_repo() {
  local r="$tmp/$1"
  git init -q "$r"
  git -C "$r" config user.name test; git -C "$r" config user.email test@example.invalid
  git -C "$r" remote add origin "https://github.com/example-owner/$1.git"
  echo "$r"
}

# clean_commit <repo>: a commit that must pass; $tmp/ran lists the hooks that ran.
clean_commit() {
  : > "$tmp/ran"
  printf 'x %s\n' "$RANDOM" >> "$1/f"; git -C "$1" add f
  git -C "$1" commit -q -m "msg $RANDOM" >/dev/null 2>&1
}
# ours_refuse <repo>: 0 when our check stopped a commit with a staged email.
ours_refuse() {
  printf 'mail %s\n' "$email" > "$1/leak.txt"; git -C "$1" add leak.txt
  if git -C "$1" commit -q -m "leak" >/dev/null 2>&1; then
    git -C "$1" reset -q --soft HEAD~1; git -C "$1" rm -q --cached leak.txt; rm -f "$1/leak.txt"; return 1
  fi
  git -C "$1" rm -q --cached leak.txt; rm -f "$1/leak.txt"; return 0
}
ran() { tr '\n' ' ' < "$tmp/ran" | sed 's/ $//'; }
state() { (cd "$1" && bash "$setup" --status --porcelain 2>/dev/null); }
field() { state "$1" | tr '\t' '\n' | sed -n "s/^$2=//p"; }
local_config() { git -C "$1" config --local --list | grep -vE '^(user\.|remote\.|core\.(repositoryformatversion|filemode|bare|logallrefupdates))' | sort; }

# Rules 1 and 2: an employer's core.hooksPath set before us: both run.
r="$(new_repo employer)"
marker_hook "$tmp/employer-hooks/pre-commit" employer
git -C "$r" config core.hooksPath "$tmp/employer-hooks"
before="$(local_config "$r")"
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "employer: setup failed"
clean_commit "$r" && [[ "$(ran)" == "employer" ]] && ok "rule 1: the employer hook still runs" || error "employer: ran '$(ran)'"
ours_refuse "$r" && ok "rule 2: our check runs too (staged email refused)" || error "employer: our check did not run"
[[ "$(field "$r" mode)" == chained && "$(field "$r" taken_over)" == no ]] && ok "status: chained, not taken over" \
  || error "employer: status '$(state "$r")'"

# Rule 4: uninstall leaves .git/config exactly as before.
(cd "$r" && bash "$setup" --uninstall >/dev/null 2>&1) || error "employer: uninstall failed"
[[ "$(local_config "$r")" == "$before" ]] && ok "rule 4: uninstall restores .git/config exactly" \
  || error "employer: config after uninstall differs: $(diff <(echo "$before") <(local_config "$r") | tr '\n' ' ')"
clean_commit "$r" && [[ "$(ran)" == "employer" ]] && ok "rule 4: the employer hook runs after uninstall" || error "employer after uninstall: ran '$(ran)'"

# Rule 3a: a hook added to .git/hooks after the setup runs (chained setups read it each time).
r="$(new_repo later-native)"
marker_hook "$r/.git/hooks/pre-commit" first
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "later-native: setup failed"
marker_hook "$r/.git/hooks/pre-commit" added-later
clean_commit "$r" && [[ "$(ran)" == "added-later" ]] && ok "rule 3: a hook changed in .git/hooks after setup runs" || error "later-native: ran '$(ran)'"
ours_refuse "$r" && ok "rule 3: ours still run beside it" || error "later-native: our check did not run"

# Rule 3b: a committed hook added after the setup runs.
r="$(new_repo later-committed)"
marker_hook "$tmp/emp2/pre-commit" employer
git -C "$r" config core.hooksPath "$tmp/emp2"
mkdir -p "$r/.githooks"
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "later-committed: setup failed"
marker_hook "$tmp/emp2/commit-msg" employer-msg
clean_commit "$r" && [[ "$(ran)" == "employer employer-msg" ]] && ok "rule 3: a hook added to the earlier hooksPath later runs" || error "later-committed: ran '$(ran)'"

# Rule 3c: a takeover (husky sets core.hooksPath after us): reported, --repair makes both run.
r="$(new_repo takeover)"
marker_hook "$tmp/emp3/pre-commit" employer
git -C "$r" config core.hooksPath "$tmp/emp3"
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "takeover: setup failed"
marker_hook "$r/.husky/pre-commit" husky
git -C "$r" config core.hooksPath .husky
[[ "$(field "$r" taken_over)" == yes ]] && ok "rule 3: a takeover is reported (taken_over=yes)" || error "takeover: status '$(state "$r")'"
out="$(cd "$r" && bash "$setup" --status 2>/dev/null)"
grep -q 'WARN: core.hooksPath was changed after the setup here' <<<"$out" \
  && ok "--status warns about the takeover and names --repair" || error "takeover: --status gave no warning"
(cd "$r" && bash "$setup" --repair >/dev/null 2>&1) || error "takeover: --repair failed"
[[ "$(field "$r" taken_over)" == no && "$(field "$r" previous)" == .husky ]] && ok "--repair: chained again, .husky is the previous value" \
  || error "takeover: after repair '$(state "$r")'"
[[ "$(git -C "$r" config --get script-helpers.previous-hooksPath-history)" == "$(native "$tmp/emp3")" ]] && ok "--repair keeps the replaced value as history" \
  || error "takeover: history '$(git -C "$r" config --get script-helpers.previous-hooksPath-history)'"
clean_commit "$r" && [[ "$(ran)" == "husky" ]] && ok "after --repair the new tool's hook runs" || error "takeover: ran '$(ran)'"
ours_refuse "$r" && ok "after --repair our check runs again" || error "takeover: our check did not run after repair"
(cd "$r" && bash "$setup" --repair >/dev/null 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "--repair with nothing to repair: exit 0" || error "takeover: second repair rc=$rc"
(cd "$r" && bash "$setup" --uninstall >/dev/null 2>&1)
[[ "$(git -C "$r" config --get core.hooksPath)" == .husky ]] && ok "rule 4: uninstall after repair restores .husky (the setup just before)" \
  || error "takeover: hooksPath after uninstall '$(git -C "$r" config --get core.hooksPath)'"
[[ -z "$(git -C "$r" config --local --get-regexp '^script-helpers\.' 2>/dev/null)" ]] && ok "uninstall removes every script-helpers key" \
  || error "takeover: keys left: $(git -C "$r" config --local --get-regexp '^script-helpers\.' | tr '\n' ' ')"

# Rule 3d: a direct setup (the repository's own .githooks) taken over: --repair
# chains the new tool, then the committed hooks.
r="$(new_repo direct-takeover)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "direct-takeover: setup failed"
[[ "$(field "$r" mode)" == direct && "$(field "$r" expected)" == .githooks ]] && ok "direct setup: mode=direct, expected .githooks" \
  || error "direct-takeover: '$(state "$r")'"
marker_hook "$r/.husky/pre-commit" husky
git -C "$r" config core.hooksPath .husky
[[ "$(field "$r" taken_over)" == yes ]] && ok "direct setup taken over: reported" || error "direct-takeover: '$(state "$r")'"
(cd "$r" && bash "$setup" --repair >/dev/null 2>&1) || error "direct-takeover: repair failed"
[[ "$(field "$r" mode)" == chained && "$(field "$r" previous)" == .husky && "$(field "$r" target)" == .githooks ]] \
  && ok "--repair: chained; committed hooks the target, .husky the previous" || error "direct-takeover: '$(state "$r")'"
clean_commit "$r" && [[ "$(ran)" == "committed husky" ]] && ok "after --repair both the committed hook and husky run" || error "direct-takeover: ran '$(ran)'"

# An older vendored copy of these hooks run again is not a new tool: --repair
# keeps the chain, the employer's value included.
r="$(new_repo vendored-rerun)"
marker_hook "$tmp/emp4/pre-commit" employer
git -C "$r" config core.hooksPath "$tmp/emp4"
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "vendored-rerun: setup failed"
git -C "$r" config core.hooksPath scripts/script-helpers/scripts/git-hooks
(cd "$r" && bash "$setup" --repair >/dev/null 2>&1) || error "vendored-rerun: repair failed"
[[ "$(field "$r" previous)" == "$(native "$tmp/emp4")" && "$(field "$r" taken_over)" == no ]] \
  && ok "--repair after an old copy of ours ran: the employer value stays chained" || error "vendored-rerun: '$(state "$r")'"
clean_commit "$r" && [[ "$(ran)" == "employer" ]] && ok "and the employer hook still runs" || error "vendored-rerun: ran '$(ran)'"

# Rule 4 after a takeover with no repair: uninstall leaves the new tool alone.
r="$(new_repo takeover-uninstall)"
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "takeover-uninstall: setup failed"
git -C "$r" config core.hooksPath .husky
(cd "$r" && bash "$setup" --uninstall >/dev/null 2>&1)
[[ "$(git -C "$r" config --get core.hooksPath)" == .husky ]] && ok "uninstall after a takeover leaves the new value alone" \
  || error "takeover-uninstall: hooksPath '$(git -C "$r" config --get core.hooksPath)'"

# A takeover that removes core.hooksPath is a takeover too.
r="$(new_repo unset-takeover)"
marker_hook "$r/.git/hooks/pre-commit" native
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "unset-takeover: setup failed"
git -C "$r" config --unset core.hooksPath
[[ "$(field "$r" taken_over)" == yes ]] && ok "core.hooksPath removed after setup: reported as a takeover" || error "unset-takeover: '$(state "$r")'"
(cd "$r" && bash "$setup" --repair >/dev/null 2>&1) || error "unset-takeover: repair failed"
clean_commit "$r" && [[ "$(ran)" == "native" ]] && ours_refuse "$r" && ok "after --repair both .git/hooks and ours run" || error "unset-takeover: ran '$(ran)'"

# A setup from 0.49.0 (no mode key) is read from the keys it wrote.
r="$(new_repo legacy)"
marker_hook "$r/.git/hooks/pre-commit" native
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "legacy: setup failed"
git -C "$r" config --unset script-helpers.mode; git -C "$r" config --unset script-helpers.expected-hooksPath
[[ "$(field "$r" mode)" == chained && "$(field "$r" taken_over)" == no ]] && ok "a 0.49.0 setup reads as chained" || error "legacy: '$(state "$r")'"
git -C "$r" config core.hooksPath .husky
[[ "$(field "$r" taken_over)" == yes ]] && ok "and its takeover is reported" || error "legacy takeover: '$(state "$r")'"

# Never set up: mode=none, --repair refuses (exit 1) and changes nothing.
r="$(new_repo none)"
[[ "$(field "$r" mode)" == none ]] && ok "not set up: mode=none" || error "none: '$(state "$r")'"
(cd "$r" && bash "$setup" --repair >/dev/null 2>&1); rc=$?
[[ $rc -eq 1 && -z "$(git -C "$r" config --local --get core.hooksPath)" ]] && ok "--repair where nothing is set up: exit 1, nothing changed" || error "none: repair rc=$rc"

# --porcelain reads the per-repository Claude hook from the file (a .gitignore
# that covers .claude/ means no exclude marker), and reports the --global hooks.
r="$(new_repo porcelain-claude)"
printf '.claude/\n' > "$r/.gitignore"
(cd "$r" && bash "$setup" --claude-repo >/dev/null 2>&1) || error "porcelain-claude: --claude-repo failed"
[[ "$(field "$r" claude_repo)" == yes ]] && ok "--porcelain: claude_repo=yes when .gitignore covers the file" || error "porcelain-claude: '$(state "$r")'"
(cd "$tmp" && bash "$setup" --global >/dev/null 2>&1) || error "porcelain-global: --global failed"
r="$(new_repo porcelain-global)"
[[ "$(field "$r" mode)" == none && "$(field "$r" global)" == yes ]] && ok "--porcelain: global=yes where the --global hooks run" || error "porcelain-global: '$(state "$r")'"
(cd "$tmp" && bash "$setup" --global --uninstall >/dev/null 2>&1)

# Flags that do not go together are refused (exit 2).
(cd "$r" && bash "$setup" --porcelain >/dev/null 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "--porcelain without --status: exit 2" || error "porcelain alone rc=$rc"
(cd "$r" && bash "$setup" --repair --uninstall >/dev/null 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "--repair with --uninstall: exit 2" || error "repair+uninstall rc=$rc"

if [[ $failures -gt 0 ]]; then echo "[hooks_coexistence_test] $failures failure(s)" >&2; exit 1; fi
note "all passed"
