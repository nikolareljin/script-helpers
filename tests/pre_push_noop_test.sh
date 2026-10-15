#!/usr/bin/env bash
# SCRIPT: pre_push_noop_test.sh
# DESCRIPTION: Tests that a push which updates no ref (already up to date, or rejected) passes the pre-push hook, and one that sends commits is still checked.
# USAGE: bash tests/pre_push_noop_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/pre_push_noop_test.sh
# ----------------------------------------------------
# git runs pre-push with no ref lines when every ref is up to date or will be
# rejected. The hook read that as "nothing could be checked" and refused, so
# `git push` of an up-to-date branch failed in the hook.
set -uo pipefail
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT_DIR/scripts/git-hooks/pre-push"
failures=0
note()  { echo "[pre_push_noop_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[pre_push_noop_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$tmp/home" GIT_CONFIG_GLOBAL="$tmp/gitconfig" XDG_CONFIG_HOME="$tmp/home/.config"
mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"
# A name list and a stand-in gitleaks, so the checks themselves can run and
# only the no-op handling is under test.
printf '# visibility\tnamespace\tname\tcode\tflags\nprivate\tacme\tzqxprivaterepo\tR-999\t\n' > "$tmp/names.tsv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/gitleaks"; chmod +x "$tmp/gitleaks"
export PRIVATE_NAMES_FILE="$tmp/names.tsv" PRIVATE_NAMES_AUTO_REFRESH=false GITLEAKS_BIN="$tmp/gitleaks"
g() { git -c user.email=t@localhost -c user.name=t -c commit.gpgsign=false "$@"; }

git init -q --bare "$tmp/remote.git"
g -c init.defaultBranch=main init -q "$tmp/w"
cd "$tmp/w" || exit 1
echo a > a.txt && g add a.txt && g commit -qm a
echo b > b.txt && g add b.txt && g commit -qm b
git remote add origin "$tmp/remote.git"
git push -q --no-verify origin main 2>/dev/null   # seed the remote; the hook is not under test here
head="$(git rev-parse HEAD)"; prev="$(git rev-parse HEAD~1)"

# 1. No ref lines at all: what git sends for an up-to-date or rejected push.
rc=0; out="$(bash "$HOOK" origin "$tmp/remote.git" < /dev/null 2>&1)" || rc=$?
[[ $rc -eq 0 && "$out" == *"no ref to update"* ]] && ok "no ref lines: passes with a note" \
  || error "no ref lines: rc=$rc out=$out"

# 1b. No ref lines, but HEAD has commits the remote does not: a wrapper that
#     lost git's stdin looks exactly like an up-to-date push, so HEAD's unpushed
#     commits are checked rather than waved through.
echo 'see zqxprivaterepo' > leak.txt && g add leak.txt && g commit -qm leak
rc=0; out="$(bash "$HOOK" origin "$tmp/remote.git" < /dev/null 2>&1)" || rc=$?
[[ $rc -ne 0 && "$out" == *"checking HEAD"* ]] && ok "no ref lines with unpushed HEAD commits: they are checked (a private name is refused)" \
  || error "no ref lines, unpushed HEAD: rc=$rc out=$out"
g reset -q --hard "$head"

# 1c. The repository's own .githooks/pre-push still gets exactly what git
#     sent (no lines), not the HEAD line made up for the checks.
mkdir -p .githooks
printf '#!/usr/bin/env bash\nn=$(grep -c . || true)\necho "repo-hook-lines=$n"\n' > .githooks/pre-push
echo d > d.txt && g add d.txt && g commit -qm d
rc=0; out="$(bash "$HOOK" origin "$tmp/remote.git" < /dev/null 2>&1)" || rc=$?
[[ $rc -eq 0 && "$out" == *"repo-hook-lines=0"* ]] && ok "no ref lines: the repository's own pre-push gets no lines" \
  || error "repo hook stdin: rc=$rc out=$out"
rm -rf .githooks
g reset -q --hard "$head"

# 2. A ref line whose local and remote sha are the same sends nothing.
rc=0; out="$(printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$head" | bash "$HOOK" origin "$tmp/remote.git" 2>&1)" || rc=$?
[[ $rc -eq 0 && "$out" == *"no ref to update"* ]] && ok "same sha on both sides: passes with a note" \
  || error "same sha: rc=$rc out=$out"

# 2b. A malformed line is not "nothing to send": it goes to the checks.
rc=0; out="$(printf 'refs/heads/main\n' | bash "$HOOK" origin "$tmp/remote.git" 2>&1)" || rc=$?
[[ $rc -ne 0 && "$out" != *"no ref to update"* ]] && ok "a malformed ref line is refused, not waved through" \
  || error "malformed line: rc=$rc out=$out"

# 3. A ref that sends a commit is still checked, not waved through.
echo c > c.txt && g add c.txt && g commit -qm c
new="$(git rev-parse HEAD)"
rc=0; out="$(printf 'refs/heads/main %s refs/heads/main %s\n' "$new" "$head" | bash "$HOOK" origin "$tmp/remote.git" 2>&1)" || rc=$?
[[ "$out" != *"no ref to update"* ]] && ok "a ref with a new commit is checked (rc=$rc)" \
  || error "new commit skipped: out=$out"
g reset -q --hard "$head"

# 4. The real thing: git push through the hook, up to date and rejected.
git config core.hooksPath "$ROOT_DIR/scripts/git-hooks"
rc=0; out="$(git push origin main 2>&1)" || rc=$?
[[ $rc -eq 0 && "$out" == *"no ref to update"* ]] && ok "git push of an up-to-date branch passes the hook" \
  || error "up-to-date push: rc=$rc out=$out"
rc=0; out="$(git push origin "$prev":main 2>&1)" || rc=$?
[[ "$out" == *"no ref to update"* && "$out" == *"rejected"* ]] && ok "a rejected push is refused by git, not by the hook" \
  || error "rejected push: rc=$rc out=$out"

# 5. A new branch whose commits the remote already has sends no new commit; the
#    checks run on an empty range and pass.
rc=0; out="$(git push origin "$prev":refs/heads/other 2>&1)" || rc=$?
[[ $rc -eq 0 ]] && ok "a new branch made of commits the remote has passes" \
  || error "new branch of known commits: rc=$rc out=$out"

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
