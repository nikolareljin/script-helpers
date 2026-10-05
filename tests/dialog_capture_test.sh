#!/usr/bin/env bash
# SCRIPT: dialog_capture_test.sh
# DESCRIPTION: Tests for dialog_has_tty, dialog_run, dialog_capture and has_interactive_dialog_session, and the selectors that use them.
# USAGE: ./tests/dialog_capture_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dialog_capture_test.sh
# ----------------------------------------------------
#
# `choice=$(dialog --stdout --menu ...)` draws its menu on stderr. A caller that
# has redirected stderr, or runs with its streams piped, then shows a menu
# nobody can see. dialog_capture puts the screen on the terminal device and
# leaves stdout to the answer.
#
# No terminal is needed here and none is used. `dialog` is a stand-in that
# says where each of its streams went: it writes SCREEN-OUT to stdout unless
# asked for the answer there, SCREEN-ERR to stderr, and records the first line
# of its stdin. DIALOG_TTY points the functions at a plain file that stands in
# for the terminal, or at a path that cannot be opened.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[dialog_capture_test] $*"; }
error() { echo "[dialog_capture_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[dialog_capture_test]   ok  $*"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else error "$1: expected [$2], got [$3]"; fi; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging dialog

mkdir -p "$tmp/bin" "$tmp/work"
# The stand-in's own "$@", not this script's.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' \
  'log="$FAKE_DIALOG_LOG"' \
  'answer=no; for a in "$@"; do [ "$a" = "--stdout" ] && answer=yes; done' \
  'n=0; for a in "$@"; do [ "$a" = "--stdout" ] && n=$((n+1)); done' \
  'IFS= read -r key || key=""' \
  'echo "args=$*" >>"$log"; echo "stdout-flags=$n" >>"$log"; echo "stdin=$key" >>"$log"' \
  'echo "in-tmpdir=$(ls "$TMPDIR" | grep -c "^dialog.capture")" >>"$log"' \
  'echo "SCREEN-ERR" >&2' \
  'if [ "$answer" = yes ]; then if [ "${FAKE_DIALOG_RC:-0}" = 0 ]; then printf "%s\n" "${FAKE_DIALOG_ANSWER:-picked}"; else printf "%s" "${FAKE_DIALOG_PARTIAL:-}"; fi; else echo "SCREEN-OUT"; fi' \
  'exit "${FAKE_DIALOG_RC:-0}"' >"$tmp/bin/dialog"
chmod +x "$tmp/bin/dialog"
export PATH="$tmp/bin:$PATH" FAKE_DIALOG_LOG="$tmp/log" TMPDIR="$tmp/work"

tty_file="$tmp/tty"
fresh() { : >"$tmp/log"; printf 'from-the-terminal\n' >"$tty_file"; unset FAKE_DIALOG_RC FAKE_DIALOG_ANSWER; }
logged() { grep "^$1=" "$tmp/log" | tail -n 1 | cut -d= -f2-; }

# --- is there a terminal ----------------------------------------------------------
note "is there a terminal"
check "a device that opens is one" "0" "$(DIALOG_TTY="$tty_file" dialog_has_tty; echo $?)"
check "a path that is not there is not" "1" "$(DIALOG_TTY="$tmp/none/tty" dialog_has_tty; echo $?)"
if [[ "$(id -u)" != "0" ]]; then
  : >"$tmp/locked"; chmod 000 "$tmp/locked"
  check "a device that exists and cannot be opened is not" "1" "$(DIALOG_TTY="$tmp/locked" dialog_has_tty; echo $?)"
else
  ok "(running as root: the cannot-open case is skipped)"
fi
check "nothing is said when it cannot be opened" "" "$(DIALOG_TTY="$tmp/none/tty" dialog_has_tty 2>&1)"
check "a session with no terminal anywhere is not interactive" "1" "$(DIALOG_TTY="$tmp/none/tty" has_interactive_dialog_session </dev/null >/dev/null 2>&1; echo $?)"
check "a terminal device makes it interactive, whatever the streams are" "0" "$(DIALOG_TTY="$tty_file" has_interactive_dialog_session </dev/null >/dev/null 2>&1; echo $?)"

# --- an answer, with a terminal ---------------------------------------------------
note "an answer, with the screen on the terminal"
fresh; export DIALOG_TTY="$tty_file"
answer="$(FAKE_DIALOG_ANSWER=13b dialog_capture --menu "Pick" 10 40 5 a A b B </dev/null 2>"$tmp/caller-err")"; rc=$?
check "the answer comes back on stdout, and only the answer" "0:13b" "$rc:$answer"
check "the screen went to the terminal" "1" "$(grep -c "SCREEN-ERR" "$tty_file")"
check "not to the caller's stderr" "" "$(cat "$tmp/caller-err")"
check "keys are read from the terminal, not from the caller's stdin" "from-the-terminal" "$(logged stdin)"
check "--stdout is added, once" "1" "$(logged stdout-flags)"
check "the caller's arguments arrive as given" "--stdout --menu Pick 10 40 5 a A b B" "$(logged args)"
fresh
answer="$(FAKE_DIALOG_ANSWER=13b dialog_capture --menu "Pick" 10 40 5 a A </dev/null 2>/dev/null)"
check "a caller that threw stderr away still gets the screen on the terminal" "13b:1" "$answer:$(grep -c "SCREEN-ERR" "$tty_file")"
fresh
answer="$(FAKE_DIALOG_RC=1 dialog_capture --menu "Pick" 10 40 5 a A </dev/null 2>/dev/null)"; rc=$?
check "cancel returns dialog's status and prints nothing" "1:" "$rc:$answer"
answer="$(FAKE_DIALOG_RC=255 dialog_capture --menu "Pick" 10 40 5 a A </dev/null 2>/dev/null)"; rc=$?
check "escape likewise" "255:" "$rc:$answer"
answer="$(FAKE_DIALOG_RC=1 FAKE_DIALOG_PARTIAL=half-typed dialog_capture --inputbox "Name" 10 40 </dev/null 2>/dev/null)"; rc=$?
check "what dialog wrote before a cancel is not an answer" "1:" "$rc:$answer"
check "its temporary file is made where TMPDIR says" "1" "$(logged in-tmpdir)"
check "no temporary file is left, after an answer or a cancel" "0" "$(find "$tmp/work" -type f | wc -l | tr -d ' ')"

# --- an answer, with no terminal --------------------------------------------------
note "an answer, with no terminal"
fresh; export DIALOG_TTY="$tmp/none/tty"
answer="$(printf 'from-the-caller\n' | FAKE_DIALOG_ANSWER=7b dialog_capture --menu "Pick" 10 40 5 a A 2>"$tmp/caller-err")"; rc=$?
check "the answer still comes back" "0:7b" "$rc:$answer"
check "the screen goes where the caller's stderr goes" "SCREEN-ERR" "$(cat "$tmp/caller-err")"
check "and keys come from the caller's stdin" "from-the-caller" "$(logged stdin)"

# --- a box with no answer ---------------------------------------------------------
note "a box with no answer"
fresh; export DIALOG_TTY="$tty_file"
out="$(dialog_run --msgbox "Hello" 8 40 </dev/null 2>"$tmp/caller-err")"; rc=$?
check "with a terminal, nothing reaches the caller's stdout or stderr" "0::" "$rc:$out:$(cat "$tmp/caller-err")"
check "both streams of the screen are on the terminal" "1:1" "$(grep -c "SCREEN-OUT" "$tty_file"):$(grep -c "SCREEN-ERR" "$tty_file")"
check "--stdout is not added to a box with no answer" "0" "$(logged stdout-flags)"
check "its status is dialog's" "1" "$(FAKE_DIALOG_RC=1 dialog_run --yesno "Sure?" 8 40 </dev/null >/dev/null 2>&1; echo $?)"
fresh; export DIALOG_TTY="$tmp/none/tty"
out="$(dialog_run --msgbox "Hello" 8 40 </dev/null 2>/dev/null)"
check "with no terminal it is plain dialog" "SCREEN-OUT" "$out"

# --- get_value --------------------------------------------------------------------
note "get_value"
# dialog writes an inputbox's answer to stderr; this stand-in for that mode.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'IFS= read -r key || key=""' 'echo "stdin=$key" >>"$FAKE_DIALOG_LOG"' 'echo "SCREEN-OUT"' \
  '[ "${FAKE_DIALOG_RC:-0}" = 0 ] && printf "%s" "${FAKE_DIALOG_ANSWER:-typed}" >&2' 'exit "${FAKE_DIALOG_RC:-0}"' >"$tmp/bin/dialog"
fresh; export DIALOG_TTY="$tty_file"
value="$(FAKE_DIALOG_ANSWER="typed value" get_value "Title" "Message" "default" </dev/null 2>/dev/null)"; rc=$?
check "the typed value comes back, and only it" "0:typed value" "$rc:$value"
check "the screen went to the terminal" "1" "$(grep -c "SCREEN-OUT" "$tty_file")"
check "cancel is a failure with nothing printed" "1:" "$(FAKE_DIALOG_RC=1 get_value "T" "M" </dev/null 2>/dev/null; echo "$?:")"
fresh; export DIALOG_TTY="$tmp/none/tty"
value="$(FAKE_DIALOG_ANSWER="typed" get_value "Title" "Message" </dev/null 2>/dev/null)"
check "with no terminal the value still comes back (the screen is in it: plain dialog's own behaviour)" "SCREEN-OUT
typed" "$value"

# --- the selectors ----------------------------------------------------------------
note "the selectors that use them"
if command -v jq >/dev/null 2>&1; then
  shlib_import os file json env ollama
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' \
    'n=0; for a in "$@"; do [ "$a" = "--stdout" ] && n=$((n+1)); done' \
    'echo "stdout-flags=$n" >>"$FAKE_DIALOG_LOG"; echo "args=$*" >>"$FAKE_DIALOG_LOG"' \
    'echo "SCREEN-ERR" >&2' '[ "${FAKE_DIALOG_RC:-0}" = 0 ] && printf "%s\n" "${FAKE_DIALOG_ANSWER:-picked}"' 'exit "${FAKE_DIALOG_RC:-0}"' >"$tmp/bin/dialog"
  printf '[{"name":"alpha","sizes":["7b","13b"]},{"name":"beta","sizes":[]}]\n' >"$tmp/models.json"
  fresh; export DIALOG_TTY="$tty_file"
  size="$(FAKE_DIALOG_ANSWER=13b ollama_dialog_select_size "$tmp/models.json" alpha 7b </dev/null 2>/dev/null)"; rc=$?
  check "the size menu returns its choice with the caller's stderr thrown away" "0:13b" "$rc:$size"
  check "its screen was on the terminal" "1" "$(grep -c "SCREEN-ERR" "$tty_file")"
  check "--stdout reaches dialog once, not twice" "1" "$(logged stdout-flags)"
  case "$(logged args)" in
    *"--default-item 7b --menu"*) ok "the current size is still the default item" ;;
    *) error "default item lost: $(logged args)" ;;
  esac
  fresh
  size="$(FAKE_DIALOG_ANSWER=7b ollama_dialog_select_size "$tmp/models.json" alpha </dev/null 2>/dev/null)"
  check "with no current size: the choice, and --stdout still once" "7b:1" "$size:$(logged stdout-flags)"
  check "cancelling the size menu is 2, a cancel, not a failure" "2" "$(FAKE_DIALOG_RC=1 ollama_dialog_select_size "$tmp/models.json" alpha </dev/null >/dev/null 2>&1; echo $?)"
  check "escape too" "2" "$(FAKE_DIALOG_RC=255 ollama_dialog_select_size "$tmp/models.json" alpha </dev/null >/dev/null 2>&1; echo $?)"
  check "a model with no sizes asks nothing" "latest:" "$(: >"$tmp/log"; ollama_dialog_select_size "$tmp/models.json" beta </dev/null 2>/dev/null):$(cat "$tmp/log")"
else
  note "SKIP: jq is needed for the selector cases"
fi

for fn in dialog_has_tty dialog_run dialog_capture has_interactive_dialog_session; do
  if grep -q "^- ${fn}" docs/modules/dialog.md; then ok "$fn is documented"; else error "$fn is not in docs/modules/dialog.md"; fi
done

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
