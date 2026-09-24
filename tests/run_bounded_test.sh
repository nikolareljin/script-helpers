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

# A scratch dir for the probes and the parallel logs at the end.
work="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$work"; fi' EXIT

# 1) The guard's semantics, with no signals and no timing: run the trap body in
#    a subshell and in the owning shell, and check which one removes the tree.
#
#    The control is the first case. An unguarded body deletes from a subshell,
#    so if that stopped being true this file would be asserting nothing.
ctl="$(mktemp -d)"
( rm -rf "$ctl" )
if [[ -d "$ctl" ]]; then
  error "control: an unguarded cleanup body did not delete from a subshell, so nothing below is meaningful"
else
  note "control: an unguarded cleanup body deletes the tree from a subshell"
fi
rm -rf "$ctl"

guarded_body() { if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$1"; fi; }

# bash 3.2 has no $BASHPID, so the guard cannot tell a subshell from the owner
# there. That costs nothing: see the note below -- 3.2 never runs an inherited
# EXIT trap on a signalled subshell in the first place.
subj="$(mktemp -d)"
( guarded_body "$subj" )
if [[ -n "${BASHPID-}" ]]; then
  if [[ -d "$subj" ]]; then
    note "the guarded body is a no-op in a subshell"
  else
    error "the guarded body deleted the tree from a subshell"
  fi
else
  note "bash ${BASH_VERSION} has no \$BASHPID, so the guard does not discriminate here (see below)"
fi
rm -rf "$subj"

# ...and it must still clean up when the owner runs it, or every suite leaks.
own="$(mktemp -d)"
guarded_body "$own"
if [[ -d "$own" ]]; then
  error "the guarded body did not remove the tree in the shell that owns it: every suite would leak"
else
  note "the guarded body still removes the tree in the owning shell"
fi
rm -rf "$own"

# 2) The trigger, for the record. A subshell runs the inherited EXIT trap only
#    when the signal lands during its startup, not once it is blocked in the
#    command -- so the rate is a property of the machine, not of the fix, and
#    it is reported rather than asserted. Two runners disagreed about it: this
#    is what made the original failures look random.
#
#    "$BASH", not `bash`: a macOS runner with Homebrew has a 5.x bash ahead of
#    /bin/bash on PATH, and the shell that matters is the one running the suite.
cat > "$work/race.sh" <<'PROBE'
fired=0
for i in $(seq 1 40); do
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  ( sleep 5; true ) >/dev/null 2>&1 & w=$!
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  [ -d "$tmp" ] || fired=$((fired+1))
  /bin/rm -rf "$tmp" 2>/dev/null
done
echo "$fired"
PROBE
rate="$("$BASH" "$work/race.sh" 2>/dev/null)"
note "observed trigger rate on this machine: ${rate:-0}/40 (bash ${BASH_VERSION})"
if [[ -z "${BASHPID-}" && "${rate:-0}" -gt 0 ]]; then
  error "bash ${BASH_VERSION} has no \$BASHPID and was expected not to reproduce this, but it did ${rate}/40"
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
for i in 1 2 3 4 5 6; do
  ( bash tests/manifest_test.sh > "$work/m$i.log" 2>&1 ) &
  ( bash tests/android_test.sh  > "$work/a$i.log" 2>&1 ) &
done
wait 2>/dev/null
hit="$(grep -lE '\[ERROR\]|No such file or directory' "$work"/m*.log "$work"/a*.log 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$hit" -eq 0 ]]; then
  note "manifest_test and android_test each pass 6 ways in parallel"
else
  error "${hit}/12 parallel runs failed: $(grep -hE '\[ERROR\]|No such file' "$work"/m*.log "$work"/a*.log 2>/dev/null | head -1)"
fi

if [[ $failures -gt 0 ]]; then
  echo "[run_bounded_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[run_bounded_test] OK"
