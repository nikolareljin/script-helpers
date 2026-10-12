#!/usr/bin/env bash
# SCRIPT: setup_hooks_chain_test.sh
# DESCRIPTION: setup-hooks.sh per repository keeps hooks that already ran (local or global core.hooksPath, .git/hooks) and chains them; --uninstall restores them.
# USAGE: bash tests/setup_hooks_chain_test.sh
# ----------------------------------------------------
# An employer's or another tool's hooks must keep working after setup, and
# nothing tracked may change. Every case runs in a throwaway HOME.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[setup_hooks_chain_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[setup_hooks_chain_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_DATA_HOME="$tmp/home/.local/share"
export GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset SCRIPT_HELPERS_OWNERS SCRIPT_HELPERS_HOOKS_HOME SCRIPT_HELPERS_REPO_HOOKS_HOME
mkdir -p "$HOME"
: > "$GIT_CONFIG_GLOBAL"
# Run from the scratch directory: git commands never depend on the caller's checkout.
cd "$tmp" || exit 1
setup="$root_dir/scripts/setup-hooks.sh"
repo_hooks="$XDG_DATA_HOME/script-helpers/repo-hooks/hooks"

# marker_hook <path> <name> [exit]: a hook that appends <name> to $tmp/ran.
marker_hook() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\necho %s >> "%s/ran"\nexit %s\n' "$2" "$tmp" "${3:-0}" > "$1"
  chmod +x "$1"
}

new_repo() {
  local r="$tmp/$1"
  git init -q "$r"
  git -C "$r" config user.name test; git -C "$r" config user.email test@example.invalid
  printf 'x\n' > "$r/f"; git -C "$r" add f
  echo "$r"
}

commit_in() { : > "$tmp/ran"; git -C "$1" commit -q --allow-empty -m "msg $RANDOM" >/dev/null 2>&1; }
ran() { tr '\n' ' ' < "$tmp/ran" | sed 's/ $//'; }
local_config() { git -C "$1" config --local --list | grep -vE '^(user\.|core\.(repositoryformatversion|filemode|bare|logallrefupdates))' | sort; }

# 1. Nothing running yet, committed .githooks: core.hooksPath points straight at it (unchanged behaviour).
r="$(new_repo direct)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "direct: setup failed"
[[ "$(git -C "$r" config --get core.hooksPath)" == ".githooks" ]] && ok "no earlier hooks: core.hooksPath = .githooks" \
  || error "direct: core.hooksPath = '$(git -C "$r" config --get core.hooksPath)'"

# 2. .git/hooks/pre-commit exists: it keeps running, after the committed hook.
r="$(new_repo native)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
marker_hook "$r/.git/hooks/pre-commit" theirs
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "native: setup failed"
[[ "$(git -C "$r" config --get core.hooksPath)" == "$repo_hooks" ]] && ok ".git/hooks present: chained through the per-repo copy" \
  || error "native: core.hooksPath = '$(git -C "$r" config --get core.hooksPath)'"
commit_in "$r"
[[ "$(ran)" == "committed theirs" ]] && ok ".git/hooks/pre-commit still runs, after the committed one" || error "native: ran '$(ran)'"

# 3. Another tool's local core.hooksPath (.husky): every hook it has still runs, uninstall restores it.
r="$(new_repo husky)"
marker_hook "$r/.husky/pre-commit" husky-pre-commit
marker_hook "$r/.husky/commit-msg" husky-commit-msg
git -C "$r" config core.hooksPath .husky
before="$(local_config "$r")"
status_before="$(git -C "$r" status --porcelain)"
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "husky: setup failed"
[[ "$(git -C "$r" status --porcelain)" == "$status_before" ]] && ok "git status unchanged by setup" || error "husky: git status changed"
[[ "$(git -C "$r" config --get script-helpers.previous-hooksPath)" == ".husky" ]] && ok "the earlier core.hooksPath is saved" \
  || error "husky: previous-hooksPath = '$(git -C "$r" config --get script-helpers.previous-hooksPath)'"
commit_in "$r"
[[ "$(ran)" == "husky-pre-commit husky-commit-msg" ]] && ok "husky's pre-commit and commit-msg still run" || error "husky: ran '$(ran)'"
# Running setup again keeps the saved value; it never saves its own path.
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "husky: second setup failed"
[[ "$(git -C "$r" config --get script-helpers.previous-hooksPath)" == ".husky" ]] && ok "a second setup keeps .husky as the previous value" \
  || error "husky: after rerun previous-hooksPath = '$(git -C "$r" config --get script-helpers.previous-hooksPath)'"
