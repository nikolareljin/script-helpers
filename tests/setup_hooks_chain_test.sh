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
# On Windows (Git Bash) setup-hooks.sh keeps its copies under %LOCALAPPDATA%.
export LOCALAPPDATA="$XDG_DATA_HOME"
export GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset SCRIPT_HELPERS_OWNERS SCRIPT_HELPERS_HOOKS_HOME SCRIPT_HELPERS_REPO_HOOKS_HOME
mkdir -p "$HOME"
: > "$GIT_CONFIG_GLOBAL"
# Run from the scratch directory: git commands never depend on the caller's checkout.
cd "$tmp" || exit 1
setup="$root_dir/scripts/setup-hooks.sh"
repo_hooks="$XDG_DATA_HOME/script-helpers/repo-hooks/hooks"
# native <path>: the form git stores a path in (C:/... under Git for Windows).
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

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

# 1. Nothing running yet, committed .githooks: chained after the current security
#    checks, with .githooks as the target (it is not this copy's own hooks).
r="$(new_repo direct)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "direct: setup failed"
[[ "$(git -C "$r" config --get script-helpers.mode)" == chained && "$(git -C "$r" config --get script-helpers.hooks-target)" == .githooks ]] \
  && ok "no earlier hooks: chained, .githooks the target" \
  || error "direct: mode=$(git -C "$r" config --get script-helpers.mode) target=$(git -C "$r" config --get script-helpers.hooks-target)"
commit_in "$r"; [[ "$(ran)" == "committed" ]] && ok "the committed .githooks hook still runs" || error "direct: ran '$(ran)'"

# 2. .git/hooks/pre-commit exists: it keeps running, after the committed hook.
r="$(new_repo native)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
marker_hook "$r/.git/hooks/pre-commit" theirs
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "native: setup failed"
[[ "$(git -C "$r" config --get core.hooksPath)" == "$(native "$repo_hooks")" ]] && ok ".git/hooks present: chained through the per-repo copy" \
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
[[ "$(git config --global --get core.hooksPath)" == "$(native "$tmp/employer-hooks")" ]] && ok "the global value is not touched" \
  || error "global: global core.hooksPath changed"
git config --global --unset core.hooksPath

