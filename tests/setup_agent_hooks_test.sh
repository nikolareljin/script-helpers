#!/usr/bin/env bash
# SCRIPT: setup_agent_hooks_test.sh
# DESCRIPTION: setup-hooks.sh --agent-repo / --agent for Codex, Gemini, Copilot CLI and Cursor: install, reinstall, uninstall, other hooks kept, nothing tracked changed, and agent_hook.sh refusing in each agent's own terms.
# USAGE: bash tests/setup_agent_hooks_test.sh
# ----------------------------------------------------
# Throwaway HOME and a stand-in gitleaks. The payloads are each agent's
# documented shape; the real agents are run once by hand (see the PR).
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[setup_agent_hooks_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[setup_agent_hooks_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }
PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info[0] != 3)' 2>/dev/null && { PY="$c"; break; }; done
[[ -n "$PY" ]] || { note "SKIP: Python 3 not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_DATA_HOME="$tmp/home/.local/share"
export LOCALAPPDATA="$XDG_DATA_HOME"
export GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset SCRIPT_HELPERS_OWNERS CODEX_HOME COPILOT_HOME
mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"
git config --global script-helpers.owners example-owner
printf 'private\tns\tzzq-private-thing\t-\t\n' > "$tmp/names.tsv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/gl-clean"; chmod +x "$tmp/gl-clean"
export PRIVATE_NAMES_FILE="$tmp/names.tsv" PRIVATE_NAMES_AUTO_REFRESH=false GITLEAKS_BIN="$tmp/gl-clean"
cd "$tmp" || exit 1
setup="$root_dir/scripts/setup-hooks.sh"
adapter="$XDG_DATA_HOME/script-helpers/agent-repo-hooks/scripts/agent-hooks/agent_hook.sh"
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

rel_of() { case "$1" in codex) echo .codex/hooks.json ;; gemini) echo .gemini/settings.json ;; copilot) echo .github/hooks/script-helpers.json ;; cursor) echo .cursor/hooks.json ;; esac; }
new_repo() {
  local r="$tmp/$1"
  git init -q "$r"; git -C "$r" remote add origin "https://github.com/example-owner/$1.git"
  echo "$r"
}
# count_ours <file>: our entries (a Copilot entry names the hook twice, for bash and powershell).
count_ours() { "$PY" -c 'import sys; print(sum(1 for l in open(sys.argv[1]) if "agent_hook.sh" in l and "\"powershell\"" not in l))' "$1"; }
field() { (cd "$1" && bash "$setup" --status --porcelain 2>/dev/null) | tr '\t' '\n' | sed -n "s/^$2=//p"; }

# 1. Install for all four: each file holds one entry, git status is clean, the
#    files are excluded, .git/config gains only the created markers.
r="$(new_repo all)"
before_status="$(git -C "$r" status --porcelain)"
(cd "$r" && bash "$setup" --agent-repo all >/dev/null 2>&1) || error "all: install failed"
for a in codex gemini copilot cursor; do
  f="$r/$(rel_of "$a")"
  [[ -f "$f" && "$(count_ours "$f")" == 1 ]] && ok "$a: one entry in $(rel_of "$a")" || error "$a: entry missing or duplicated"
done
[[ "$(git -C "$r" status --porcelain)" == "$before_status" ]] && ok "git status unchanged (files excluded)" || error "all: git status changed: $(git -C "$r" status --porcelain | tr '\n' ' ')"
[[ "$(field "$r" agents)" == "codex,gemini,copilot,cursor" ]] && ok "--status --porcelain: agents=codex,gemini,copilot,cursor" || error "all: agents='$(field "$r" agents)'"

