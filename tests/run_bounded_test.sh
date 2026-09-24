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

# A scratch dir for the two probe scripts below and the parallel logs at the end.
work="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$work"; fi' EXIT

# The probe: set a cleanup trap, signal a subshell, report whether the tree
# survived. Written twice, once with the guard and once without.
write_probe() {   # <path> <trap-body>
  cat > "$1" <<PROBE
deleted=0
for i in \$(seq 1 40); do
  tmp="\$(mktemp -d)"
  trap '$2' EXIT
  ( sleep 5; true ) >/dev/null 2>&1 & w=\$!
  kill "\$w" 2>/dev/null; wait "\$w" 2>/dev/null
  [ -d "\$tmp" ] || deleted=\$((deleted+1))
  /bin/rm -rf "\$tmp" 2>/dev/null
done
echo "\$deleted"
PROBE
}
# shellcheck disable=SC2016  # the trap body is written out literally, not expanded here
write_probe "$work/unguarded.sh" 'rm -rf "$tmp"'
# shellcheck disable=SC2016  # the trap body is written out literally, not expanded here
write_probe "$work/guarded.sh"   'if [ "${BASHPID-$$}" = "$$" ]; then rm -rf "$tmp"; fi'

# 1) The control. Without it, case 2 passes whether or not the guard does
#    anything: a test that cannot reproduce the bug cannot show a fix works.
#
#    It is bash 4+ only. bash 3.2 -- what macOS ships, and what the macos job
#    runs this under -- does not run an inherited EXIT trap when the subshell
#    is signalled: 0/20 there against 10/20 on 5.2. So what to expect depends
#    on the shell, and both directions are asserted rather than one skipped.
#
#    "$BASH", not `bash`: the shell that matters is the one running this suite,
#    and a macOS runner with Homebrew has a 5.x `bash` ahead of /bin/bash.
# shellcheck disable=SC2016  # $BASHPID must be evaluated by that shell, not this one
has_bashpid="$("$BASH" -c 'echo "${BASHPID-}"')"
unguarded="$("$BASH" "$work/unguarded.sh" 2>/dev/null)"

if [[ -n "$has_bashpid" ]]; then
  if [[ "${unguarded:-0}" -gt 0 ]]; then
    note "control: an unguarded trap deletes the caller's tree when a subshell is signalled (${unguarded}/40)"
  else
    error "the mechanism did not reproduce in 40 tries on bash ${BASH_VERSION}, so the assertion below proves nothing"
  fi
else
  if [[ "${unguarded:-1}" -eq 0 ]]; then
    note "bash ${BASH_VERSION} does not run an inherited EXIT trap on a signalled subshell (0/40); the race cannot happen here"
  else
    error "bash ${BASH_VERSION} was expected not to reproduce this, but it did ${unguarded}/40"
  fi
fi

# 2) The guard, with the watchdog left exactly as the suites have it. Expected
#    to hold on every shell: on bash 4+ because the guard refuses, on bash 3.2
#    because there is nothing to refuse.
guarded="$("$BASH" "$work/guarded.sh" 2>/dev/null)"
if [[ "${guarded:-1}" -eq 0 ]]; then
  note "a guarded trap leaves the caller's tree alone (0/40)"
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