# 6. pre-push input reaches the earlier hook unchanged.
r="$(new_repo stdin)"
mkdir -p "$r/.hooks"
printf '#!/usr/bin/env bash\ncat > "%s/pushed"\n' "$tmp" > "$r/.hooks/pre-push"; chmod +x "$r/.hooks/pre-push"
git -C "$r" config core.hooksPath .hooks
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "stdin: setup failed"
line="refs/heads/main $(printf '1%.0s' {1..40}) refs/heads/main $(printf '0%.0s' {1..40})"
(cd "$r" && printf '%s\n' "$line" | bash "$repo_hooks/pre-push" origin https://example.invalid/r.git >"$tmp/out" 2>&1) || true
[[ "$(cat "$tmp/pushed" 2>/dev/null)" == "$line" ]] && ok "the earlier pre-push gets git's ref list on stdin" \
  || { error "stdin: got '$(cat "$tmp/pushed" 2>/dev/null)'"; sed 's/^/    /' "$tmp/out" >&2; }

# 6b. script-helpers.push-tests quick: the dispatcher runs the quick tests once
#     and refuses a failing suite; a chained script-helpers pre-push is skipped.
r="$(new_repo pushtests)"
printf 'test:\n\t@echo SUITE-RAN; exit 1\n' > "$r/Makefile"; git -C "$r" add Makefile
git -C "$r" commit -q -m "suite" >/dev/null 2>&1
git -C "$r" config script-helpers.push-tests quick
(cd "$r" && SCRIPT_HELPERS_OWNERS=acme bash "$setup" >/dev/null 2>&1) || error "pushtests: setup failed"
line="refs/heads/main $(git -C "$r" rev-parse HEAD) refs/heads/main $(printf '0%.0s' {1..40})"
rc=0
(cd "$r" && printf '%s\n' "$line" | SCRIPT_HELPERS_OWNERS=acme SECURITY_GATE_ALLOW_UNCHECKED=1 PRIVATE_NAMES_AUTO_REFRESH=false \
  PRIVATE_NAMES_FILE=/nonexistent/private-names.tsv \
  bash "$repo_hooks/pre-push" origin git@github.com:acme/r.git >"$tmp/out" 2>&1) || rc=$?
if [[ $rc -ne 0 ]] && grep -q 'tests failed' "$tmp/out" && [[ "$(grep -c SUITE-RAN "$tmp/out")" -eq 1 ]]; then
  ok "the dispatcher runs push-tests quick once and refuses a failing suite"
else
  error "pushtests: rc=$rc, suite ran $(grep -c SUITE-RAN "$tmp/out") time(s)"; sed 's/^/    /' "$tmp/out" >&2
fi

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
[[ "$(git -C "$r" config --get script-helpers.hooks-target)" == .githooks && -z "$(git -C "$r" config --get script-helpers.previous-hooksPath)" ]] \
  && ok "our own --global is not an earlier hook: .githooks the target, nothing previous" \
  || error "with-global: target=$(git -C "$r" config --get script-helpers.hooks-target) previous=$(git -C "$r" config --get script-helpers.previous-hooksPath)"
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
[[ "$(git config --global --get core.hooksPath)" == "$(native "$tmp/employer2")" ]] || error "with-global: employer value not restored"
git config --global --unset core.hooksPath
unset SCRIPT_HELPERS_OWNERS

# 10. --claude-repo next to a machine-wide mode is refused.
rc=0; (cd "$r" && bash "$setup" --claude-repo --global >/dev/null 2>&1) || rc=$?
[[ $rc -eq 2 ]] && ok "--claude-repo with --global is refused (2)" || error "claude-repo+global: rc=$rc"

# 10a. A failing committed hook stops the chain: what ran before does not run.
r="$(new_repo committed-fails)"
marker_hook "$r/.githooks/pre-commit" committed-refuses 1
marker_hook "$r/.githooks/pre-push" committed-push
marker_hook "$r/.git/hooks/pre-commit" theirs
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "committed-fails: setup failed"
head_before="$(git -C "$r" rev-parse -q --verify HEAD || echo none)"
commit_in "$r"
[[ "$(ran)" == "committed-refuses" && "$(git -C "$r" rev-parse -q --verify HEAD || echo none)" == "$head_before" ]] \
  && ok "a failing committed hook blocks the commit and stops the chain" || error "committed-fails: ran '$(ran)'"

# 10b. The repository's own core.hooksPath (.githooks) survives setup and --uninstall.
r="$(new_repo own-githooks)"
marker_hook "$r/.githooks/pre-commit" committed
marker_hook "$r/.githooks/pre-push" committed-push
git -C "$r" config core.hooksPath .githooks
(cd "$r" && bash "$setup" >/dev/null 2>&1 && bash "$setup" --uninstall >/dev/null 2>&1) || error "own-githooks: setup/uninstall failed"
[[ "$(git -C "$r" config --get core.hooksPath)" == ".githooks" ]] && ok "the repository's own core.hooksPath survives --uninstall" \
  || error "own-githooks: core.hooksPath = '$(git -C "$r" config --get core.hooksPath)'"

# 10c. Committed hooks that are not executable: no tracked mode change, and they still run.
r="$(new_repo not-exec)"
mkdir -p "$r/.githooks"
printf '#!/usr/bin/env bash\necho committed >> "%s/ran"\n' "$tmp" > "$r/.githooks/pre-commit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$r/.githooks/pre-push"
git -C "$r" add .githooks && git -C "$r" commit -q -m hooks --no-verify
(cd "$r" && bash "$setup" >/dev/null 2>&1) || error "not-exec: setup failed"
[[ -z "$(git -C "$r" status --porcelain)" ]] && ok "non-executable committed hooks: no tracked mode change" \
  || error "not-exec: git status: $(git -C "$r" status --porcelain | tr '\n' ' ')"
commit_in "$r"
[[ "$(ran)" == "committed" ]] && ok "non-executable committed hooks still run" || error "not-exec: ran '$(ran)'"

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
  [[ -z "$(find "$r/.claude" -mindepth 1 -maxdepth 1 ! -name settings.local.json)" ]] && ok "no backup files left in .claude/" \
    || error "claude-existing: in .claude: $(ls -A "$r/.claude" | tr '\n' ' ')"
  [[ -z "$(git -C "$r" status --porcelain --untracked-files=all | grep -v '^A  f$')" ]] && ok "existing file: git status shows nothing new" \
    || error "claude-existing: git status: $(git -C "$r" status --porcelain --untracked-files=all | tr '\n' ' ')"
  # A refused install writes nothing, so a later uninstall never deletes the user's file.
  r="$(new_repo claude-refused)"
  exclude_before="$(cat "$r/.git/info/exclude" 2>/dev/null)"
  rc=0; (cd "$r" && SCRIPT_HELPERS_OWNERS='' bash "$setup" --claude-repo >/dev/null 2>&1) || rc=$?
  [[ $rc -eq 2 && -z "$(git -C "$r" config --local --get script-helpers.claude-local-created)" && "$(cat "$r/.git/info/exclude" 2>/dev/null)" == "$exclude_before" ]] \
    && ok "--claude-repo refused (no owners): nothing written" || error "claude-refused: rc=$rc or state written"
  mkdir -p "$r/.claude"; printf '{"permissions": {}}\n' > "$r/.claude/settings.local.json"
  (cd "$r" && bash "$setup" --claude-repo --uninstall >/dev/null 2>&1) || true
  [[ -f "$r/.claude/settings.local.json" ]] && ok "uninstall after a refused install keeps the user's file" || error "claude-refused: user's file deleted"

  # A tracked settings.local.json is refused and left as it is.
  r="$(new_repo claude-tracked)"
  mkdir -p "$r/.claude"; printf '{}\n' > "$r/.claude/settings.local.json"
  git -C "$r" add -f .claude/settings.local.json
  rc=0; (cd "$r" && bash "$setup" --claude-repo >/dev/null 2>&1) || rc=$?
  [[ $rc -eq 2 && "$(cat "$r/.claude/settings.local.json")" == "{}" ]] && ok "a tracked settings.local.json is refused (2), unchanged" \
    || error "claude-tracked: rc=$rc"

  # A user's own exclude line survives install and uninstall.
  r="$(new_repo claude-user-exclude)"
  printf '/.claude/settings.local.json*\n' >> "$r/.git/info/exclude"
  exclude_before="$(cat "$r/.git/info/exclude")"
  (cd "$r" && bash "$setup" --claude-repo >/dev/null 2>&1 && bash "$setup" --claude-repo --uninstall >/dev/null 2>&1) || error "claude-user-exclude: failed"
  [[ "$(cat "$r/.git/info/exclude")" == "$exclude_before" ]] && ok "a user's own exclude line survives" \
    || error "claude-user-exclude: exclude now: $(tr '\n' '|' < "$r/.git/info/exclude")"

  # A committed symlink must not redirect the write outside the repository.
  mkdir -p "$tmp/outside-target"
  ln -s "$tmp/outside-target" "$tmp/link-probe" 2>/dev/null
  if [[ -L "$tmp/link-probe" ]]; then
    r="$(new_repo claude-symlink)"
    ln -s "$tmp/outside-target" "$r/.claude"
    rc=0; (cd "$r" && bash "$setup" --claude-repo >/dev/null 2>&1) || rc=$?
    [[ $rc -eq 2 && ! -e "$tmp/outside-target/settings.local.json" ]] && ok "a symlinked .claude is refused (2), nothing written outside" \
      || error "claude-symlink: rc=$rc, outside: $(ls -A "$tmp/outside-target" | tr '\n' ' ')"
    r="$(new_repo claude-file-symlink)"
    mkdir -p "$r/.claude"; : > "$tmp/outside-file.json"
    ln -s "$tmp/outside-file.json" "$r/.claude/settings.local.json"
    rc=0; (cd "$r" && bash "$setup" --claude-repo >/dev/null 2>&1) || rc=$?
    [[ $rc -eq 2 && ! -s "$tmp/outside-file.json" ]] && ok "a symlinked settings.local.json is refused (2)" \
      || error "claude-file-symlink: rc=$rc"
  else
    note "SKIP: ln -s makes no symlink here (Git Bash without symlink support); symlink cases not checked"
  fi
  unset SCRIPT_HELPERS_OWNERS
else
  note "SKIP: python3 not available, --claude-repo not checked"
fi

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
