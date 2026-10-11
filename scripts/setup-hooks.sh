#!/usr/bin/env bash
# SCRIPT: setup-hooks.sh
# DESCRIPTION: Configure git to use shared or repository-local hook scripts.
# USAGE: bash scripts/setup-hooks.sh [--global [--uninstall] | --status]
# PARAMETERS:
#   (none)        Point this repository's core.hooksPath at the shared hooks.
#   --global      Install the hooks machine-wide: copy them, with their own copy of
#                 the check scripts, to ${XDG_DATA_HOME:-~/.local/share}/script-helpers/git-hooks
#                 and set the GLOBAL core.hooksPath there, after printing the old value
#                 and saving it. Refuses (exit 2) until owners are configured:
#                   git config --global script-helpers.owners <user-or-org>[,<another>]
#                 Only those owners' github.com repositories are checked; every other
#                 repository runs only its own hooks. See docs/security-gates.md.
#   --global --uninstall  Restore the global core.hooksPath saved by --global.
#   --status      Show the global and this repository's hooks setup.
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

GLOBAL=false; UNINSTALL=false; STATUS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --global) GLOBAL=true ;;
    --uninstall) UNINSTALL=true ;;
    --status) STATUS=true ;;
    -h|--help) sed -n '2,/^# ------/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[setup-hooks] unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ "$UNINSTALL" == true && "$GLOBAL" != true ]]; then
  echo "[setup-hooks] --uninstall goes with --global" >&2; exit 2
fi

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"    # this script-helpers copy
global_dir="${SCRIPT_HELPERS_HOOKS_HOME:-${XDG_DATA_HOME:-${HOME:-}/.local/share}/script-helpers/git-hooks}"
global_hooks="$global_dir/hooks"
backup_file="$global_dir/previous-hooksPath"
# Every hook git runs from core.hooksPath: with a global hooksPath set, git no
# longer reads .git/hooks, so each one needs a wrapper that chains to it.
GLOBAL_HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite push-to-checkout pre-auto-gc sendemail-validate reference-transaction post-index-change"

configured_owners() {
  printf '%s' "${SCRIPT_HELPERS_OWNERS:-$(git config --global --get script-helpers.owners 2>/dev/null || true)}"
}

show_status() {
  local cur local_path
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  echo "[setup-hooks] global core.hooksPath: ${cur:-(unset)}"
  if [[ -n "$cur" && "$cur" == "$global_hooks" ]]; then
    echo "[setup-hooks] global hooks: installed at $global_dir ($(cat "$global_dir/VERSION" 2>/dev/null || echo unknown version))"
    echo "[setup-hooks] previous global value: $(cat "$backup_file" 2>/dev/null || echo '(none saved)')"
  else
    echo "[setup-hooks] global hooks: not active"
  fi
  echo "[setup-hooks] owners checked: $(configured_owners | sed 's/^$/(none configured)/')"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local_path="$(git config --local --get core.hooksPath 2>/dev/null || true)"
    if [[ -n "$local_path" ]]; then
      echo "[setup-hooks] this repository: core.hooksPath = $local_path (overrides the global one; its hooks run the checks unconditionally)"
    else
      echo "[setup-hooks] this repository: no local core.hooksPath; the global value applies"
    fi
  fi
}

install_global() {
  local cur owners name stage
  owners="$(configured_owners)"
  if [[ -z "$owners" ]]; then
    echo "[setup-hooks] ERROR: no owners configured, so the global hooks would check nothing." >&2
    echo "[setup-hooks] Set your GitHub user or org first, then run this again:" >&2
    echo "[setup-hooks]   git config --global script-helpers.owners <user-or-org>[,<another>]" >&2
    exit 2
  fi
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  echo "[setup-hooks] current global core.hooksPath: ${cur:-(unset)}"
  mkdir -p "$global_dir" || exit 1
  if [[ "$cur" != "$global_hooks" ]]; then
    printf '%s\n' "${cur:-(unset)}" > "$backup_file"
    echo "[setup-hooks] saved it to $backup_file; --global --uninstall restores it"
  fi

  # Stage, then swap: a half-copied install must never be what git runs.
  stage="$(mktemp -d "$global_dir/.stage.XXXXXX")" || exit 1
  mkdir -p "$stage/scripts/global-hooks" "$stage/hooks" || exit 1
  cp "$src_root/helpers.sh" "$stage/" && cp -R "$src_root/lib" "$stage/lib" || { rm -rf "$stage"; exit 1; }
  for name in security_hooks.sh owner_scope.sh check_sensitive.sh check_private_names.sh refresh_private_names.sh; do
    cp "$src_root/scripts/$name" "$stage/scripts/$name" || { rm -rf "$stage"; exit 1; }
  done
  cp "$src_root/scripts/global-hooks/dispatch.sh" "$stage/scripts/global-hooks/" || { rm -rf "$stage"; exit 1; }
  for name in $GLOBAL_HOOK_NAMES; do
    printf '#!/usr/bin/env bash\nexec bash "%s/scripts/global-hooks/dispatch.sh" %s "$@"\n' "$global_dir" "$name" > "$stage/hooks/$name"
    chmod +x "$stage/hooks/$name"
  done
  printf '%s %s\n' "$(git -C "$src_root" describe --tags --always 2>/dev/null || cat "$src_root/VERSION" 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%d)" > "$stage/VERSION"
  rm -rf "$global_dir/scripts.old" "$global_dir/hooks.old" "$global_dir/lib.old"
  for name in scripts hooks lib; do
    [[ -e "$global_dir/$name" ]] && mv "$global_dir/$name" "$global_dir/$name.old"
    mv "$stage/$name" "$global_dir/$name"
  done
  mv -f "$stage/helpers.sh" "$global_dir/helpers.sh"; mv -f "$stage/VERSION" "$global_dir/VERSION"
  rm -rf "$stage" "$global_dir/scripts.old" "$global_dir/hooks.old" "$global_dir/lib.old"

  git config --global core.hooksPath "$global_hooks"
  echo "[setup-hooks] global core.hooksPath = $global_hooks"
  echo "[setup-hooks] Checked: github.com repositories of: $owners. Others run only their own hooks."
  echo "[setup-hooks] A repository with its own core.hooksPath ignores this; run setup-hooks.sh in it."
}