# 2. A second install changes nothing; uninstall removes everything it made.
(cd "$r" && bash "$setup" --agent-repo all >/dev/null 2>&1)
dup=0; for a in codex gemini copilot cursor; do [[ "$(count_ours "$r/$(rel_of "$a")")" == 1 ]] || dup=1; done
[[ $dup -eq 0 ]] && ok "reinstall adds no second entry" || error "reinstall duplicated an entry"
(cd "$r" && bash "$setup" --agent-repo all --uninstall >/dev/null 2>&1) || error "all: uninstall failed"
left="$(cd "$r" && ls -A | grep -v '^\.git$' | tr '\n' ' ')"
[[ -z "$left" ]] && ok "uninstall removes the files and directories it created" || error "all: left behind: $left"
[[ -z "$(git -C "$r" config --local --get-regexp '^script-helpers\.' 2>/dev/null)" ]] && ok "uninstall removes its .git/config keys" || error "all: keys left"
grep -q 'agent-repo' "$r/.git/info/exclude" && error "all: exclude lines left" || ok "uninstall removes its exclude lines"

# 3. Another hook in the same file stays through install and uninstall.
r="$(new_repo foreign)"
mkdir -p "$r/.cursor" "$r/.gemini"
printf '{"version":1,"hooks":{"beforeShellExecution":[{"command":"./their-guard.sh"}],"afterFileEdit":[{"command":"./fmt.sh"}]}}\n' > "$r/.cursor/hooks.json"
printf '{"theme":"dark","hooks":{"BeforeTool":[{"matcher":"write_file","hooks":[{"type":"command","command":"./lint.sh"}]}]}}\n' > "$r/.gemini/settings.json"
(cd "$r" && bash "$setup" --agent-repo cursor,gemini >/dev/null 2>&1) || error "foreign: install failed"
grep -q their-guard "$r/.cursor/hooks.json" && grep -q fmt.sh "$r/.cursor/hooks.json" && grep -q lint.sh "$r/.gemini/settings.json" \
  && ok "existing hooks kept on install" || error "foreign: an existing hook was lost on install"
(cd "$r" && bash "$setup" --agent-repo cursor,gemini --uninstall >/dev/null 2>&1) || error "foreign: uninstall failed"
[[ -f "$r/.cursor/hooks.json" ]] && grep -q their-guard "$r/.cursor/hooks.json" && grep -q '"theme"' "$r/.gemini/settings.json" \
  && ! grep -q agent_hook.sh "$r/.cursor/hooks.json" "$r/.gemini/settings.json" \
  && ok "uninstall removes only ours; the user's files stay" || error "foreign: uninstall damaged or deleted a user file"
ls "$r/.git/script-helpers/cursor-backups"/hooks.json.bak-* >/dev/null 2>&1 && ok "backups kept under .git/script-helpers" || error "foreign: no backup under .git/script-helpers"
[[ -z "$(ls "$r/.cursor" | grep bak)" ]] && ok "no backup left in the work tree" || error "foreign: backup in the work tree"

# 4. Refusals: a tracked file, a symlinked directory, an unknown agent, claude, bad combinations.
r="$(new_repo refuse)"
mkdir -p "$r/.codex"; printf '{}\n' > "$r/.codex/hooks.json"
git -C "$r" add .codex/hooks.json
(cd "$r" && bash "$setup" --agent-repo codex >/dev/null 2>&1); rc=$?
[[ $rc -eq 2 && "$(cat "$r/.codex/hooks.json")" == "{}" ]] && ok "a tracked hook file is refused (2), unchanged" || error "refuse tracked: rc=$rc"
mkdir -p "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$r/.cursor" 2>/dev/null
if [[ -L "$r/.cursor" ]]; then
  (cd "$r" && bash "$setup" --agent-repo cursor >/dev/null 2>&1); rc=$?
  [[ $rc -eq 2 && -z "$(ls -A "$tmp/elsewhere")" ]] && ok "a symlinked .cursor is refused (2), nothing written outside" || error "refuse symlink: rc=$rc"
else
  note "SKIP: ln -s makes no symlink here"
fi
for bad in "--agent-repo nope" "--agent-repo claude" "--agent-repo codex --global" "--agent-repo" "--agent codex --agent-repo gemini"; do
  # shellcheck disable=SC2086
  (cd "$r" && bash "$setup" $bad >/dev/null 2>&1); rc=$?
  [[ $rc -eq 2 ]] && ok "refused (2): $bad" || error "not refused: $bad (rc=$rc)"
