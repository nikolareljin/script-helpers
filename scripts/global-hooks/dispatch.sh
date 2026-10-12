#!/usr/bin/env bash
# SCRIPT: dispatch.sh
# DESCRIPTION: Machine-wide git hook: security checks for the configured owners' repositories, then the repository's own hook.
# USAGE: dispatch.sh <hook-name> [git's hook arguments...]  (called by the wrappers setup-hooks.sh --global writes)
# PARAMETERS:
#   <hook-name>            The git hook being run: pre-push, pre-commit, commit-msg, ...
#   SCRIPT_HELPERS_OWNERS  Comma-separated GitHub users/orgs whose repositories are
#                          checked. Default: git config --global script-helpers.owners.
# ----------------------------------------------------
#
# Installed by `setup-hooks.sh --global` and pointed at by the global
# core.hooksPath, so it runs in every repository without its own core.hooksPath.
#
# 1. Is this repository one of the owners'? The URL being pushed to (pre-push)
#    and every remote URL decide, failing closed: see scripts/owner_scope.sh.
#    No owners configured, another owner, or no remote: no checks at all, and
#    nothing printed (except one notice per push while owners are unset).
# 2. If so, the security steps of scripts/security_hooks.sh for this hook.
# 3. Always: the hook git would have run without this install, the previous
#    global core.hooksPath's <hook> if one was set, else .git/hooks/<hook>.
#    Committed hooks (.githooks/<hook>, scripts/git-hooks/<hook>) first, only
#    in an owner's repository whose clone set script-helpers.trust-repo-hooks.
#    Its exit status is this hook's.
set -uo pipefail

hook="${1:?dispatch.sh needs the hook name}"
shift

base="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # <install>/scripts
install_dir="$(cd "$base/.." && pwd)"
self_wrapper="$install_dir/hooks/$hook"

stdin_file=""
stdin_dir=""
cleanup() { [[ -n "$stdin_dir" ]] && rm -rf "$stdin_dir"; }
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT
case "$hook" in
  pre-push|post-rewrite|reference-transaction|pre-receive|post-receive|proc-receive)
    # A private per-run directory (mktemp -d, mode 700), never a bare file in TMPDIR.
    stdin_dir="$(mktemp -d 2>/dev/null)" && [[ -n "$stdin_dir" && -d "$stdin_dir" && ! -L "$stdin_dir" ]] || {
      echo "[script-helpers] global hooks: could not create a private temp directory; refused." >&2
      exit 1
    }
    chmod 700 "$stdin_dir" 2>/dev/null || true
    stdin_file="$stdin_dir/stdin"
    cat > "$stdin_file" || exit 1
    ;;
esac

# Both libraries come from this install, never from the repository.
export SCRIPT_HELPERS_SECURITY_DIR="$base"
# shellcheck source=/dev/null
if ! source "$base/owner_scope.sh" || ! source "$base/security_hooks.sh"; then
  echo "[script-helpers] global hooks: install at $install_dir is broken; rerun setup-hooks.sh --global." >&2
  exit 1
fi

# scope_failed <reason>: scope could not be decided. Fail closed for the hooks
# that publish or record (pre-push, pre-commit, commit-msg); others pass.
scope_failed() {
  case "$hook" in
    pre-push|pre-commit|commit-msg) sec_unchecked "$hook" "$1" || exit 1 ;;
  esac
}

in_scope=false
if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! owners="$(scope_owners)"; then
    scope_failed "could not read git config script-helpers.owners"
  elif [[ -z "$owners" ]]; then
    [[ "$hook" == pre-push ]] && echo "[script-helpers] global hooks: no owners set (git config --global script-helpers.owners <user-or-org>); security checks skipped." >&2
  elif ! remote_urls="$(scope_repo_urls)"; then
    # Cannot tell whose repository this is: check it rather than guess.
    echo "[script-helpers] global hooks: could not list this repository's remotes; checking it." >&2
    in_scope=true
  else
    # pre-push: the URL being pushed to, and every remote's URLs. Any one of
    # them an owner's (or looking like one) puts the push in scope, so an
    # owner's commits pushed to a mirror or a second remote are checked too.
    urls=()
    [[ "$hook" == pre-push ]] && urls+=("${2:-}")
    while IFS= read -r u; do urls+=("$u"); done <<EOF_URLS
