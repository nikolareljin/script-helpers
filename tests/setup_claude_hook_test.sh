#!/usr/bin/env bash
# SCRIPT: setup_claude_hook_test.sh
# DESCRIPTION: Tests for setup-hooks.sh --claude, --all, --uninstall, --status, --doctor and --managed.
# USAGE: ./tests/setup_claude_hook_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/setup_claude_hook_test.sh
# ----------------------------------------------------
#
# Everything runs against a throwaway HOME, CLAUDE_CONFIG_DIR, XDG_*,
# LOCALAPPDATA and GIT_CONFIG_GLOBAL, so the real settings are never read or
# written. Owners are placeholders.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
SETUP="$root_dir/scripts/setup-hooks.sh"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"; fi' EXIT

failures=0
note()  { echo "[setup_claude_hook_test] $*"; }
error() { echo "[setup_claude_hook_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then note "SKIP: no Python 3"; exit 0; fi

ON_WINDOWS=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=true ;; esac
native() { if [[ "$ON_WINDOWS" == true ]]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

export HOME="$tmp/home" CLAUDE_CONFIG_DIR="$tmp/claude" XDG_DATA_HOME="$tmp/data" \
       XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" \
       GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
       SCRIPT_HELPERS_MANAGED_SETTINGS="$tmp/managed/managed-settings.json"
if [[ "$ON_WINDOWS" == true ]]; then
  LOCALAPPDATA="$(cygpath -w "$tmp/localappdata")"; export LOCALAPPDATA
  data_dir="$tmp/localappdata"
else
  export LOCALAPPDATA="$tmp/localappdata"   # ignored off Windows
  data_dir="$tmp/data"
fi
unset SCRIPT_HELPERS_OWNERS SCRIPT_HELPERS_HOOKS_HOME PRIVATE_NAMES_FILE SENSITIVE_TERMS_FILE 2>/dev/null || true
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$tmp/bin"
: > "$GIT_CONFIG_GLOBAL"
# Out of any repository: git config would otherwise read this checkout.
cd "$tmp" || exit 1
# A stand-in gitleaks that finds nothing: the hook refuses without one, and
# the scanner itself is not under test here.
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/gitleaks"; chmod +x "$tmp/bin/gitleaks"
# A stand-in claude: the version decides whether onFailure is written.
fake_claude() { printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "$1" > "$tmp/bin/claude"; chmod +x "$tmp/bin/claude"; }
fake_claude 2.1.200
export PATH="$tmp/bin:$PATH"

# A name list: without one the hook cannot check, and refuses every command.
mkdir -p "$XDG_CONFIG_HOME/script-helpers"
printf '# generated: 2026-10-11 source: test\n# visibility\tnamespace\tname\tcode\tflags\nprivate\texample\tzzqsecretbox\tR-901\t\n' \
  > "$XDG_CONFIG_HOME/script-helpers/private-names.tsv"
settings="$CLAUDE_CONFIG_DIR/settings.json"
hook_copy="$data_dir/script-helpers/claude-hooks/scripts/claude-hooks/pretooluse_private_names.sh"

# jq_py <file> <python expression over d>: prints the result. The expressions
# are the literals in this file, never input.
jq_py() { "$PY" -c 'import json,sys; d=json.loads(open(sys.argv[1],encoding="utf-8-sig").read()); print(eval(sys.argv[2]))' "$(native "$1")" "$2"; }
ours_count() { jq_py "$1" 'sum(1 for g in d.get("hooks",{}).get("PreToolUse",[]) for h in g.get("hooks",[]) if h.get("command","").rstrip(chr(34)).endswith("pretooluse_private_names.sh"))'; }
run() { bash "$SETUP" "$@" >"$tmp/out" 2>&1; echo $?; }

# 1. No owners: refused, nothing written.
rc="$(run --claude)"
[[ "$rc" == 2 && ! -e "$settings" ]] && grep -q 'no owners configured' "$tmp/out" \
  && ok "no owners -> exit 2, settings.json not created" \
  || error "no owners: rc=$rc $(cat "$tmp/out")"

git config --global script-helpers.owners example-owner

# 2. Existing settings: other keys, an unrelated user hook, an older entry.
cat > "$settings" <<'EOF'
{
  "model": "placeholder-model",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "bash /old/place/scripts/claude-hooks/pretooluse_private_names.sh"},
        {"type": "command", "command": "/usr/local/bin/my-own-hook.sh"}
      ]}
    ],
    "Stop": [{"hooks": [{"type": "command", "command": "echo done"}]}]
  }
}
EOF
rc="$(run --claude)"
if [[ "$rc" == 0 ]]; then
  [[ "$(ours_count "$settings")" == 1 ]] && ok "one entry after install (the older one replaced)" || error "entries: $(ours_count "$settings")"
  [[ "$(jq_py "$settings" 'd["model"]')" == placeholder-model && "$(jq_py "$settings" 'd["permissions"]["allow"][0]')" == "Bash(ls:*)" ]] \
    && ok "other keys kept" || error "other keys lost: $(cat "$settings")"
  grep -q 'my-own-hook.sh' "$settings" && grep -q '"echo done"' "$settings" \
    && ok "the user's own hooks kept" || error "user hooks lost: $(cat "$settings")"
  [[ "$(jq_py "$settings" '[h for g in d["hooks"]["PreToolUse"] for h in g["hooks"] if "pretooluse" in h["command"]][0]["timeout"]')" == 60 ]] \
    && [[ "$(jq_py "$settings" '[(g["matcher"], h["shell"]) for g in d["hooks"]["PreToolUse"] for h in g["hooks"] if "pretooluse" in h["command"]][0]')" == "('Bash', 'bash')" ]] \
    && ok "matcher Bash, timeout 60, shell bash" || error "entry fields: $(cat "$settings")"
  cmd="$(jq_py "$settings" '[h for g in d["hooks"]["PreToolUse"] for h in g["hooks"] if "pretooluse" in h["command"]][0]["command"]')"
  [[ "$cmd" == "bash \"$(native "$data_dir")/script-helpers/claude-hooks/scripts/claude-hooks/pretooluse_private_names.sh\"" && -f "$hook_copy" ]] \
    && ok "the entry runs the installed copy, which exists" || error "command: $cmd"
  ls "$CLAUDE_CONFIG_DIR"/settings.json.bak-* >/dev/null 2>&1 && ok "a backup was written" || error "no backup"
