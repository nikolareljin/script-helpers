#!/usr/bin/env bash
# SCRIPT: setup_hooks_test.sh
# DESCRIPTION: Tests for scripts/setup-hooks.sh: which hooks directory it picks.
# USAGE: ./tests/setup_hooks_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/setup_hooks_test.sh
# ----------------------------------------------------
#
# The case worth a fixture: a repository that vendors script-helpers somewhere
# other than scripts/script-helpers, and has only .githooks/pre-push (the
# protected-refs guard). setup-hooks.sh must pick the bundled hooks, and the
# shared pre-push must still hand over to the repository's own.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
note()  { echo "[setup_hooks_test] $*"; }
error() { echo "[setup_hooks_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }

# A repository with a copy of script-helpers' setup-hooks.sh and git-hooks at $2.
make_repo() {
  local repo="$tmp/$1" vendor="$2"
  git init -q "$repo"
  if [[ -n "$vendor" ]]; then
    mkdir -p "$repo/$vendor/scripts"
    cp "$root_dir/scripts/setup-hooks.sh" "$repo/$vendor/scripts/"
    cp -R "$root_dir/scripts/git-hooks" "$repo/$vendor/scripts/"
  fi
  echo "$repo"
}

hooks_path() { git -C "$1" config --get core.hooksPath || true; }

# 1. vendor/script-helpers: the old lookup only knew scripts/script-helpers.
repo="$(make_repo vendored vendor/script-helpers)"
(cd "$repo" && bash vendor/script-helpers/scripts/setup-hooks.sh >/dev/null 2>&1) || true
[[ "$(hooks_path "$repo")" == "vendor/script-helpers/scripts/git-hooks" ]] \
  && ok "vendor/script-helpers -> its bundled hooks" \
  || error "vendor/script-helpers: got '$(hooks_path "$repo")'"

# 2. scripts/script-helpers, the usual place.
repo="$(make_repo usual scripts/script-helpers)"
(cd "$repo" && bash scripts/script-helpers/scripts/setup-hooks.sh >/dev/null 2>&1) || true
[[ "$(hooks_path "$repo")" == "scripts/script-helpers/scripts/git-hooks" ]] \
  && ok "scripts/script-helpers -> its bundled hooks" \
  || error "scripts/script-helpers: got '$(hooks_path "$repo")'"

# 3. .githooks with both hooks still wins.
repo="$(make_repo local scripts/script-helpers)"
mkdir -p "$repo/.githooks"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.githooks/pre-commit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.githooks/pre-push"
(cd "$repo" && bash scripts/script-helpers/scripts/setup-hooks.sh >/dev/null 2>&1) || true
[[ "$(hooks_path "$repo")" == ".githooks" ]] \
  && ok ".githooks with pre-commit and pre-push is used as is" \
  || error ".githooks: got '$(hooks_path "$repo")'"

# 4. Only .githooks/pre-push: shared hooks, and they hand over to it.
repo="$(make_repo guard vendor/script-helpers)"
mkdir -p "$repo/.githooks"
printf '#!/usr/bin/env bash\necho guard-ran; exit 7\n' > "$repo/.githooks/pre-push"
(cd "$repo" && bash vendor/script-helpers/scripts/setup-hooks.sh >/dev/null 2>&1) || true
[[ "$(hooks_path "$repo")" == "vendor/script-helpers/scripts/git-hooks" ]] \
  && ok "only .githooks/pre-push -> the shared hooks" \
  || error "guard repo: got '$(hooks_path "$repo")'"
rc=0
out="$(cd "$repo" && printf 'refs/heads/main 1111 refs/heads/main 2222\n' \
  | bash vendor/script-helpers/scripts/git-hooks/pre-push origin url 2>&1)" || rc=$?
[[ $rc -eq 7 && "$out" == *guard-ran* ]] \
  && ok "the shared pre-push hands over to .githooks/pre-push (exit 7 kept)" \
  || error "hand-over: rc=$rc out='$out'"

# 5. Run by a relative path from a subdirectory.
repo="$(make_repo subdir vendor/script-helpers)"
mkdir -p "$repo/src/deep"
(cd "$repo/src/deep" && bash ../../vendor/script-helpers/scripts/setup-hooks.sh >/dev/null 2>&1) || true
[[ "$(hooks_path "$repo")" == "vendor/script-helpers/scripts/git-hooks" ]] \
  && ok "relative path from a subdirectory -> the same hooks" \
  || error "from a subdirectory: got '$(hooks_path "$repo")'"

# 6. Outside a worktree it refuses.
rc=0
(cd "$tmp" && bash "$root_dir/scripts/setup-hooks.sh" >/dev/null 2>&1) || rc=$?
[[ $rc -ne 0 ]] && ok "outside a git worktree -> error" || error "outside a worktree exited 0"

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
