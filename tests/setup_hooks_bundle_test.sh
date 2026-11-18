#!/usr/bin/env bash
# SCRIPT: setup_hooks_bundle_test.sh
# DESCRIPTION: Every script an installed hook copy sources or runs is in that copy: git-hook bundles (per repository, --global) and tool-hook bundles (--claude, --agent).
# USAGE: bash tests/setup_hooks_bundle_test.sh
# PARAMETERS: No required parameters. FOXGUARD_REQUIRE=1 turns a missing foxguard
#             into a failure instead of skipping the push case that needs it.
# ----------------------------------------------------
# A copy runs outside the source tree, so a file left out of stage_common only
# shows when the hook reaches it: foxguard_push_compare.py was missing and every
# push with security.foxguardBlock on was refused.
# ----------------------------------------------------
set -uo pipefail
unset CI GITHUB_ACTIONS FOXGUARD_CMD SCRIPT_HELPERS_FOXGUARD_BLOCK SCRIPT_HELPERS_SECURITY_DIR
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[setup_hooks_bundle_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[setup_hooks_bundle_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }
PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info[0] != 3)' 2>/dev/null && { PY="$c"; break; }; done
real_fox="$(source "$root_dir/lib/foxguard.sh" >/dev/null 2>&1 && foxguard_bin 2>/dev/null || true)"

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_DATA_HOME="$tmp/home/.local/share" XDG_CACHE_HOME="$tmp/home/.cache"
export LOCALAPPDATA="$XDG_DATA_HOME"
export GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset SCRIPT_HELPERS_OWNERS SCRIPT_HELPERS_HOOKS_HOME SCRIPT_HELPERS_REPO_HOOKS_HOME CODEX_HOME COPILOT_HOME
mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"
printf 'private\tacme\tzqxprivaterepo\tR-999\t\n' > "$tmp/names.tsv"
export PRIVATE_NAMES_FILE="$tmp/names.tsv" PRIVATE_NAMES_AUTO_REFRESH=false
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/clean-gitleaks"; chmod +x "$tmp/clean-gitleaks"
export GITLEAKS_BIN="$tmp/clean-gitleaks"
cd "$tmp" || exit 1
setup="$root_dir/scripts/setup-hooks.sh"
git config --global script-helpers.owners example-owner
# with_reports: the local reports a push names, appended to $tmp/out.
with_reports() {
  local f
  for f in $(sed -n 's/^.*Local report: //p' "$tmp/out" | sort -u); do [[ -f "$f" ]] && cat -- "$f" >> "$tmp/out"; done
}
gc() { git -c user.name=Test -c user.email=test@example.com "$@"; }
data="$XDG_DATA_HOME/script-helpers"

# Named by a copied script only in a message or for the repository under test.
message_only=" setup-hooks.sh ci_security.sh preflight.sh local_test_flutter.sh local_test_go.sh local_test_gradle.sh local_test_node.sh local_test_php.sh local_test_python.sh local_test_rust.sh "
# Tool hooks never run push_checks.sh, the one script that sources it.
tool_only_absent=" security_hooks.sh "
names="$(cd "$root_dir/scripts" && ls -- *.sh *.py)"

# audit <label> <copy> <allowed-absent>: every scripts/ name a copied script
# references outside a comment is in the copy.
audit() {
  local label="$1" copy="$2" allowed="$3" f n missing=""
  [[ -d "$copy/scripts" ]] || { error "$label: no copy at $copy"; return; }
  while IFS= read -r f; do
    for n in $names; do
      [[ -f "$copy/scripts/$n" ]] && continue
      case "$message_only$allowed" in *" $n "*) continue ;; esac
      if [[ "$(grep -v '^[[:space:]]*#' "$f" | grep -c -w -F -- "$n")" != 0 ]]; then
        missing="$missing ${f#"$copy/"}->$n"
      fi
    done
  done < <(find "$copy/scripts" -type f \( -name '*.sh' -o -name '*.py' -o -path '*/hooks/*' \))
  if [[ -z "$missing" ]]; then ok "$label: every referenced script is in the copy"; else error "$label: missing:$missing"; fi
  [[ -f "$copy/scripts/foxguard_push_compare.py" ]] && ok "$label: foxguard_push_compare.py copied" \
    || error "$label: foxguard_push_compare.py not copied"
}

