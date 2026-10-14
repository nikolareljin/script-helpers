#!/usr/bin/env bash
# SCRIPT: owner_scope_github_user_test.sh
# DESCRIPTION: setup-hooks.sh records the signed-in GitHub account as script-helpers.github-user, and the owner scope counts it with script-helpers.owners.
# USAGE: bash tests/owner_scope_github_user_test.sh
# ----------------------------------------------------
set -uo pipefail
# The hooks would download a missing gitleaks or foxguard; tests never do.
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[owner_scope_github_user_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[owner_scope_github_user_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_DATA_HOME="$tmp/home/.local/share"
export LOCALAPPDATA="$XDG_DATA_HOME"
export GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset SCRIPT_HELPERS_OWNERS SCRIPT_HELPERS_HOOKS_HOME SCRIPT_HELPERS_REPO_HOOKS_HOME
mkdir -p "$HOME" "$tmp/bin"; : > "$GIT_CONFIG_GLOBAL"
cd "$tmp" || exit 1

# A gh that is signed in as example-user.
printf '#!/usr/bin/env bash\n[[ "$1 $2" == "api user" ]] && { echo example-user; exit 0; }\nexit 1\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

git init -q "$tmp/r"
out="$(cd "$tmp/r" && PATH="$tmp/bin:$PATH" bash "$root_dir/scripts/setup-hooks.sh" < /dev/null 2>&1)"
[[ "$(git config --global --get script-helpers.github-user)" == example-user ]] && grep -q 'example-user, is checked' <<<"$out" \
  && ok "setup records the signed-in GitHub account and says so" \
  || error "github-user not recorded: $(git config --global --get script-helpers.github-user) / $(grep -i github <<<"$out")"

# shellcheck source=/dev/null
source "$root_dir/scripts/owner_scope.sh"
[[ "$(scope_owners)" == example-user ]] && ok "the account alone is the scope" || error "scope: '$(scope_owners)'"
git config --global script-helpers.owners Example-Org
[[ "$(scope_owners)" == "example-user,example-org" ]] && ok "configured namespaces are added to it" || error "scope: '$(scope_owners)'"
scope_in_scope "$(scope_owners)" git@github.com:example-org/x.git && scope_in_scope "$(scope_owners)" https://github.com/example-user/y \
  && ok "repositories of both are in scope" || error "in-scope check failed"
scope_in_scope "$(scope_owners)" git@github.com:someone-else/z.git && error "another namespace was in scope" \
  || ok "another namespace is not"

# Recorded once: a different gh account later does not replace it.
printf '#!/usr/bin/env bash\necho other-user\n' > "$tmp/bin/gh"
(cd "$tmp/r" && PATH="$tmp/bin:$PATH" bash "$root_dir/scripts/setup-hooks.sh" < /dev/null >/dev/null 2>&1)
[[ "$(git config --global --get script-helpers.github-user)" == example-user ]] && ok "an existing value is kept" \
  || error "github-user replaced: $(git config --global --get script-helpers.github-user)"

# No gh: nothing recorded, nothing fails.
git config --global --unset script-helpers.github-user
git init -q "$tmp/r2"
rc=0; (cd "$tmp/r2" && PATH="/usr/bin:/bin" bash "$root_dir/scripts/setup-hooks.sh" < /dev/null >/dev/null 2>&1) || rc=$?
[[ $rc -eq 0 && -z "$(git config --global --get script-helpers.github-user)" ]] && ok "without gh nothing is recorded and setup still works" \
  || error "no gh: rc=$rc, github-user='$(git config --global --get script-helpers.github-user)'"

if [[ $failures -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "all passed"
