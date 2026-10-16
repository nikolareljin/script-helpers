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
[[ "$rc" == 0 ]] && grep -q 'ok .*private name from your list.*exit 2' "$tmp/out" \
  && grep -q 'ok .*personal identifier.*exit 2' "$tmp/out" \
  && grep -q 'ok .*--no-verify.*exit 2' "$tmp/out" && grep -q 'ok .*must pass.*exit 0' "$tmp/out" \
  && ok "--doctor: all four probes behave, with timings" || error "--doctor: rc=$rc $(cat "$tmp/out")"
grep -q 'zzqsecretbox' "$tmp/out" && error "--doctor printed the private name it probed with"
# Without gitleaks every command in scope is refused as "could not check":
# the harmless probe fails and the hook's reason is shown.
rc="$(GITLEAKS_BIN="$tmp/no-gitleaks" run --doctor)"
[[ "$rc" == 1 ]] && grep -q 'FAIL .*must pass.*exit 2 (want 0)' "$tmp/out" && grep -q 'hook: .*gitleaks is not installed' "$tmp/out" \
  && ok "--doctor: no gitleaks is a failure, with the hook's reason" || error "--doctor no gitleaks: rc=$rc $(cat "$tmp/out")"
# Refused for the wrong reason: a name check that cannot run ("no list")
# refuses the name probe too, and ls passes (the prefilter skips it). Exit 2
# alone would read as a working gate.
gate_copy="$data_dir/script-helpers/claude-hooks/scripts/check_private_names.sh"
mv "$gate_copy" "$gate_copy.real"
printf '#!/usr/bin/env bash\ncat >/dev/null; echo "No private-name list at: x" >&2; exit 2\n' > "$gate_copy"
rc="$(run --doctor)"
[[ "$rc" == 1 ]] && grep -q 'FAIL .*private name from your list.*refused, but for another reason' "$tmp/out" \
  && grep -q 'hook: .*NOT checked' "$tmp/out" && grep -q 'ok .*must pass' "$tmp/out" \
  && ok "--doctor: a refusal for another reason is a failure" || error "--doctor wrong reason: rc=$rc $(cat "$tmp/out")"
mv "$gate_copy.real" "$gate_copy"
# A name check that never fires: the hook still refuses --no-verify, but the
# name probe must fail.
mv "$gate_copy" "$gate_copy.real"; printf '#!/usr/bin/env bash\ncat >/dev/null; exit 0\n' > "$gate_copy"
rc="$(run --doctor)"
[[ "$rc" == 1 ]] && grep -q 'FAIL .*private name from your list.*exit 0 (want 2)' "$tmp/out" \
  && ok "--doctor: a name check that never fires is a failure" || error "--doctor dead name check: rc=$rc $(cat "$tmp/out")"
mv "$gate_copy.real" "$gate_copy"
# No usable name in the list: said so, not a pass.
mv "$XDG_CONFIG_HOME/script-helpers/private-names.tsv" "$tmp/names.off"
rc="$(run --doctor)"
[[ "$rc" == 1 ]] && grep -q 'no usable private name' "$tmp/out" && grep -q 'names     MISSING' "$tmp/out" \
  && ok "--doctor: no name list is reported as missing, and fails" || error "--doctor no list: rc=$rc $(cat "$tmp/out")"
# The probe name is read as the gate reads the list: no header means the v1
# column order, and a name the machine allowlist lets through is never used.
printf 'private\texample\tzzqallowedbox\tR-903\t\nprivate\texample\tzzqsecretbox\tR-901\t\n' \
  > "$XDG_CONFIG_HOME/script-helpers/private-names.tsv"
printf 'zzqallowedbox\n' > "$XDG_CONFIG_HOME/script-helpers/private-names-allow"
rc="$(run --doctor)"
[[ "$rc" == 0 ]] && grep -q 'ok .*private name from your list.*exit 2' "$tmp/out" \
  && ok "--doctor: a header-less list works, and an allowlisted name is skipped" || error "--doctor v1/allow: rc=$rc $(cat "$tmp/out")"
rm -f "$XDG_CONFIG_HOME/script-helpers/private-names-allow"
mv "$tmp/names.off" "$XDG_CONFIG_HOME/script-helpers/private-names.tsv"
# A hook copy that went missing fails open; the doctor must say so.
mv "$hook_copy" "$hook_copy.gone"
rc="$(run --doctor)"
[[ "$rc" == 1 ]] && grep -q 'does not exist' "$tmp/out" \
  && ok "--doctor reports a missing hook copy" || error "--doctor missing copy: rc=$rc $(cat "$tmp/out")"
