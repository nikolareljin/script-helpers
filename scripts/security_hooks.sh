#!/usr/bin/env bash
# SCRIPT: security_hooks.sh
# DESCRIPTION: The security steps every git hook runs, sourced by scripts/git-hooks/* and the global dispatcher.
# USAGE: source scripts/security_hooks.sh; sec_pre_push <refs-file> <remote-name> <url> | sec_pre_commit | sec_commit_msg <msg-file>
# PARAMETERS:
#   SCRIPT_HELPERS_SECURITY_DIR  Directory holding check_private_names.sh and
#                                check_sensitive.sh. Set by the global hooks;
#                                otherwise they are looked up in the repository.
#   SECURITY_GATE_ALLOW_UNCHECKED=1  Let a push through when a check could not
#                                run (exit 2, script missing, scope unknown), with
#                                a warning. Narrow on purpose: --no-verify skips
#                                every check, this skips none that can run.
#                                SENSITIVE_ALLOW_UNCHECKED=1 is the same.
#   FOXGUARD_CMD                 foxguard command to run (default: the pinned
#                                binary in the cache, else foxguard on PATH).
# ----------------------------------------------------
#
# Order, in pre-push: private names (block) -> credentials, then personal
# identifiers and PII, both in check_sensitive.sh (block) -> foxguard (warn only). The caller handles the deletions-only shortcut and the
# tests. Every function returns 0 to continue and 1 to refuse.
#
# No "already checked" marker is exported: an environment variable that skips
# the checks could be set by any parent process. A hook chained after these
# steps runs them again; that costs time, never coverage.

# sec_unchecked <hook> <reason>: a check could not run. Return 1 (refuse) unless
# SECURITY_GATE_ALLOW_UNCHECKED=1, which lets it through with a warning. A check
# that did not run is not a clean one.
sec_unchecked() {
  if [[ "${SECURITY_GATE_ALLOW_UNCHECKED:-${SENSITIVE_ALLOW_UNCHECKED:-}}" == 1 ]]; then
    echo "[$1] WARNING: $2; SECURITY_GATE_ALLOW_UNCHECKED=1, allowed unchecked." >&2
    return 0
  fi
  echo "[$1] $2; refused." >&2
  echo "[$1] Fix the cause, or run once with SECURITY_GATE_ALLOW_UNCHECKED=1." >&2
  return 1
}