else
  error "install: rc=$rc $(cat "$tmp/out")"
fi

# 3. Idempotent.
cp "$settings" "$tmp/before.json"
rc="$(run --claude)"
[[ "$rc" == 0 ]] && cmp -s "$settings" "$tmp/before.json" \
  && ok "a second run changes nothing" || error "re-run: rc=$rc; $(diff "$tmp/before.json" "$settings")"

# 4. --status and --doctor.
rc="$(run --status)"
[[ "$rc" == 0 ]] && grep -q 'claude hook (user)' "$tmp/out" && grep -q 'owners    ok' "$tmp/out" \
  && ok "--status shows the hook and the prerequisites" || error "--status: $(cat "$tmp/out")"
rc="$(run --doctor)"
[[ "$rc" == 0 ]] && grep -q 'ok .*must be refused.*exit 2' "$tmp/out" && grep -q 'ok .*must pass.*exit 0' "$tmp/out" \
  && ok "--doctor: both probes behave, with timings" || error "--doctor: rc=$rc $(cat "$tmp/out")"
# A hook copy that went missing fails open; the doctor must say so.
mv "$hook_copy" "$hook_copy.gone"
rc="$(run --doctor)"
[[ "$rc" == 1 ]] && grep -q 'does not exist' "$tmp/out" \
  && ok "--doctor reports a missing hook copy" || error "--doctor missing copy: rc=$rc $(cat "$tmp/out")"
mv "$hook_copy.gone" "$hook_copy"

# 5. Uninstall leaves the rest.
rc="$(run --claude --uninstall)"
[[ "$rc" == 0 && "$(ours_count "$settings")" == 0 ]] && grep -q 'my-own-hook.sh' "$settings" \
  && [[ "$(jq_py "$settings" 'd["model"]')" == placeholder-model && ! -e "$data_dir/script-helpers/claude-hooks" ]] \
  && ok "uninstall removes only our entry and the copy" || error "uninstall: rc=$rc $(cat "$settings")"

# 6. Invalid JSON: refused, untouched, nothing copied.
printf '{"model": "x",\n' > "$settings"
cp "$settings" "$tmp/bad.json"
rc="$(run --claude)"
[[ "$rc" == 3 ]] && cmp -s "$settings" "$tmp/bad.json" && [[ ! -e "$hook_copy" ]] \
  && ok "invalid JSON -> exit 3, file untouched, nothing installed" || error "invalid JSON: rc=$rc $(cat "$tmp/out")"

# 7. CRLF and a BOM: read, merged, line endings kept.
printf '\xef\xbb\xbf{\r\n  "model": "crlf"\r\n}\r\n' > "$settings"
rc="$(run --claude)"
[[ "$rc" == 0 && "$(ours_count "$settings")" == 1 && "$(jq_py "$settings" 'd["model"]')" == crlf ]] \
  && [[ "$(grep -c $'\r$' "$settings")" -gt 3 && "$(grep -vc $'\r$' "$settings")" == 0 ]] \
  && ok "a CRLF settings file with a BOM is merged and stays CRLF" || error "CRLF: rc=$rc $(cat "$tmp/out")"