$remote_urls
EOF_URLS
    scope_in_scope "$owners" "${urls[@]+"${urls[@]}"}" && in_scope=true
  fi
fi

if [[ "$in_scope" == true ]]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  case "$hook" in
    pre-push)
      deletions_only=true
      # shellcheck disable=SC2034
      while read -r lref lsha rref rsha; do
        [[ -n "${lsha:-}" ]] || continue
        [[ "$lsha" =~ ^0+$ ]] || deletions_only=false
      done < "$stdin_file"
      if [[ "$deletions_only" == false ]]; then
        (cd "$top" && sec_pre_push "$stdin_file" "${1:-}" "${2:-}") || exit 1
      fi
      ;;
    pre-commit) (cd "$top" && sec_pre_commit) || exit 1 ;;
    commit-msg)
      msg="$1"; [[ "$msg" == /* ]] || msg="$(pwd)/$msg"
      (cd "$top" && sec_commit_msg "$msg") || exit 1
      ;;
  esac
fi

# ------------------------------------------------------------- chaining
# run_hook <path> [args]: run a repository's hook the way git would.
run_hook() {
  local h="$1"; shift
  if [[ -n "$stdin_file" ]]; then
    if [[ -x "$h" ]]; then "$h" "$@" < "$stdin_file"; else bash "$h" "$@" < "$stdin_file"; fi
  else
    if [[ -x "$h" ]]; then "$h" "$@"; else bash "$h" "$@"; fi
  fi
}

top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[[ -n "$common" && "$common" != /* ]] && common="$(pwd)/$common"
previous=""
if [[ -f "$install_dir/previous-hooksPath" ]]; then
  previous="$(cat "$install_dir/previous-hooksPath")"
  [[ "$previous" == "(unset)" ]] && previous=""
  # shellcheck disable=SC2088  # a literal "~/" saved from git config
  case "$previous" in "~/"*) previous="${HOME:-}/${previous#\~/}" ;; esac
fi
# Committed hooks (.githooks, scripts/git-hooks, or a relative earlier
# core.hooksPath, which points into the work tree) run only in an owner's
# repository whose clone opted in locally:
#   git config --local script-helpers.trust-repo-hooks true
# (set by the per-repository setup-hooks.sh). Anything else would execute code
# from whatever was cloned, which git never does by itself. Only local and
# global git config decide; nothing in the work tree does.
trusted=false
if [[ "$in_scope" == true && -n "$top" ]] && \
   [[ "$(git config --local --bool --get script-helpers.trust-repo-hooks 2>/dev/null)" == true ]]; then
  trusted=true
fi
if [[ -n "$previous" && "$previous" != /* ]]; then
  if [[ "$trusted" == true ]]; then previous="$top/$previous"; else previous=""; fi
fi

# Where git itself would have looked without this install: the previous global
# hooks directory if there was one, else .git/hooks (local, never committed).
if [[ -n "$previous" ]]; then
  native="$previous/$hook"
else
  native="${common:+$common/hooks/$hook}"
fi
tracked1=""; tracked2=""
if [[ "$trusted" == true ]]; then
  tracked1="$top/.githooks/$hook"; tracked2="$top/scripts/git-hooks/$hook"
fi
for candidate in "$tracked1" "$tracked2" "$native"; do
  [[ -n "$candidate" && -f "$candidate" ]] || continue
  [[ "$candidate" -ef "$self_wrapper" || "$candidate" -ef "${BASH_SOURCE[0]}" ]] && continue
  # git runs a hooks-directory file only when it is executable; keep that rule.
  [[ "$candidate" == "$native" && ! -x "$candidate" ]] && continue
  run_hook "$candidate" "$@"
  exit $?
done
exit 0