# 1. Git-hook bundles: per repository and --global.
git init -q "$tmp/r"; git init -q --bare "$tmp/remote.git"
git -C "$tmp/r" remote add origin "$tmp/remote.git"
(cd "$tmp/r" && bash "$setup" </dev/null >"$tmp/out" 2>&1) || { error "per-repo setup failed"; cat "$tmp/out" >&2; }
audit "per-repo git hooks" "$data/repo-hooks" ""
bash "$setup" --global </dev/null >"$tmp/out" 2>&1 || { error "--global setup failed"; cat "$tmp/out" >&2; }
audit "global git hooks" "$data/git-hooks" ""
bash "$setup" --global --uninstall </dev/null >/dev/null 2>&1

# 2. Tool-hook bundles: --claude and --agent.
if [[ -n "$PY" ]]; then
  bash "$setup" --claude </dev/null >"$tmp/out" 2>&1 || { error "--claude setup failed"; cat "$tmp/out" >&2; }
  audit "claude hook" "$data/claude-hooks" "$tool_only_absent"
  bash "$setup" --agent codex </dev/null >"$tmp/out" 2>&1 || { error "--agent setup failed"; cat "$tmp/out" >&2; }
  audit "agent hook" "$data/agent-hooks" "$tool_only_absent"
else
  note "SKIP: tool-hook bundles need Python 3"
fi

# 3. A clean push through the per-repo copy with foxguard blocking at high.
if [[ -z "$real_fox" ]]; then
  [[ "${FOXGUARD_REQUIRE:-0}" == 1 ]] && error "foxguard not found" || note "SKIP: clean push needs foxguard"
elif [[ -z "$PY" ]]; then
  note "SKIP: clean push needs Python 3"
else
  printf 'x = 1\n' > "$tmp/r/a.py"
  gc -C "$tmp/r" add a.py && gc -C "$tmp/r" commit -q -m one
  rc=0; (cd "$tmp/r" && FOXGUARD_CMD="$real_fox" SCRIPT_HELPERS_FOXGUARD_BLOCK=high git push -q origin HEAD:refs/heads/main) >"$tmp/out" 2>&1 || rc=$?
  [[ $rc -eq 0 ]] && ok "a clean push passes the copied foxguard step" \
    || { error "clean push refused (rc=$rc)"; tail -5 "$tmp/out" >&2; }
fi

# 4. Fail closed: a copy without foxguard_push_compare.py refuses the push.
if [[ -n "$real_fox" && -n "$PY" ]]; then
  rm -f "$data/repo-hooks/scripts/foxguard_push_compare.py"
  printf 'y = 2\n' > "$tmp/r/b.py"
  gc -C "$tmp/r" add b.py && gc -C "$tmp/r" commit -q -m two
  rc=0; (cd "$tmp/r" && FOXGUARD_CMD="$real_fox" SCRIPT_HELPERS_FOXGUARD_BLOCK=high git push -q origin HEAD:refs/heads/main) >"$tmp/out" 2>&1 || rc=$?
  with_reports
  [[ $rc -ne 0 ]] && grep -qF 'foxguard_push_compare.py is missing' "$tmp/out" && ok "a copy without the compare helper refuses the push" \
    || error "missing compare helper: rc=$rc"
fi

# 5. Fail closed: an in-scope global copy without push_checks.sh refuses the push.
git init -q "$tmp/g"
git -C "$tmp/g" remote add origin "https://github.com/example-owner/g.git"
git -C "$tmp/g" remote set-url --push origin "$tmp/remote.git"
if bash "$setup" --global </dev/null >"$tmp/out" 2>&1; then
  rm -f "$data/git-hooks/scripts/push_checks.sh"
  gc -C "$tmp/g" commit -q --allow-empty -m g
  rc=0; (cd "$tmp/g" && SCRIPT_HELPERS_FOXGUARD_BLOCK=off git push -q origin HEAD:refs/heads/g) >"$tmp/out" 2>&1 || rc=$?
  [[ $rc -ne 0 ]] && grep -qF 'push_checks.sh missing' "$tmp/out" && ok "a global copy without push_checks.sh refuses the push" \
    || { error "missing push_checks.sh: rc=$rc"; tail -5 "$tmp/out" >&2; }
  bash "$setup" --global --uninstall </dev/null >/dev/null 2>&1
else
  error "--global setup failed"; cat "$tmp/out" >&2
fi

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