uninstall_global() {
  local cur prev
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  if [[ "$cur" != "$global_hooks" ]]; then
    echo "[setup-hooks] global core.hooksPath is '${cur:-(unset)}', not $global_hooks; left as is." >&2
  else
    prev="$(cat "$backup_file" 2>/dev/null || echo '(unset)')"
    if [[ "$prev" == "(unset)" || -z "$prev" ]]; then
      git config --global --unset core.hooksPath
      echo "[setup-hooks] global core.hooksPath unset (as before --global)"
    else
      git config --global core.hooksPath "$prev"
      echo "[setup-hooks] global core.hooksPath restored to $prev"
    fi
  fi
  rm -rf "${global_dir:?}/hooks" "${global_dir:?}/scripts" "${global_dir:?}/lib" "${global_dir:?}/helpers.sh" "${global_dir:?}/VERSION" "$backup_file"
  rmdir "$global_dir" 2>/dev/null || true
  echo "[setup-hooks] global hooks removed"
}

if [[ "$STATUS" == true ]]; then show_status; exit 0; fi
if [[ "$GLOBAL" == true ]]; then
  if [[ "$UNINSTALL" == true ]]; then uninstall_global; else install_global; fi
  exit 0
fi

# This script's directory, both as the caller reached it and physically. Taken
# before the cd below: a relative path in BASH_SOURCE is relative to the
# caller's cwd.
script_dir_logical="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "[setup-hooks] ERROR: Run this script inside a Git worktree." >&2
  exit 1
fi
# The top as the caller sees it, symlinks kept: a vendored copy that is a symlink
# to a checkout elsewhere is inside the repository only in this view.
repo_root_logical="$(cd "./$(git rev-parse --show-cdup)" && pwd)"
cd "$repo_root"
repo_root="$(pwd -P)"

# bundled_under <script dir> <repository top>: the hooks next to this script as a
# repo-relative path, when that directory is inside the repository.
bundled_under() {
  if [[ "$1" == "$2"/* ]] && has_required_hooks "$1/git-hooks"; then
    echo "${1#"$2"/}/git-hooks"
  fi
}

# The bundled hooks next to this script, as a repo-relative path, or nothing:
# first as the caller reached them, then physically.
bundled_hooks() {
  local found
  found="$(bundled_under "$script_dir_logical" "$repo_root_logical")"
  [[ -n "$found" ]] || found="$(bundled_under "$script_dir" "$repo_root")"
  [[ -z "$found" ]] || echo "$found"
}

has_required_hooks() {
  local dir="$1"
  [[ -f "$dir/pre-commit" ]] && [[ -f "$dir/pre-push" ]]
}

resolve_hooks_dir() {
  # Returns a repo-relative path for git config storage; uses absolute paths for existence checks.
  if has_required_hooks "$repo_root/.githooks"; then
    echo ".githooks"
  elif [[ -n "$(bundled_hooks)" ]]; then
    bundled_hooks
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
  echo "[setup-hooks] ERROR: No hooks directory found. Looked for pre-commit and pre-push in:" >&2
  echo "  .githooks/" >&2
  echo "  ${script_dir_logical}/git-hooks/  (next to this script)" >&2
  echo "  scripts/script-helpers/scripts/git-hooks/" >&2
  echo "  scripts/git-hooks/" >&2
  exit 1
fi

# Make all hook files executable
while IFS= read -r -d '' hook; do
  chmod +x "$hook"
done < <(find "$hooks_dir_abs" -maxdepth 1 -type f -print0)

git config core.hooksPath "$hooks_dir"
# This clone opted in: if the machine-wide hooks ever run here (no local
# core.hooksPath), they may chain to this repository's committed hooks.
git config --local script-helpers.trust-repo-hooks true
echo "[setup-hooks] core.hooksPath = $hooks_dir"
echo "[setup-hooks] Done. Hooks active for this repo, security checks included"
echo "[setup-hooks] (they run in every repository set up this way, whoever owns it)."