mv "$hook_copy.gone" "$hook_copy"
# A qualified-only name (also public somewhere) is refused only as
# namespace/name; the probe must use that form, or a working hook fails it.
cp "$XDG_CONFIG_HOME/script-helpers/private-names.tsv" "$tmp/names.keep"
printf '# visibility\tnamespace\tname\tcode\tflags\nprivate\texample\tzzqsharedbox\tR-904\tqualified-only\npublic\tother\tzzqsharedbox\t-\t\nprivate\texample\tzzqsecretbox\tR-901\t\n' \
  > "$XDG_CONFIG_HOME/script-helpers/private-names.tsv"
rc="$(run --doctor)"
[[ "$rc" == 0 ]] && grep -q 'ok .*private name from your list.*exit 2' "$tmp/out" \
  && ok "--doctor: a qualified-only name is probed as namespace/name" || error "--doctor qualified-only: rc=$rc $(cat "$tmp/out")"
grep -q 'zzqsharedbox' "$tmp/out" && error "--doctor printed the qualified name it probed with"
mv "$tmp/names.keep" "$XDG_CONFIG_HOME/script-helpers/private-names.tsv"

# 4b. Where the entry points. ok: the installed copy. stale: another copy, such
# as a checkout, which a branch switch removes. broken: nothing there.
porcelain_user() { bash "$SETUP" --status --porcelain --claude 2>/dev/null | tr '\t' '\n' | sed -n 's/^claude_user=//p'; }
[[ "$(porcelain_user)" == ok ]] && ok "--status --porcelain --claude: ok for the installed copy" || error "porcelain user: $(bash "$SETUP" --status --porcelain --claude 2>&1)"
cp -R "$data_dir/script-helpers/claude-hooks" "$tmp/checkout"
cp "$settings" "$tmp/settings.keep"
point_entry() { "$PY" -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p))
for g in d["hooks"]["PreToolUse"]:
    for h in g["hooks"]:
        if h["command"].rstrip(chr(34)).endswith("pretooluse_private_names.sh"): h["command"]="bash "+chr(34)+sys.argv[2]+chr(34)
json.dump(d,open(p,"w"),indent=2)' "$(native "$settings")" "$(native "$1")"; }
point_entry "$tmp/checkout/scripts/claude-hooks/pretooluse_private_names.sh"
[[ "$(porcelain_user)" == stale ]] && ok "an entry into another copy: stale" || error "stale porcelain: $(bash "$SETUP" --status --porcelain --claude 2>&1)"
rc="$(run --status)"
grep -q 'STALE: the entry runs' "$tmp/out" && ok "--status says STALE and how to fix it" || error "stale status: $(cat "$tmp/out")"
rc="$(run --doctor)"
[[ "$rc" == 1 ]] && grep -q 'FAIL: the hook in settings is not the installed copy' "$tmp/out" \
  && ok "--doctor fails on a stale entry" || error "--doctor stale: rc=$rc $(cat "$tmp/out")"
# Other forms of the same entry: single quotes, $HOME/, surrounding spaces.
cp "$tmp/settings.keep" "$settings"
set_command() { "$PY" -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p))
for g in d["hooks"]["PreToolUse"]:
    for h in g["hooks"]:
        if "pretooluse_private_names.sh" in h["command"]: h["command"]=sys.argv[2]
json.dump(d,open(p,"w"),indent=2)' "$(native "$settings")" "$1"; }
if [[ "$ON_WINDOWS" != true ]]; then
  set_command "bash '$hook_copy'"
  [[ "$(porcelain_user)" == ok ]] && ok "a single-quoted entry: ok" || error "single quotes: $(bash "$SETUP" --status --porcelain --claude 2>&1)"
  # $HOME is $tmp/home, so $HOME/../ reaches the copy under $tmp/data.
  via_home="\$HOME/../${hook_copy#"$tmp"/}"
  set_command "bash \"$via_home\" "
  [[ "$(porcelain_user)" == ok ]] && ok "a \$HOME/ entry with a trailing space: ok" || error "\$HOME form: $(bash "$SETUP" --status --porcelain --claude 2>&1)"
  set_command "bash   $via_home"
  [[ "$(porcelain_user)" == ok ]] && ok "spaces after bash: ok" || error "spaces after bash: $(bash "$SETUP" --status --porcelain --claude 2>&1)"
  # The shell leaves $HOME and ~ alone in single quotes, so that hook cannot run.
  set_command "bash '$via_home'"
  [[ "$(porcelain_user)" == broken ]] && ok "single-quoted \$HOME/: broken" || error "single-quoted \$HOME: $(bash "$SETUP" --status --porcelain --claude 2>&1)"