_SEC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# sec_find <script>: path of a security script, or return 127.
sec_find() {
  local name="$1" top candidate
  # Set by the global hooks: their own copy and nothing else, so a missing
  # script there never falls back to one from the repository being checked.
  if [[ -n "${SCRIPT_HELPERS_SECURITY_DIR:-}" ]]; then
    [[ -f "$SCRIPT_HELPERS_SECURITY_DIR/$name" ]] || return 127
    printf '%s' "$SCRIPT_HELPERS_SECURITY_DIR/$name"; return 0
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  for candidate in \
    "$top/scripts/script-helpers/scripts/$name" \
    "$top/vendor/script-helpers/scripts/$name" \
    "$top/scripts/$name"; do
    [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  # Last, the copy next to this library (the hooks a repository points at).
  if [[ -f "$_SEC_LIB_DIR/$name" ]]; then
    printf '%s' "$_SEC_LIB_DIR/$name"; return 0
  fi
  return 127
}

# A stale dictionary misses every repository created since it was built, and
# nothing reports that. Kick a refresh into the background when it ages: never
# blocking, never failing the push, at most one at a time.
#
# Deliberately not a systemd timer or a launchd agent: this has to behave the
# same on Linux, macOS and Windows, and git runs its hooks under bash on all
# three. Nothing to install.
sec_maybe_refresh_private_names() {
  local list="${PRIVATE_NAMES_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names.tsv}"
  local age_days="${PRIVATE_NAMES_REFRESH_DAYS:-7}"
  [[ "${PRIVATE_NAMES_AUTO_REFRESH:-true}" == true ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0

  local refresher
  refresher="$(sec_find refresh_private_names.sh)" || return 0

  # Fresh enough, nothing to do. A missing list counts as stale.
  if [[ -s "$list" ]] && [[ -z "$(find "$list" -mtime "+$age_days" 2>/dev/null)" ]]; then
    return 0
  fi

  # One at a time. mkdir is the atomic primitive available everywhere; a stale
  # lock older than a day is cleared, so a killed refresh cannot wedge it.
  local lock="${list}.refresh.lock"
  [[ -d "$lock" ]] && [[ -n "$(find "$lock" -mtime +1 2>/dev/null)" ]] && rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 0

  echo "[pre-push] private-name list is stale; refreshing in the background."
  # No EXIT trap here: a trap in a backgrounded subshell is the construct
  # run_bounded_test refuses, and it buys nothing. A refresh that is killed
  # leaves the lock, which the day-old check above clears.
  (
    bash "$refresher" >"${list}.refresh.log" 2>&1
    rmdir "$lock" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

# sec_not_remote <remote-name>: git log arguments excluding what the push
# target already has. Only that remote's refs count: a commit already on some
# other remote (a private one, say) is still news to this one. A push to a bare
# URL has no remote refs, so everything it sends is checked.
sec_not_remote() {
  if [[ -n "${1:-}" ]] && git remote 2>/dev/null | grep -qxF -- "$1"; then
    printf -- '--not --remotes=%s' "$1"
  else
    printf -- '--not'
  fi
}

# sec_revs <refs-file> <remote-name>: one line of git log arguments per pushed
# ref: what that ref sends that the target does not have.
sec_revs() {
  local lref lsha rref rsha
  # shellcheck disable=SC2034
  while read -r lref lsha rref rsha; do
    [[ -n "${lsha:-}" ]] || continue
    [[ "$lsha" =~ ^0+$ ]] && continue          # a deletion carries no commits
    if [[ "${rsha:-0}" =~ ^0+$ ]] || ! git cat-file -e "${rsha}^{commit}" 2>/dev/null; then
      # A new branch, or a remote tip this clone never fetched: everything the
      # target remote does not already have (see sec_not_remote).
      printf '%s %s\n' "$lsha" "$(sec_not_remote "${2:-}")"
    else
      printf '%s..%s\n' "$rsha" "$lsha"
    fi
  done < "$1"
}

# A private repository's name must never reach a public one, and a push is the
# last moment it can be stopped: GitHub keeps the edit history of every pull
# request and issue body publicly, and rewriting commits changes every tag.
#
# Both the tracked tree and the messages of the commits actually being pushed.
# The check decides for itself whether this repository is one the rule applies
# to, so the hook can be installed everywhere rather than only where someone
# remembered to configure it.
sec_private_names() {
  local refs="$1" remote="${2:-}" url="${3:-}" gate rc revs
  # Public or private is the push target's, not origin's: a private repository
  # pushed to a public mirror must be checked. --for-repo takes the target.
  local -a target=()
  [[ -n "$url" ]] && target=(--for-repo "$url")
  gate="$(sec_find check_private_names.sh)" || {
    sec_unchecked pre-push "check_private_names.sh not found; private names NOT checked"
    return
  }

  sec_maybe_refresh_private_names

  bash "$gate" --tree --only-public "${target[@]+"${target[@]}"}"
  rc=$?
  # 2 means it could not check -- no name list, most often. That is a setup
  # problem rather than a clean tree, and it is deliberately a different exit
  # code from "found something" so the two can never be confused.
  if [[ "$rc" -eq 1 ]]; then
    echo "[pre-push] A tracked file names a private repository. Cite it by its code." >&2
    return 1
  elif [[ "$rc" -ne 0 ]]; then
    sec_unchecked pre-push "the private-name check could not run on the tree (exit $rc)" || return 1
  fi

  # The messages go to a file first, and the gate is called on the file.
  #
  # This used to be `... done < refs | bash "$gate" --stdin`, with `rc=$?` read straight
  # after. Under `set -o pipefail` that is the PIPELINE's status, not the gate's: when
  # `git log` failed -- a shallow clone, or a remote ref never fetched -- rc was git's 128,
  # the `-eq 1` test below did not fire, and the commit-message check silently did nothing
  # while the push went ahead. The mirror case was worse: anything on the left exiting 1
  # blocked the push and blamed a private name that was not there.
  local messages="${refs}.messages" log_failed=0
  : > "$messages"
  while IFS= read -r revs; do
    # shellcheck disable=SC2086  # revs is a list of git log arguments
    git log --format='%B' $revs >> "$messages" 2>/dev/null || log_failed=1
  done < <(sec_revs "$refs" "$remote")

  if [[ "$log_failed" -eq 1 ]]; then
    # Distinct from both "clean" and "found something", because it is neither.
    sec_unchecked pre-push "could not read every outgoing commit message (shallow clone, or a remote ref never fetched)" || { rm -f "$messages"; return 1; }
  fi

  bash "$gate" --file "$messages" --only-public "${target[@]+"${target[@]}"}"
  rc=$?
  rm -f "$messages"
  if [[ "$rc" -eq 1 ]]; then
    echo "[pre-push] A commit message names a private repository." >&2
    echo "[pre-push] To override:  PRIVATE_NAMES_ALLOW=<term> git push ..." >&2
    echo "[pre-push]              or git push --no-verify" >&2
    return 1
  elif [[ "$rc" -ne 0 ]]; then
    sec_unchecked pre-push "the private-name check could not run on the commit messages (exit $rc)" || return 1
  fi
  return 0
}

# Credentials, personal identifiers and PII in the added lines and messages.
# Exit 2 (could not check: gitleaks missing, commits unreadable) refuses the
# push: a credential scan that did not run is not a clean one.
sec_sensitive_push() {
  local refs="$1" remote="${2:-}" gate rc
  gate="$(sec_find check_sensitive.sh)" || {
    sec_unchecked pre-push "check_sensitive.sh not found; credentials and personal data NOT checked"
    return
  }
  bash "$gate" --push-refs "$refs" --remote "$remote"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      echo "[pre-push] Sensitive data in the commits being pushed; push refused." >&2
      echo "[pre-push] Rewrite the commit that added it (git rebase -i), not a follow-up commit:" >&2
      echo "[pre-push] the push carries every commit, so the value would still be published." >&2
      return 1
      ;;
    *) sec_unchecked pre-push "sensitive-data check could not run (exit $rc)" ;;
  esac
}

# foxguard_cmd: the foxguard to run, or return 1.
sec_foxguard_cmd() {
  local c
  if [[ -n "${FOXGUARD_CMD:-}" ]]; then printf '%s' "$FOXGUARD_CMD"; return 0; fi
  for c in "${XDG_CACHE_HOME:-${HOME:-}/.cache}"/script-helpers/foxguard/*/foxguard \
           "${XDG_CACHE_HOME:-${HOME:-}/.cache}"/script-helpers/foxguard/*/foxguard.exe; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  command -v foxguard 2>/dev/null && return 0
  return 1
}

# foxguard on the files this push changes. Warnings only: it always returns 0.
# Measured 2026-09-29: its shell taint rules flagged 93 lines of this library,
# none exploitable, so as a gate it would fail correct code.
sec_foxguard_push() {
  local refs="$1" remote="${2:-}" cmd revs f out rc=0 n shown=0 max="${FOXGUARD_MAX_LINES:-40}"
  if ! cmd="$(sec_foxguard_cmd)"; then
    echo "[pre-push] foxguard not installed; static-analysis warnings skipped (install: docs/security-gates.md)."
    return 0
  fi
  local list
  list="$(mktemp)" || return 0
  while IFS= read -r revs; do
    # shellcheck disable=SC2086
    git log --name-only --format= --diff-filter=ACMR $revs 2>/dev/null
  done < <(sec_revs "$refs" "$remote") | sort -u | while IFS= read -r f; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done > "$list"
  if [[ ! -s "$list" ]]; then rm -f "$list"; return 0; fi
  local files=()
  while IFS= read -r f; do files+=("$f"); done < "$list"
  rm -f "$list"
  # shellcheck disable=SC2086  # FOXGUARD_CMD may carry arguments
  out="$($cmd "${files[@]}" 2>&1)" || rc=$?
  n="$(printf '%s\n' "$out" | grep -c '[^[:space:]]' || true)"
  if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
    echo "[pre-push] WARNING (foxguard): could not scan (exit $rc); push not affected."
  fi
  if [[ "${n:-0}" -gt 0 && ( "$rc" -ne 0 ) ]]; then
    while IFS= read -r f; do
      [[ -n "${f//[[:space:]]/}" ]] || continue
      shown=$((shown + 1))
      [[ "$shown" -le "$max" ]] && printf '[pre-push] WARNING (foxguard): %s\n' "$f"
    done <<< "$out"
    [[ "$shown" -gt "$max" ]] && echo "[pre-push] WARNING (foxguard): ... $((shown - max)) more line(s); run foxguard on the files to see them."
    echo "[pre-push] foxguard findings are warnings; the push is not blocked by them."
  fi
  return 0
}

# sec_pre_push <refs-file> <remote-name> <url>: every security step of a push
# (git's two pre-push arguments). 1 refuses it.
sec_pre_push() {
  sec_private_names "$1" "${2:-}" "${3:-}" || return 1
  sec_sensitive_push "$1" "${2:-}" || return 1
  sec_foxguard_push "$1" "${2:-}"
  return 0
}

# sec_pre_commit: sensitive data in the staged lines. Exit 2 warns here and does
# not block: the push runs the same check and refuses then.
sec_pre_commit() {
  local gate rc
  gate="$(sec_find check_sensitive.sh)" || {
    echo "[pre-commit] check_sensitive.sh not found; staged lines NOT checked (the push refuses until it is found)." >&2
    return 0
  }
  bash "$gate" --staged
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) echo "[pre-commit] Sensitive data in the staged lines; commit refused." >&2; return 1 ;;
    *) echo "[pre-commit] sensitive-data check could not run (exit $rc); commit allowed, the push will check again." >&2; return 0 ;;
  esac
}

# sec_commit_msg <file>: a private name or sensitive data in the message.
sec_commit_msg() {
  local msg="$1" gate rc
  if gate="$(sec_find check_private_names.sh)"; then
    bash "$gate" --file "$msg" --only-public
    rc=$?
    if [[ "$rc" -eq 1 ]]; then
      echo "[commit-msg] This message names a private repository. Cite it by its code instead." >&2
      echo "[commit-msg] To override:  PRIVATE_NAMES_ALLOW=<term> git commit ..." >&2
      echo "[commit-msg]              or git commit --no-verify" >&2
      return 1
    elif [[ "$rc" -ne 0 ]]; then
      # Could not check. A missing list is a setup problem, not a clean message,
      # and the distinction is the whole point of the separate exit code.
      echo "[commit-msg] the private-name check could not run (exit $rc); commit allowed." >&2
      echo "[commit-msg] Generate the name list to enable it." >&2
    fi
  else
    # 127 territory: the check is not installed here. Saying so beats both a
    # silent pass and a refusal the author cannot act on.
    echo "[commit-msg] check_private_names.sh not found; private-name check skipped." >&2
  fi
  if gate="$(sec_find check_sensitive.sh)"; then
    # git keeps the template's comment lines in the file until it strips them.
    grep -v '^#' "$msg" > "$msg.sensitive" 2>/dev/null || true
    bash "$gate" --file "$msg.sensitive"
    rc=$?
    rm -f "$msg.sensitive"
    case "$rc" in
      0) ;;
      1) echo "[commit-msg] Sensitive data in the message; commit refused." >&2; return 1 ;;
      *) echo "[commit-msg] sensitive-data check could not run (exit $rc); commit allowed." >&2 ;;
    esac
  fi
  return 0
}