done
git config --global --unset script-helpers.owners
(cd "$r" && bash "$setup" --agent-repo gemini >/dev/null 2>&1); rc=$?
[[ $rc -eq 2 && ! -e "$r/.gemini" ]] && ok "no owners: refused (2), nothing written" || error "no owners: rc=$rc"
git config --global script-helpers.owners example-owner

# 5. The adapter answers each agent in its own terms: exit 2 plus its deny JSON
#    for a private name, exit 0 and no output for an ordinary command.
r="$(new_repo adapter)"
(cd "$r" && bash "$setup" --agent-repo all >/dev/null 2>&1) || error "adapter: install failed"
cwd="$(native "$r")"
payload() {
  local a="$1" cmd="$2"
  case "$a" in
    codex)   printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$cwd" "$cmd" ;;
    gemini)  printf '{"cwd":"%s","hook_event_name":"BeforeTool","tool_name":"run_shell_command","tool_input":{"command":"%s"}}' "$cwd" "$cmd" ;;
    copilot) printf '{"cwd":"%s","toolName":"bash","toolArgs":{"command":"%s"}}' "$cwd" "$cmd" ;;
    cursor)  printf '{"cwd":"%s","command":"%s","sandbox":false}' "$cwd" "$cmd" ;;
  esac
}
deny_key() { case "$1" in codex) echo hookSpecificOutput ;; gemini) echo decision ;; copilot) echo permissionDecision ;; cursor) echo permission ;; esac; }
for a in codex gemini copilot cursor; do
  out="$(payload "$a" "echo zzq-private-thing" | bash "$adapter" "$a" 2>/dev/null)"; rc=$?
  key="$(printf '%s' "$out" | "$PY" -c 'import json,sys; print(list(json.loads(sys.stdin.read()).keys())[0])' 2>/dev/null)"
  [[ $rc -eq 2 && "$key" == "$(deny_key "$a")" ]] && ok "$a: a private name is refused (2) with its deny JSON" || error "$a: rc=$rc key='$key' out=$out"
  out="$(payload "$a" "ls -la" | bash "$adapter" "$a" 2>/dev/null)"; rc=$?
  [[ $rc -eq 0 && -z "$out" ]] && ok "$a: ls passes (0), no output" || error "$a: ls rc=$rc out=$out"