fi
point_entry "$tmp/nowhere/scripts/claude-hooks/pretooluse_private_names.sh"
[[ "$(porcelain_user)" == broken ]] && ok "an entry to a missing file: broken" || error "broken porcelain: $(bash "$SETUP" --status --porcelain --claude 2>&1)"
rc="$(run --status)"
grep -q 'BROKEN: .* does not exist' "$tmp/out" && ok "--status says BROKEN" || error "broken status: $(cat "$tmp/out")"
rc="$(run --claude)"
[[ "$rc" == 0 && "$(porcelain_user)" == ok && "$(ours_count "$settings")" == 1 ]] && ok "--claude again: back to ok, one entry" || error "re-install: rc=$rc $(cat "$tmp/out")"
cp "$tmp/settings.keep" "$settings"; rm -rf "$tmp/checkout"

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

# 8. No settings.json yet: created. Before that, absent.
[[ "$(porcelain_user)" == absent ]] && ok "--status --porcelain --claude: absent without an entry" || error "absent porcelain: $(bash "$SETUP" --status --porcelain --claude 2>&1)"
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
# --uninstall alone is the per-repository undo; outside a repository it refuses.
rc="$(run --uninstall)"
[[ "$rc" != 0 ]] && grep -q 'inside a Git worktree' "$tmp/out" && ok "--uninstall alone outside a repository -> refused" \
  || error "--uninstall alone outside a repository: rc=$rc"
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

# 12. merge_settings.py edge cases, called directly.
MERGE="$root_dir/scripts/claude-hooks/merge_settings.py"
ms_dir="$tmp/ms"; mkdir -p "$ms_dir"
"$PY" "$(native "$MERGE")" uninstall "$(native "$ms_dir/none.json")" >/dev/null 2>&1
[[ ! -e "$ms_dir/none.json" ]] && ok "uninstall with no settings.json creates none" || error "uninstall created $(cat "$ms_dir/none.json")"
printf '{"a":1}' > "$ms_dir/compact.json"
"$PY" "$(native "$MERGE")" uninstall "$(native "$ms_dir/compact.json")" >/dev/null 2>&1
[[ "$(cat "$ms_dir/compact.json")" == '{"a":1}' ]] && ! ls "$ms_dir"/compact.json.bak-* >/dev/null 2>&1 \
  && ok "uninstall with nothing of ours leaves the file byte for byte" || error "uninstall rewrote: $(cat "$ms_dir/compact.json")"
printf '{"a":1}\n' > "$ms_dir/orig.json"; chmod 600 "$ms_dir/orig.json"
"$PY" "$(native "$MERGE")" install "$(native "$ms_dir/orig.json")" 'bash /x/pretooluse_private_names.sh' >/dev/null 2>&1
"$PY" "$(native "$MERGE")" uninstall "$(native "$ms_dir/orig.json")" >/dev/null 2>&1
n_bak="$(find "$ms_dir" -name 'orig.json.bak-*' | wc -l | tr -d ' ')"
[[ "$n_bak" == 2 ]] && grep -lx '{"a":1}' "$ms_dir"/orig.json.bak-* >/dev/null \
  && ok "two changes in one second keep two backups, the original among them" || error "backups: $n_bak"
if [[ "$ON_WINDOWS" != true ]]; then
  bad_mode="$(find "$ms_dir" -name 'orig.json.bak-*' ! -perm 600 | head -1)"
  [[ -z "$bad_mode" ]] && ok "backups keep the settings file's mode (600)" || error "backup mode: $(ls -l "$bad_mode")"
  printf '{"a":1}\n' > "$ms_dir/real.json"; ln -s real.json "$ms_dir/link.json"
  "$PY" "$MERGE" install "$ms_dir/link.json" 'bash /x/pretooluse_private_names.sh' >/dev/null 2>&1
  [[ -L "$ms_dir/link.json" ]] && grep -q pretooluse_private_names "$ms_dir/real.json" \
    && ok "a symlinked settings.json stays a symlink; its target is updated" || error "symlink replaced: $(ls -l "$ms_dir")"
fi

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