bash "$SETUP" --claude --uninstall >/dev/null 2>&1
rm -f "$settings"

# 8. No settings.json yet: created.
rc="$(run --claude)"
[[ "$rc" == 0 && "$(ours_count "$settings")" == 1 ]] && ok "a missing settings.json is created" || error "fresh: rc=$rc $(cat "$tmp/out")"
bash "$SETUP" --claude --uninstall >/dev/null 2>&1

# 9. --all: the global git hooks and the Claude hook; --all --uninstall undoes both.
git config --global core.hooksPath /some/previous/path
prev_path="$(git config --global core.hooksPath)"   # Git Bash rewrites it on Windows
rc="$(run --all)"
[[ "$rc" == 0 && "$(git config --global core.hooksPath)" == "$(native "$data_dir")/script-helpers/git-hooks/hooks" && "$(ours_count "$settings")" == 1 ]] \
  && ok "--all installs both" || error "--all: rc=$rc hooksPath=$(git config --global core.hooksPath) $(cat "$tmp/out")"
rc="$(run --all --uninstall)"
[[ "$rc" == 0 && "$(git config --global core.hooksPath)" == "$prev_path" && "$(ours_count "$settings")" == 0 ]] \
  && ok "--all --uninstall restores both" || error "--all --uninstall: rc=$rc $(cat "$tmp/out")"

# 10a. onFailure: written for Claude Code 2.1.295+, warned about before.
onfailure_of() { jq_py "$settings" '[h.get("onFailure","") for g in d["hooks"]["PreToolUse"] for h in g["hooks"] if "pretooluse" in h["command"]][0]'; }
rc="$(run --claude)"
[[ "$rc" == 0 && -z "$(onfailure_of)" ]] && grep -q 'WARN: Claude Code older than 2.1.295' "$tmp/out" \
  && ok "Claude Code 2.1.200: no onFailure, and a warning" || error "old claude: rc=$rc $(cat "$tmp/out")"
rc="$(run --status)"
grep -q 'WARN: no onFailure' "$tmp/out" && ok "--status warns that a timeout fails open" || error "--status onFailure: $(cat "$tmp/out")"
fake_claude 2.1.295
rc="$(run --claude)"
[[ "$rc" == 0 && "$(onfailure_of)" == block && "$(ours_count "$settings")" == 1 ]] \
  && ok "Claude Code 2.1.295: onFailure block written, still one entry" || error "new claude: rc=$rc $(cat "$settings")"
rc="$(run --status)"
grep -q 'onFailure: block' "$tmp/out" && ok "--status reports onFailure block" || error "--status block: $(cat "$tmp/out")"
fake_claude 2.2.0
cp "$settings" "$tmp/before.json"; run --claude >/dev/null
cmp -s "$settings" "$tmp/before.json" && ok "a re-run with onFailure changes nothing" || error "onFailure re-run changed the file"
bash "$SETUP" --claude --uninstall >/dev/null 2>&1
fake_claude 2.1.200

# 10. Bad combinations.
[[ "$(run --uninstall)" == 2 ]] && ok "--uninstall alone -> exit 2" || error "--uninstall alone accepted"
[[ "$(run --claude --managed)" == 2 ]] && ok "--claude --managed -> exit 2" || error "--claude --managed accepted"

# 11. --managed: refused without write access, written with it.
mkdir -p "$tmp/managed"
if [[ "$ON_WINDOWS" != true && "$(id -u)" != 0 ]]; then
  chmod 555 "$tmp/managed"
  rc="$(run --managed)"
  [[ "$rc" == 2 && ! -e "$SCRIPT_HELPERS_MANAGED_SETTINGS" ]] && grep -q 'no write access' "$tmp/out" \
    && ok "--managed without write access -> exit 2, no sudo" || error "--managed unwritable: rc=$rc $(cat "$tmp/out")"
  chmod 755 "$tmp/managed"
fi
rc="$(run --managed)"
[[ "$rc" == 0 && "$(ours_count "$SCRIPT_HELPERS_MANAGED_SETTINGS")" == 1 && -f "$tmp/managed/script-helpers/scripts/claude-hooks/pretooluse_private_names.sh" ]] \
  && ok "--managed writes the managed file and a copy beside it" || error "--managed: rc=$rc $(cat "$tmp/out")"
rc="$(run --managed --uninstall)"
[[ "$rc" == 0 && "$(ours_count "$SCRIPT_HELPERS_MANAGED_SETTINGS")" == 0 && ! -e "$tmp/managed/script-helpers" ]] \
  && ok "--managed --uninstall removes it" || error "--managed --uninstall: rc=$rc $(cat "$tmp/out")"

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