done
# No cwd in the payload: the directory the agent ran the hook from is used.
out="$(cd "$r" && printf '{"command":"echo zzq-private-thing"}' | bash "$adapter" cursor 2>/dev/null)"; rc=$?
[[ $rc -eq 2 ]] && ok "no cwd in the payload: the hook's own directory is used (refused)" || error "no cwd: rc=$rc"
grep -q '"powershell": "& ' "$r/.github/hooks/script-helpers.json" && ok "copilot: a powershell command too (Copilot runs that one on Windows)" || error "copilot: no powershell command"
# Copilot's toolArgs as JSON text, not an object.
out="$(printf '{"cwd":"%s","toolName":"bash","toolArgs":"{\\"command\\":\\"echo zzq-private-thing\\"}"}' "$cwd" | bash "$adapter" copilot 2>/dev/null)"; rc=$?
[[ $rc -eq 2 ]] && ok "copilot: toolArgs given as JSON text is read too" || error "copilot text args: rc=$rc"
# A check that cannot run refuses: Cursor would let a command through on any other exit.
mkdir -p "$tmp/broken/scripts/agent-hooks"; cp "$adapter" "$tmp/broken/scripts/agent-hooks/"
out="$(payload cursor "ls" | bash "$tmp/broken/scripts/agent-hooks/agent_hook.sh" cursor 2>/dev/null)"; rc=$?
[[ $rc -eq 2 && "$out" == *'"deny"'* ]] && ok "the check missing: refused (2), deny JSON" || error "broken: rc=$rc out=$out"
(printf '{}' | bash "$adapter" claude >/dev/null 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "the adapter refuses an unknown agent (2)" || error "adapter unknown agent rc=$rc"

# 5b. A json.py in the project (the agents run hooks from there) never runs
#     inside the check: every Python call is isolated (-I).
printf 'import os\nopen(os.path.join(os.path.dirname(os.path.abspath(__file__)), "PWNED"), "a").write("x")\n' > "$r/json.py"
cp "$r/json.py" "$r/re.py"
(cd "$r" && payload cursor "ls" | bash "$adapter" cursor >/dev/null 2>&1)
(cd "$r" && payload codex "ls" | bash "$root_dir/scripts/claude-hooks/pretooluse_private_names.sh" >/dev/null 2>&1)
[[ ! -e "$r/PWNED" ]] && ok "a json.py or re.py in the project does not run inside the hooks" || error "planted module ran inside a hook"
rm -f "$r/json.py" "$r/re.py" "$r/PWNED"

# 5c. A payload that cannot be judged is refused, not passed.
for bad in "" "echo zzq-private-thing" "[1]" "{"; do
  (cd "$r" && printf '%s' "$bad" | bash "$adapter" cursor >/dev/null 2>&1); rc=$?
  [[ $rc -eq 2 ]] && ok "unreadable payload refused (2): '${bad:-<empty>}'" || error "unreadable payload passed: '$bad' rc=$rc"
done

# 5d. Linked worktrees share .git/config and .git/info/exclude: an uninstall in
#     one must not forget or un-exclude the file another still has.
w="$(new_repo wt-main)"
git -C "$w" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$w" worktree add -q "$tmp/wt-linked"
for kind in agent claude; do
  if [[ $kind == agent ]]; then inst=(--agent-repo cursor); rel=.cursor/hooks.json
  else inst=(--claude-repo); rel=.claude/settings.local.json; fi
  (cd "$w" && bash "$setup" "${inst[@]}" >/dev/null 2>&1) || error "$kind wt: main install failed"
  (cd "$tmp/wt-linked" && bash "$setup" "${inst[@]}" >/dev/null 2>&1) || error "$kind wt: linked install failed"
  (cd "$tmp/wt-linked" && bash "$setup" "${inst[@]}" --uninstall >/dev/null 2>&1) || error "$kind wt: linked uninstall failed"
  [[ ! -e "$tmp/wt-linked/$rel" && -z "$(git -C "$w" status --porcelain)" ]] \
    && ok "$kind: uninstall in a linked worktree keeps the main one's file excluded" || error "$kind wt: main now shows: $(git -C "$w" status --porcelain | tr '\n' ' ')"
  (cd "$w" && bash "$setup" "${inst[@]}" --uninstall >/dev/null 2>&1)
  [[ ! -e "$w/$rel" && ! -e "$w/$(dirname "$rel")" ]] && ok "$kind: the main worktree's uninstall still removes what it created" || error "$kind wt: main left $(ls -A "$w" | tr '\n' ' ')"
done

# 6. User level: --agent all writes the four user files; uninstall removes them and the copy.
(cd "$tmp" && bash "$setup" --agent all >/dev/null 2>&1) || error "user: install failed"
n=0
for f in "$HOME/.codex/hooks.json" "$HOME/.gemini/settings.json" "$HOME/.copilot/hooks/script-helpers.json" "$HOME/.cursor/hooks.json"; do
  [[ -f "$f" && "$(count_ours "$f")" == 1 ]] && n=$((n+1))
done
[[ $n -eq 4 ]] && ok "--agent all: our entry in the four user files" || error "user: $n of 4 files hold our entry"
(cd "$tmp" && bash "$setup" --agent codex --uninstall >/dev/null 2>&1)
[[ -d "$XDG_DATA_HOME/script-helpers/agent-hooks" ]] && ok "uninstalling one agent keeps the copy the others use" || error "user: copy removed while others use it"
(cd "$tmp" && bash "$setup" --agent all --uninstall >/dev/null 2>&1)
[[ ! -d "$XDG_DATA_HOME/script-helpers/agent-hooks" ]] && ! grep -rq --exclude='*.bak-*' agent_hook.sh "$HOME/.codex" "$HOME/.gemini" "$HOME/.copilot" "$HOME/.cursor" 2>/dev/null \
  && ok "--agent all --uninstall removes every entry and the copy" || error "user: entries or copy left"

if [[ $failures -gt 0 ]]; then echo "[setup_agent_hooks_test] $failures failure(s)" >&2; exit 1; fi
note "all passed"
