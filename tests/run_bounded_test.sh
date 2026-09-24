#!/usr/bin/env bash
# SCRIPT: run_bounded_test.sh
# DESCRIPTION: Guards every suite's cleanup trap against running in an inherited subshell.
# USAGE: bash tests/run_bounded_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/run_bounded_test.sh
# ----------------------------------------------------
#
# Every suite here ends with `trap ... rm -rf "$tmp" ... EXIT`. A subshell
# inherits that trap, and bash runs it there when the subshell is signalled --
# so a suite could delete its own working tree while still using it.
#
# Several suites bound a call with a watchdog:
#
#   "$@" & pid=$!
#   ( sleep "$secs"; kill -9 "$pid" ) & w=$!
#   wait "$pid"; kill "$w"
#
# `kill "$w"` is a SIGTERM, and that is enough. What followed was unrelated
# assertions failing in whichever section came next -- `gradle_assemble ... ran
# ''` in android_test, a write to a vanished directory in manifest_test --
# intermittently, on CI and on a laptop. Roughly two runs in three in isolation,
# one in five under load, which is why a re-run always "fixed" it.
#
# The fix is on the trap, not on the subshells: only the shell that set it may
# run it. Clearing the trap inside the watchdog alone was tried and is not
# enough, because the backgrounded command subshell carries it too.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[run_bounded_test] $*"; }
error() { echo "[run_bounded_test][ERROR] $*" >&2; failures=$((failures+1)); }

# 1) The control. Without it, case 2 passes whether or not the guard does
#    anything: a test that cannot reproduce the bug cannot show a fix works.
#    40 iterations, because one reproduces about two times in three -- "not once
#    in 40" would mean the mechanism is gone, not that this run was lucky.
unguarded="$(bash -c '
  deleted=0
  for i in $(seq 1 40); do
    tmp="$(mktemp -d)"
    trap "rm -rf \"$tmp\"" EXIT
    ( sleep 5; true ) >/dev/null 2>&1 & w=$!
    kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
    [ -d "$tmp" ] || deleted=$((deleted+1))
    /usr/bin/rm -rf "$tmp" 2>/dev/null
  done
  echo "$deleted"')"
if [[ "${unguarded:-0}" -gt 0 ]]; then
  note "control: an unguarded trap deletes the caller's tree when a subshell is signalled (${unguarded}/40)"
else
  error "the mechanism did not reproduce in 40 tries, so the assertion below proves nothing"
fi

# 2) The guard, with the watchdog left exactly as the suites have it.
guarded="$(bash -c '
  deleted=0
  for i in $(seq 1 40); do
    tmp="$(mktemp -d)"
    trap "if [[ \$BASHPID == \$\$ ]]; then rm -rf \"$tmp\"; fi" EXIT
    ( sleep 5; true ) >/dev/null 2>&1 & w=$!
    kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
    [ -d "$tmp" ] || deleted=$((deleted+1))
    /usr/bin/rm -rf "$tmp" 2>/dev/null
  done
  echo "$deleted"')"
if [[ "${guarded:-1}" -eq 0 ]]; then
  note "a \$BASHPID-guarded trap leaves the caller's tree alone (0/40)"
else
  error "a guarded trap still deleted the tree ${guarded}/40 times"
fi

# 3) And that the guard is actually on every suite. A new file copying the old
#    idiom is how this comes back, so it is checked in the tree.
# The literal name to look for; matches both $BASHPID and ${BASHPID-$$}.
marker="BASHPID"
unguarded_files=""
for f in tests/*.sh; do
  [[ "$(basename "$f")" == "run_bounded_test.sh" ]] && continue
  while IFS= read -r line; do
    case "$line" in
      *"$marker"*) : ;;
      *) unguarded_files="${unguarded_files} $(basename "$f")" ;;
    esac
  done < <(grep -nE "^[[:space:]]*trap .*rm -rf.* EXIT" "$f")
done
if [[ -z "$unguarded_files" ]]; then
  note "every inline cleanup trap in tests/ is guarded"
else
  error "cleanup trap with no \$BASHPID guard in:${unguarded_files}"
fi

# The same for the suites that clean up through a named function.
for f in tests/*.sh; do
  fn="$(sed -n "s/^trap \([A-Za-z_][A-Za-z0-9_]*\) EXIT$/\1/p" "$f" | head -1)"
  [[ -n "$fn" ]] || continue
  body="$(sed -n "/^${fn}() {/,/^}/p" "$f")"
  case "$body" in
    *'rm -rf'*)
      case "$body" in
        *"$marker"*) note "$(basename "$f"): ${fn}() is guarded" ;;
        *) error "$(basename "$f"): ${fn}() removes a tree with no \$BASHPID guard" ;;
      esac ;;
  esac
done

# 3b) The second half of the fix, which is what protects bash 3.2: SIGKILL
#     cannot run a trap, on any bash, and needs no version-specific variable.
#     macOS ships bash 3.2, which has no $BASHPID, so there the guard above
#     degrades to "always the owner" and this is the whole protection.
softkill=""
for f in tests/*.sh; do
  [[ "$(basename "$f")" == "run_bounded_test.sh" ]] && continue
  if grep -qE "^[[:space:]]*kill \"[\$](w|watch_pid)\"" "$f"; then
    softkill="${softkill} $(basename "$f")"
  fi
done
if [[ -z "$softkill" ]]; then
  note "every watchdog is killed with -9, which runs no trap"
else
  error "watchdog killed with SIGTERM (can run the inherited trap) in:${softkill}"
fi

# 4) The two suites this was found in, run several ways at once -- the condition
#    that made the race visible rather than rare.
tmpd="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmpd"; fi' EXIT
for i in 1 2 3 4 5 6; do
  ( bash tests/manifest_test.sh > "$tmpd/m$i.log" 2>&1 ) &
  ( bash tests/android_test.sh  > "$tmpd/a$i.log" 2>&1 ) &
done
wait 2>/dev/null
hit="$(grep -lE '\[ERROR\]|No such file or directory' "$tmpd"/m*.log "$tmpd"/a*.log 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$hit" -eq 0 ]]; then
  note "manifest_test and android_test each pass 6 ways in parallel"
else
  error "${hit}/12 parallel runs failed: $(grep -hE '\[ERROR\]|No such file' "$tmpd"/m*.log "$tmpd"/a*.log 2>/dev/null | head -1)"
fi

if [[ $failures -gt 0 ]]; then
  echo "[run_bounded_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[run_bounded_test] OK"