(cd "$r" && bash "$setup" --uninstall >/dev/null 2>&1) || error "husky: uninstall failed"
[[ "$(local_config "$r")" == "$before" ]] && ok "--uninstall leaves .git/config as it was" \
  || error "husky: config after uninstall differs: $(diff <(echo "$before") <(local_config "$r") | tr '\n' ' ')"
commit_in "$r"
[[ "$(ran)" == "husky-pre-commit husky-commit-msg" ]] && ok "after --uninstall husky runs exactly as before" || error "husky after uninstall: ran '$(ran)'"

# 4. A failing earlier hook still blocks the commit.
r="$(new_repo failing)"
marker_hook "$r/.hooks/pre-commit" refuses 3
git -C "$r" config core.hooksPath .hooks
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "failing: setup failed"
head_before="$(git -C "$r" rev-parse -q --verify HEAD || echo none)"
commit_in "$r"
[[ "$(git -C "$r" rev-parse -q --verify HEAD || echo none)" == "$head_before" ]] && ok "an earlier hook that fails still blocks the commit" \
  || error "failing: the commit went through"

# 5. A global core.hooksPath (an employer's): it keeps running, and stays set.
r="$(new_repo global)"
marker_hook "$tmp/employer-hooks/pre-commit" employer
git config --global core.hooksPath "$tmp/employer-hooks"
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "global: setup failed"
commit_in "$r"
[[ "$(ran)" == "employer" ]] && ok "a global core.hooksPath keeps running" || error "global: ran '$(ran)'"
[[ "$(git config --global --get core.hooksPath)" == "$tmp/employer-hooks" ]] && ok "the global value is not touched" \
  || error "global: global core.hooksPath changed"
git config --global --unset core.hooksPath

