#!/usr/bin/env bash
# SCRIPT: setup-hooks.sh
# DESCRIPTION: Configure git to use shared or repository-local hook scripts.
# USAGE: bash scripts/setup-hooks.sh
#
# Priority:
#   1. .githooks/  (repo-local overrides with both pre-commit and pre-push)
#   2. scripts/script-helpers/scripts/git-hooks/  (submodule bundled hooks)
#   3. scripts/git-hooks/  (in script-helpers itself)
#
# After running, hooks are active for all subsequent git operations in this repo.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

resolve_hooks_dir() {
  if [[ -f .githooks/pre-commit ]] && [[ -f .githooks/pre-push ]]; then
    echo ".githooks"
  elif [[ -d scripts/script-helpers/scripts/git-hooks ]]; then
    echo "scripts/script-helpers/scripts/git-hooks"
  elif [[ -d scripts/git-hooks ]]; then
    echo "scripts/git-hooks"
  else
    echo ""
  fi
}

hooks_dir="$(resolve_hooks_dir)"

if [[ -z "$hooks_dir" ]]; then
  echo "[setup-hooks] ERROR: No hooks directory found." >&2
  echo "  Expected shared hooks in scripts/ or both .githooks/pre-commit and .githooks/pre-push." >&2
  exit 1
fi

# Make all hook files executable
find "$hooks_dir" -maxdepth 1 -type f | while read -r hook; do
  chmod +x "$hook"
done

git config core.hooksPath "$hooks_dir"
echo "[setup-hooks] core.hooksPath = $hooks_dir"
echo "[setup-hooks] Done. Hooks active for this repo."
