#!/usr/bin/env bash
# SCRIPT: setup-hooks.sh
# DESCRIPTION: Configure git to use shared or repository-local hook scripts.
# USAGE: bash scripts/setup-hooks.sh
# PARAMETERS:
#   No command-line parameters.
#   Hook directory priority:
#     1. .githooks/  (repo-local overrides with both pre-commit and pre-push)
#     2. git-hooks/ next to this script: the hooks bundled with this copy of
#        script-helpers, wherever it is vendored (scripts/script-helpers,
#        vendor/script-helpers, ...) or script-helpers' own scripts/git-hooks
#     3. scripts/script-helpers/scripts/git-hooks/, then scripts/git-hooks/
#   The shared pre-push hands over to .githooks/pre-push when a repository has
#   one (for example the protected-refs guard), so a repository with only
#   .githooks/pre-push gets the shared hooks and still runs its own.
# ----------------------------------------------------
# After running, hooks are active for all subsequent git operations in this repo.
set -euo pipefail

# This script's directory, physical, so it compares with repo_root. Taken before
# the cd below: a relative path in BASH_SOURCE is relative to the caller's cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "[setup-hooks] ERROR: Run this script inside a Git worktree." >&2
  exit 1
fi
cd "$repo_root"
repo_root="$(pwd -P)"

has_required_hooks() {
  local dir="$1"
  [[ -f "$dir/pre-commit" ]] && [[ -f "$dir/pre-push" ]]
}

resolve_hooks_dir() {
  # Returns a repo-relative path for git config storage; uses absolute paths for existence checks.
  if has_required_hooks "$repo_root/.githooks"; then
    echo ".githooks"
  elif [[ "$script_dir" == "$repo_root"/* ]] && has_required_hooks "$script_dir/git-hooks"; then
    echo "${script_dir#"$repo_root"/}/git-hooks"
  elif has_required_hooks "$repo_root/scripts/script-helpers/scripts/git-hooks"; then
    echo "scripts/script-helpers/scripts/git-hooks"
  elif has_required_hooks "$repo_root/scripts/git-hooks"; then
    echo "scripts/git-hooks"
  else
    echo ""
  fi
}

hooks_dir="$(resolve_hooks_dir)"   # relative — portable across clones
hooks_dir_abs="$repo_root/$hooks_dir"

if [[ -z "$hooks_dir" ]]; then
  echo "[setup-hooks] ERROR: No hooks directory found." >&2
  echo "  Expected shared hooks in scripts/ or both .githooks/pre-commit and .githooks/pre-push." >&2
  exit 1
fi

# Make all hook files executable
while IFS= read -r -d '' hook; do
  chmod +x "$hook"
done < <(find "$hooks_dir_abs" -maxdepth 1 -type f -print0)

git config core.hooksPath "$hooks_dir"
echo "[setup-hooks] core.hooksPath = $hooks_dir"
echo "[setup-hooks] Done. Hooks active for this repo."