# 6. pre-push input reaches the earlier hook unchanged.
r="$(new_repo stdin)"
mkdir -p "$r/.hooks"
printf '#!/usr/bin/env bash\ncat > "%s/pushed"\n' "$tmp" > "$r/.hooks/pre-push"; chmod +x "$r/.hooks/pre-push"
git -C "$r" config core.hooksPath .hooks
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "stdin: setup failed"
line="refs/heads/main $(printf '1%.0s' {1..40}) refs/heads/main $(printf '0%.0s' {1..40})"
(cd "$r" && printf '%s\n' "$line" | bash "$repo_hooks/pre-push" origin https://example.invalid/r.git >/dev/null 2>&1) || true
[[ "$(cat "$tmp/pushed" 2>/dev/null)" == "$line" ]] && ok "the earlier pre-push gets git's ref list on stdin" \
  || error "stdin: got '$(cat "$tmp/pushed" 2>/dev/null)'"

# 7. A core.hooksPath this script did not set is left alone by --uninstall.
r="$(new_repo foreign-uninstall)"
git -C "$r" config core.hooksPath .other
(cd "$r" && bash "$setup" --uninstall >/dev/null 2>&1) || true
[[ "$(git -C "$r" config --get core.hooksPath)" == ".other" ]] && ok "--uninstall never removes another tool's core.hooksPath" \
  || error "foreign-uninstall: core.hooksPath = '$(git -C "$r" config --get core.hooksPath)'"

# 8. Another tool's own scripts/git-hooks (not script-helpers') is kept, not mistaken for ours.
r="$(new_repo own-scripts-dir)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
marker_hook "$r/scripts/git-hooks/commit-msg" their-commit-msg
git -C "$r" config core.hooksPath scripts/git-hooks
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "own-scripts-dir: setup failed"
commit_in "$r"
[[ "$(ran)" == "committed their-commit-msg" ]] && ok "a repository's own scripts/git-hooks keeps running" || error "own-scripts-dir: ran '$(ran)'"

# 9. With --global installed: no earlier hooks -> direct; an earlier global hooks dir -> runs once.
export SCRIPT_HELPERS_OWNERS=example-owner
r="$(new_repo with-global)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
bash "$setup" --global >/dev/null 2>&1 || error "with-global: --global failed"
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "with-global: setup failed"
[[ "$(git -C "$r" config --get core.hooksPath)" == ".githooks" ]] && ok "our own --global is not an earlier hook: direct mode" \
  || error "with-global: core.hooksPath = '$(git -C "$r" config --get core.hooksPath)'"
bash "$setup" --global --uninstall >/dev/null 2>&1
marker_hook "$tmp/employer2/pre-commit" employer
git config --global core.hooksPath "$tmp/employer2"
bash "$setup" --global >/dev/null 2>&1 || error "with-global: --global over employer failed"
r="$(new_repo with-global-employer)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "with-global-employer: setup failed"
commit_in "$r"
[[ "$(ran)" == "committed employer" ]] && ok "the hooks --global replaced run once, after the committed ones" || error "with-global-employer: ran '$(ran)'"
bash "$setup" --global --uninstall >/dev/null 2>&1
[[ "$(git config --global --get core.hooksPath)" == "$tmp/employer2" ]] || error "with-global: employer value not restored"
git config --global --unset core.hooksPath
unset SCRIPT_HELPERS_OWNERS

# 10. --claude-repo next to a machine-wide mode is refused.
rc=0; (cd "$r" && bash "$setup" --claude-repo --global >/dev/null 2>&1) || rc=$?
[[ $rc -eq 2 ]] && ok "--claude-repo with --global is refused (2)" || error "claude-repo+global: rc=$rc"

# 11-12. --claude-repo: the hook for this repository only, nothing git can see.
if command -v python3 >/dev/null 2>&1; then
  export SCRIPT_HELPERS_OWNERS=example-owner
  merge="$root_dir/scripts/claude-hooks/merge_settings.py"
  r="$(new_repo claude-new)"
  exclude_before="$(cat "$r/.git/info/exclude" 2>/dev/null)"
  (cd "$r" && bash "$setup" --claude-repo >/dev/null 2>&1) || error "claude-repo: setup failed"
  python3 "$merge" status "$r/.claude/settings.local.json" >/dev/null 2>&1 && ok "--claude-repo writes the entry to .claude/settings.local.json" \
    || error "claude-repo: no entry in settings.local.json"
  [[ -z "$(git -C "$r" status --porcelain --untracked-files=all | grep -v '^A  f$')" ]] && ok "--claude-repo: git status shows nothing new" \
    || error "claude-repo: git status: $(git -C "$r" status --porcelain --untracked-files=all | tr '\n' ' ')"
  (cd "$r" && bash "$setup" --claude-repo --uninstall >/dev/null 2>&1) || error "claude-repo: uninstall failed"
  [[ ! -e "$r/.claude" ]] && ok "--claude-repo --uninstall removes the file it created" || error "claude-repo: .claude left: $(ls -A "$r/.claude" | tr '\n' ' ')"
  [[ "$(cat "$r/.git/info/exclude" 2>/dev/null)" == "$exclude_before" ]] && ok "--uninstall restores .git/info/exclude" \
    || error "claude-repo: exclude differs"
  [[ -z "$(git -C "$r" config --local --get-regexp '^script-helpers\.' 2>/dev/null)" ]] && ok "--uninstall leaves no script-helpers keys" \
    || error "claude-repo: keys left: $(git -C "$r" config --local --get-regexp '^script-helpers\.' | tr '\n' ' ')"

  r="$(new_repo claude-existing)"
  mkdir -p "$r/.claude"
  printf '{\n  "permissions": {"allow": ["Bash(ls)"]}\n}\n' > "$r/.claude/settings.local.json"
  printf '/.claude/settings.local.json\n' >> "$r/.git/info/exclude"
  (cd "$r" && bash "$setup" --claude-repo >/dev/null 2>&1) || error "claude-existing: setup failed"
  (cd "$r" && bash "$setup" --claude-repo --uninstall >/dev/null 2>&1) || error "claude-existing: uninstall failed"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permissions") == {"allow": ["Bash(ls)"]} else 1)' "$r/.claude/settings.local.json" \
    && ok "an existing settings.local.json keeps its own settings" || error "claude-existing: permissions lost"
  [[ -z "$(ls "$r/.claude" | grep -v '^settings.local.json$')" ]] && ok "no backup files left in .claude/" \
    || error "claude-existing: in .claude: $(ls -A "$r/.claude" | tr '\n' ' ')"
  [[ -z "$(git -C "$r" status --porcelain --untracked-files=all | grep -v '^A  f$')" ]] && ok "existing file: git status shows nothing new" \
    || error "claude-existing: git status: $(git -C "$r" status --porcelain --untracked-files=all | tr '\n' ' ')"
  unset SCRIPT_HELPERS_OWNERS
else
  note "SKIP: python3 not available, --claude-repo not checked"
fi

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
