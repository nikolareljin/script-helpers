#!/usr/bin/env bash
# SCRIPT: dialog_capture_test.sh
# DESCRIPTION: Tests for dialog_has_tty, dialog_run, dialog_gauge, dialog_capture and has_interactive_dialog_session, and the selectors that use them.
# USAGE: ./tests/dialog_capture_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dialog_capture_test.sh
# ----------------------------------------------------
#
# dialog draws a box on its standard output unless it is asked for the answer
# there, so `value=$(dialog --inputbox ...)` and `$(dialog --msgbox ...)` put
# the screen into the caller's variable and show nobody anything. The
# functions under test put the screen on the terminal device and leave stdout
# to the answer.
#
# No terminal is needed here and none is used. `dialog` is a stand-in that
# says where each of its streams went: it writes SCREEN-OUT to stdout unless
# asked for the answer there, SCREEN-ERR to stderr, and records the first line
# of its stdin. SHLIB_SHLIB_DIALOG_TTY points the functions at a plain file that
# stands in for the terminal, or at a path that is not one. What the real
# program does on a real terminal is tests/dialog_pty_test.sh.
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
  '[ "$1" = "--help" ] && { echo "help=asked" >>"$FAKE_DIALOG_LOG"; printf "cdialog (ComeOn Dialog!) version 1.3-stand-in\nUsage: dialog <options>\n  --stdout --menu --checklist --inputbox --passwordbox --msgbox --infobox --yesno --gauge --title --default-item --defaultno --insecure --no-shadow\n"; exit 0; }' \
  'log="$FAKE_DIALOG_LOG"' \
  'answer=no; for a in "$@"; do [ "$a" = "--stdout" ] && answer=yes; done' \
  'n=0; for a in "$@"; do [ "$a" = "--stdout" ] && n=$((n+1)); done' \
  'IFS= read -r key || key=""' \
  'echo "args=$*" >>"$log"; echo "stdout-flags=$n" >>"$log"; echo "stdin=$key" >>"$log"' \
  'echo "in-tmpdir=$(ls "$TMPDIR" | wc -l | tr -d " ")" >>"$log"' \
  'echo "SCREEN-ERR" >&2' \
  'if [ "$answer" = yes ]; then if [ "${FAKE_DIALOG_RC:-0}" = 0 ]; then printf "%s\n" "${FAKE_DIALOG_ANSWER-picked}"; else printf "%s" "${FAKE_DIALOG_PARTIAL:-}"; fi; else echo "SCREEN-OUT"; fi' \
  'exit "${FAKE_DIALOG_RC:-0}"' >"$tmp/bin/dialog"
chmod +x "$tmp/bin/dialog"
export PATH="$tmp/bin:$PATH" FAKE_DIALOG_LOG="$tmp/log" TMPDIR="$tmp/work"

tty_file="$tmp/tty"
fresh() { : >"$tmp/log"; printf 'from-the-terminal\n' >"$tty_file"; unset FAKE_DIALOG_RC FAKE_DIALOG_ANSWER; }
logged() { grep "^$1=" "$tmp/log" | tail -n 1 | cut -d= -f2-; }

# --- is there a terminal ----------------------------------------------------------
note "is there a terminal"
printf 'from-the-terminal\n' >"$tty_file"
check "a device that opens is one" "0" "$(SHLIB_DIALOG_TTY="$tty_file" dialog_has_tty; echo $?)"
check "a path whose directory is not there is not" "1" "$(SHLIB_DIALOG_TTY="$tmp/none/tty" dialog_has_tty; echo $?)"
check "a path that is not there, in a directory that is, is not" "1" "$(SHLIB_DIALOG_TTY="$tmp/typo-tty" dialog_has_tty; echo $?)"
check "and asking did not create it" "no" "$([[ -e "$tmp/typo-tty" ]] && echo yes || echo no)"
check "nor did asking whether the session is interactive" "1:no" "$(SHLIB_DIALOG_TTY="$tmp/typo-2" has_interactive_dialog_session </dev/null >/dev/null 2>&1; echo "$?:$([[ -e "$tmp/typo-2" ]] && echo yes || echo no)")"
check "a directory is not a terminal" "1" "$(SHLIB_DIALOG_TTY="$tmp" dialog_has_tty; echo $?)"
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$tmp/fifo" 2>/dev/null; then
  # Opening a FIFO waits for the other end. Asked in the background and given
  # five seconds, so that a version which opens it fails here, not hangs here.
  ( SHLIB_DIALOG_TTY="$tmp/fifo" dialog_has_tty; echo "$?" >"$tmp/fifo.answer" ) &
  asker=$!
  for _ in $(seq 1 50); do [[ -s "$tmp/fifo.answer" ]] && break; sleep 0.1; done
  if [[ -s "$tmp/fifo.answer" ]]; then
    check "a FIFO is not a terminal" "1" "$(cat "$tmp/fifo.answer")"
  else
    error "asking about a FIFO did not come back: it was opened, and that waits"
    # Let the stuck open go, so nothing outlives this test: opening the FIFO
    # both ways never waits, and gives the reader its other end.
    ( exec 9<>"$tmp/fifo"; sleep 1 ) 2>/dev/null
  fi
  wait "$asker" 2>/dev/null
fi
if [[ "$(id -u)" != "0" ]]; then
  : >"$tmp/locked"; chmod 000 "$tmp/locked"
  check "a device that exists and cannot be opened is not" "1" "$(SHLIB_DIALOG_TTY="$tmp/locked" dialog_has_tty; echo $?)"
  : >"$tmp/readonly"; chmod 400 "$tmp/readonly"
  check "nor one that can only be read" "1" "$(SHLIB_DIALOG_TTY="$tmp/readonly" dialog_has_tty; echo $?)"
else
  ok "(running as root: the cannot-open cases are skipped)"
fi
check "nothing is said when it cannot be opened" "" "$(SHLIB_DIALOG_TTY="$tmp/none/tty" dialog_has_tty 2>&1)"
check "the variable dialog itself uses is not this one" "1" "$(DIALOG_TTY="$tty_file" SHLIB_DIALOG_TTY="$tmp/none/tty" dialog_has_tty; echo $?)"
check "a session with no terminal anywhere is not interactive" "1" "$(SHLIB_DIALOG_TTY="$tmp/none/tty" has_interactive_dialog_session </dev/null >/dev/null 2>&1; echo $?)"
check "a terminal device makes it interactive, whatever the streams are" "0" "$(SHLIB_DIALOG_TTY="$tty_file" has_interactive_dialog_session </dev/null >/dev/null 2>&1; echo $?)"
# With nothing set the device is /dev/tty. This process may or may not have a
# controlling terminal; either way the answer is the one opening it gives.
if ( exec 3<>/dev/tty ) 2>/dev/null; then expected=0; else expected=1; fi
check "with nothing set, the device asked is /dev/tty" "$expected" "$(unset SHLIB_DIALOG_TTY; dialog_has_tty; echo $?)"

# --- an answer, with a terminal ---------------------------------------------------
note "an answer, with the screen on the terminal"
fresh; export SHLIB_DIALOG_TTY="$tty_file"
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
check "nothing is written to disk for an answer: not while dialog runs" "0" "$(logged in-tmpdir)"
check "and not afterwards" "0" "$(find "$tmp/work" -type f | wc -l | tr -d ' ')"
answer="$(FAKE_DIALOG_ANSWER="two words" dialog_capture --inputbox "Name" 10 40 </dev/null 2>/dev/null)"
check "an answer with a space comes back whole" "two words" "$answer"

# --- an answer, with no terminal --------------------------------------------------
note "an answer, with no terminal"
fresh; export SHLIB_DIALOG_TTY="$tmp/none/tty"
answer="$(printf 'from-the-caller\n' | FAKE_DIALOG_ANSWER=7b dialog_capture --menu "Pick" 10 40 5 a A 2>"$tmp/caller-err")"; rc=$?
check "the answer still comes back" "0:7b" "$rc:$answer"
check "the screen goes where the caller's stderr goes" "SCREEN-ERR" "$(cat "$tmp/caller-err")"
check "and keys come from the caller's stdin" "from-the-caller" "$(logged stdin)"

# --- a call dialog would not understand ---------------------------------------------
# For an unknown option, or a box with no arguments, dialog prints its help
# text to stdout and exits 0. Through dialog_run that 0 would read as "Yes";
# through dialog_capture the help text would be the answer.
note "a call dialog would not understand"
fresh; export SHLIB_DIALOG_TTY="$tty_file"
check "a typo in a yes/no is 255, not 0 (Yes)" "255" "$(dialog_run --defaultno --yesn "Delete?" 6 30 </dev/null 2>"$tmp/caller-err"; echo $?)"
check "it says which option, on the caller's stderr" "1" "$(grep -c -- "no option '--yesn'" "$tmp/caller-err")"
check "and no box was run (only --help was asked)" "0" "$(grep -c '^args=' "$tmp/log")"
check "a typo among the options of a menu: 255 and no answer" "255:" "$(answer="$(dialog_capture --default-itm a --menu Pick 10 40 2 a A </dev/null 2>/dev/null)"; echo "$?:$answer")"
check "a typo in a gauge" "255" "$(printf '10\n' | dialog_gauge --gage "Working" 7 40 0 2>/dev/null; echo $?)"
check "a text argument that starts with -- is left to dialog" "0:picked" "$(answer="$(dialog_capture --menu "-- pick --" 10 40 2 a A </dev/null 2>/dev/null)"; echo "$?:$answer")"
# dialog's help text as the answer (a box with no arguments): not an answer.
fresh
check "help text in place of an answer is 255 and nothing is printed" "255:" "$(answer="$(FAKE_DIALOG_ANSWER="$(printf 'cdialog (ComeOn Dialog!) version 1.3\nUsage: dialog <options>\n')" dialog_capture --menu </dev/null 2>/dev/null)"; echo "$?:$answer")"
check "a real two-line answer is not taken for help text" "0:a
b" "$(answer="$(FAKE_DIALOG_ANSWER="$(printf 'a\nb')" dialog_capture --checklist Pick 10 40 2 a A on b B on </dev/null 2>/dev/null)"; echo "$?:$answer")"
check "the option list is read from dialog once" "1" "$(: >"$tmp/log"; _DIALOG_KNOWN_OPTIONS=""; dialog_run --msgbox Hi 6 30 </dev/null >/dev/null 2>&1; dialog_run --msgbox Hi 6 30 </dev/null >/dev/null 2>&1; grep -c 'help=asked' "$tmp/log")"

# --- a box with no answer ---------------------------------------------------------
note "a box with no answer"
fresh; export SHLIB_DIALOG_TTY="$tty_file"
out="$(dialog_run --msgbox "Hello" 8 40 </dev/null 2>"$tmp/caller-err")"; rc=$?
check "with a terminal, nothing reaches the caller's stdout or stderr" "0::" "$rc:$out:$(cat "$tmp/caller-err")"
check "both streams of the screen are on the terminal" "1:1" "$(grep -c "SCREEN-OUT" "$tty_file"):$(grep -c "SCREEN-ERR" "$tty_file")"
check "--stdout is not added to a box with no answer" "0" "$(logged stdout-flags)"
check "its status is dialog's" "1" "$(FAKE_DIALOG_RC=1 dialog_run --yesno "Sure?" 8 40 </dev/null >/dev/null 2>&1; echo $?)"
fresh
printf 'from-the-caller\n' | dialog_run --yesno "Sure?" 8 40 >/dev/null 2>&1
check "keys come from the terminal, not from the caller's stdin" "from-the-terminal" "$(logged stdin)"
fresh; export SHLIB_DIALOG_TTY="$tmp/none/tty"
out="$(dialog_run --msgbox "Hello" 8 40 </dev/null 2>/dev/null)"
check "with no terminal it is plain dialog" "SCREEN-OUT" "$out"

# --- a gauge ----------------------------------------------------------------------
note "a gauge"
fresh; export SHLIB_DIALOG_TTY="$tty_file"
out="$(printf 'from-the-caller\n' | dialog_gauge --gauge "Working" 7 40 0 2>"$tmp/caller-err")"; rc=$?
check "with a terminal, the screen does not reach the caller's stdout" "0:" "$rc:$out"
check "it is on the terminal" "1" "$(grep -c "SCREEN-OUT" "$tty_file")"
check "its progress is read from the caller's stdin, not from the terminal" "from-the-caller" "$(logged stdin)"
check "--stdout is not added to a gauge" "0" "$(logged stdout-flags)"
check "its status is dialog's" "3" "$(printf '10\n' | FAKE_DIALOG_RC=3 dialog_gauge --gauge "Working" 7 40 0 >/dev/null 2>&1; echo $?)"
fresh; export SHLIB_DIALOG_TTY="$tmp/none/tty"
out="$(printf '10\n' | dialog_gauge --gauge "Working" 7 40 0 2>/dev/null)"
check "with no terminal it is plain dialog" "SCREEN-OUT" "$out"

# --- get_value --------------------------------------------------------------------
note "get_value"
fresh; export SHLIB_DIALOG_TTY="$tty_file"
value="$(FAKE_DIALOG_ANSWER="typed value" get_value "The title" "The message" "the default" </dev/null 2>/dev/null)"; rc=$?
check "the typed value comes back, and only it" "0:typed value" "$rc:$value"
check "the screen went to the terminal" "1" "$(grep -c "SCREEN-ERR" "$tty_file")"
check "title, message and default reach dialog" "--stdout --title The title --inputbox The message 10 60 the default" "$(logged args)"
check "keys come from the terminal" "from-the-terminal" "$(logged stdin)"
value="$(FAKE_DIALOG_RC=1 get_value "T" "M" </dev/null 2>"$tmp/caller-err")"; rc=$?
check "cancel is a failure with nothing on stdout" "1:" "$rc:$value"
check "and its message is on stderr" "1" "$(grep -c "User pressed Cancel" "$tmp/caller-err")"
value="$(FAKE_DIALOG_ANSWER="" get_value "T" "M" </dev/null 2>/dev/null)"; rc=$?
check "an empty answer is a failure too" "1:" "$rc:$value"
fresh; export SHLIB_DIALOG_TTY="$tmp/none/tty"
value="$(printf 'from-the-caller\n' | FAKE_DIALOG_ANSWER="typed" get_value "Title" "Message" 2>/dev/null)"
check "with no terminal the value still comes back, and only it" "typed" "$value"
# A PATH with every directory that holds a dialog taken out, and this same bash.
no_dialog_path=""
old_ifs="$IFS"; IFS=":"
for dir in $PATH; do
  [[ -n "$dir" && ! -x "$dir/dialog" ]] && no_dialog_path="${no_dialog_path}${no_dialog_path:+:}${dir}"
done
IFS="$old_ifs"
value="$(PATH="$no_dialog_path" "$BASH" -c 'source ./helpers.sh; shlib_import logging dialog; get_value T M' 2>"$tmp/caller-err")"; rc=$?
check "with dialog not installed: a failure, and the message is not the value" "1:" "$rc:$value"
check "the message is on stderr" "1" "$(grep -c "Dialog is not installed" "$tmp/caller-err")"

# --- the callers -------------------------------------------------------------------
# Each call site, not only the function it goes through: a caller put back on
# plain `dialog` passes every test above.
note "the callers: the download gauge and the hub setup's prompts"
fresh; export SHLIB_DIALOG_TTY="$tty_file"
if command -v curl >/dev/null 2>&1; then
  printf 'payload\n' >"$tmp/src.bin"
  out="$(dialog_download_file "file://$tmp/src.bin" "$tmp/dst.bin" curl 2>/dev/null)"
  check "the download gauge is on the terminal, not in the caller's stdout" "0:1" "$(grep -c "SCREEN-OUT" <<<"$out"):$(grep -c "SCREEN-OUT" "$tty_file")"
else
  ok "(no curl: the download gauge is not run)"
fi
# (The model pull gauge draws only when stderr is a terminal: it is in
# tests/dialog_pty_test.sh.)
# The stand-in reads its key from stdin, so a prompt that is answered "from
# the terminal" went through dialog_capture; plain dialog would read /dev/null.
fresh
out="$(shlib_import hub >/dev/null 2>&1; HUB_UI=dialog FAKE_DIALOG_ANSWER=b _hub__ui_menu "Title" "Pick" a a First b Second </dev/null 2>/dev/null)"
check "the hub's menu is answered from the terminal" "b:from-the-terminal" "$out:$(logged stdin)"
fresh
out="$(shlib_import hub >/dev/null 2>&1; HUB_UI=dialog FAKE_DIALOG_ANSWER=typed _hub__ui_input "Title" "Name" "default" </dev/null 2>/dev/null)"
check "its input too" "typed:from-the-terminal" "$out:$(logged stdin)"
fresh
out="$(shlib_import hub >/dev/null 2>&1; HUB_UI=dialog FAKE_DIALOG_ANSWER=s3cret _hub__ui_secret "Title" "Key" </dev/null 2>/dev/null)"
check "and its secret, which is drawn on the terminal and nowhere else" "s3cret:from-the-terminal:0" "$out:$(logged stdin):$(grep -c "s3cret" "$tty_file")"

# --- the selectors ----------------------------------------------------------------
note "the selectors that use them"
if command -v jq >/dev/null 2>&1; then
  shlib_import os file json env ollama
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' \
  '[ "$1" = "--help" ] && { echo "help=asked" >>"$FAKE_DIALOG_LOG"; printf "cdialog (ComeOn Dialog!) version 1.3-stand-in\nUsage: dialog <options>\n  --stdout --menu --checklist --inputbox --passwordbox --msgbox --infobox --yesno --gauge --title --default-item --defaultno --insecure --no-shadow\n"; exit 0; }' \
    'n=0; for a in "$@"; do [ "$a" = "--stdout" ] && n=$((n+1)); done' \
    'echo "stdout-flags=$n" >>"$FAKE_DIALOG_LOG"; echo "args=$*" >>"$FAKE_DIALOG_LOG"' \
    'echo "SCREEN-ERR" >&2' '[ "${FAKE_DIALOG_RC:-0}" = 0 ] && printf "%s\n" "${FAKE_DIALOG_ANSWER-picked}"' 'exit "${FAKE_DIALOG_RC:-0}"' >"$tmp/bin/dialog"
  printf '[{"name":"alpha","sizes":["7b","13b"]},{"name":"beta","sizes":[]}]\n' >"$tmp/models.json"
  fresh; export SHLIB_DIALOG_TTY="$tty_file"
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
  fresh
  size="$(FAKE_DIALOG_ANSWER=7b ollama_dialog_select_size "$tmp/models.json" alpha 99b </dev/null 2>/dev/null)"
  case "$(logged args)" in
    *--default-item*) error "a current size that is not listed was made the default item: $(logged args)" ;;
    *) ok "a current size that is not listed is not made the default item" ;;
  esac
  check "an empty answer from the size menu is a cancel" "2" "$(FAKE_DIALOG_ANSWER="" ollama_dialog_select_size "$tmp/models.json" alpha </dev/null >/dev/null 2>&1; echo $?)"
  check "a model with no sizes asks nothing" "latest:" "$(: >"$tmp/log"; ollama_dialog_select_size "$tmp/models.json" beta </dev/null 2>/dev/null):$(cat "$tmp/log")"
  # A caller in strict mode has no space in IFS. The sizes were split by it,
  # so the menu had one item made of all of them.
  fresh
  size="$(IFS=$'\n\t'; FAKE_DIALOG_ANSWER=13b ollama_dialog_select_size "$tmp/models.json" alpha </dev/null 2>/dev/null)"
  check "each size is its own item for a caller whose IFS has no space" "13b:7b 7b 13b 13b" "$size:$(logged args | sed -E 's/.* 10 //')"

  note "the model menu"
  export OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu.cache.tsv"
  printf '[{"name":"alpha","description":"first","sizes":["7b"]},{"name":"beta","description":"second","sizes":[]},{"name":"gamma","description":"third","sizes":[]}]\n' >"$tmp/index.json"
  fresh; export SHLIB_DIALOG_TTY="$tty_file"
  model="$(FAKE_DIALOG_ANSWER=0002 ollama_dialog_select_model "$tmp/index.json" </dev/null 2>/dev/null)"; rc=$?
  check "the model menu returns the name behind the chosen tag" "0:beta" "$rc:$model"
  check "its screen was on the terminal, with stderr thrown away" "1" "$(grep -c "SCREEN-ERR" "$tty_file")"
  check "--stdout reaches dialog once" "1" "$(logged stdout-flags)"
  case "$(logged args)" in
    *--default-item*) error "a default item with no current model: $(logged args)" ;;
    *) ok "no current model, no default item" ;;
  esac
  fresh
  model="$(FAKE_DIALOG_ANSWER=0003 ollama_dialog_select_model "$tmp/index.json" beta </dev/null 2>/dev/null)"
  check "with a current model: the choice comes back" "gamma" "$model"
  check "and its screen was on the terminal as well" "1" "$(grep -c "SCREEN-ERR" "$tty_file")"
  check "and --stdout is still there once" "1" "$(logged stdout-flags)"
  case "$(logged args)" in
    *"--default-item 0002 --menu"*) ok "the current model is the default item" ;;
    *) error "default item: $(logged args)" ;;
  esac
  # A namespaced model (hf.co/org/model, user/model) is in the menu. The menu
  # used to drop every name with a slash, so it could not offer one.
  printf '[{"name":"zeta","description":"the last one","sizes":[]},{"name":"hf.co/org/quant","description":"from the hub","sizes":["Q4"]},{"name":"team/tool","sizes":[]}]\n' >"$tmp/index-ns.json"
  : >"$tmp/log"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-ns.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-ns.json" </dev/null 2>/dev/null)"; rc=$?
  check "a namespaced model is offered and can be chosen" "0:hf.co/org/quant" "$rc:$model"
  check "all three are in the menu" "3" "$(grep -o -E 'hf.co/org/quant|team/tool|zeta' "$tmp/log" | sort -u | wc -l | tr -d ' ')"
  # A row without sizes and with a description. Tab is whitespace to `read`,
  # so the empty column vanished and the description was shown as the sizes.
  case "$(logged args)" in
    *"hf.co/org/quant | sizes: Q4 | from the hub"*"team/tool | sizes: latest"*"zeta | sizes: latest | the last one"*) ok "a model without sizes says latest, and its description stays a description" ;;
    *) error "sizes and descriptions: $(logged args)" ;;
  esac
  # A description that is not text, or has a control character in it.
  printf '[{"name":"num","description":42},{"name":"esc","description":"a\\u001b[2Jb\\tc"}]\n' >"$tmp/index-desc.json"
  : >"$tmp/log"
  OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-desc.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-desc.json" </dev/null >/dev/null 2>&1
  case "$(logged args)" in
    *"esc | sizes: latest | a [2Jb c"*"num | sizes: latest | 42"*) ok "a description is shown as text, without its control characters" ;;
    *) error "odd descriptions: $(logged args | od -c | head -5)" ;;
  esac

  # The menu follows the index: an entry added after the menu was last built
  # is offered at once. The cache used to be reused for half an hour. The
  # times are set, not waited for: the index is given a later one.
  printf '[{"name":"zeta","sizes":[]}]\n' >"$tmp/index-grow.json"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-grow.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-grow.json" </dev/null 2>/dev/null)"
  check "(the menu before the index changes)" "zeta" "$model"
  printf '[{"name":"zeta","sizes":[]},{"name":"aaa/new","sizes":[]}]\n' >"$tmp/index-grow.json"
  touch -t 209901010000 "$tmp/index-grow.json"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-grow.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-grow.json" </dev/null 2>/dev/null)"
  check "an index that is newer than the cache gets a new menu" "aaa/new" "$model"

  # A cache is used as it is when it was made from this index and is newer
  # than it. It is a file, so each row is held to the rule the index is: a
  # row written by hand, or by an older version, with a name that is not a
  # reference is skipped, and a row cut short still has sizes.
  hand_cache() { # hand_cache <cache> <index it claims> <rows...>
    local cache="$1" index="$2"; shift 2
    { printf '#index\t%s\n' "$(_ollama_index_id "$index")"; printf '%b\n' "$@"; } >"$cache"
  }
  printf '[{"name":"only-in-the-index"}]\n' >"$tmp/index-hand.json"; touch -t 200001010000 "$tmp/index-hand.json"
  hand_cache "$tmp/menu-hand.cache.tsv" "$tmp/index-hand.json" 'fine\tfine\tlatest\t' 'x;touch MARK\tx;touch MARK\tlatest\t' 'also/fine\talso/fine\t7b\tsome words' 'short\tshort' 'qwen3:\tqwen3:\tlatest\t' 'a..b\ta..b\tlatest\t'
  : >"$tmp/log"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-hand.cache.tsv" FAKE_DIALOG_ANSWER=0002 ollama_dialog_select_model "$tmp/index-hand.json" </dev/null 2>/dev/null)"
  check "a cache made from this index and newer than it is used, without its rows that are not references" "also/fine" "$model"
  case "$(logged args)" in
    *"Showing 3."*"0003 short | sizes: latest"*) ok "three rows are offered, and one cut short still says latest" ;;
    *) error "rows of a hand-written cache: $(logged args)" ;;
  esac
  # The same cache is not used for another index (a cache path the caller
  # gave, shared by two indexes), nor when it does not say which index it is
  # from, nor when it has an empty column (only a version that lost that
  # column in reading wrote one).
  printf '[{"name":"from-the-other-index"}]\n' >"$tmp/index-other.json"; touch -t 200001010000 "$tmp/index-other.json"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-hand.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-other.json" </dev/null 2>/dev/null)"
  check "a cache made from another index is made again" "from-the-other-index" "$model"
  printf 'no-header\tno-header\tlatest\t\n' >"$tmp/menu-hand.cache.tsv"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-hand.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-hand.json" </dev/null 2>/dev/null)"
  check "a cache that does not say which index it is from is made again" "only-in-the-index" "$model"
  hand_cache "$tmp/menu-hand.cache.tsv" "$tmp/index-hand.json" 'from-the-old-cache\tfrom-the-old-cache\t\twords'
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-hand.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-hand.json" </dev/null 2>/dev/null)"
  check "a cache written with an empty column is made again" "only-in-the-index" "$model"
  # Half an hour is still the limit for a cache nothing else is wrong with.
  hand_cache "$tmp/menu-hand.cache.tsv" "$tmp/index-hand.json" 'from-the-old-cache\tfrom-the-old-cache\tlatest\t'
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-hand.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-hand.json" </dev/null 2>/dev/null)"
  check "(a cache written just now is used)" "from-the-old-cache" "$model"
  hand_cache "$tmp/menu-hand.cache.tsv" "$tmp/index-hand.json" 'from-the-old-cache\tfrom-the-old-cache\tlatest\t'
  touch -t 200001020000 "$tmp/menu-hand.cache.tsv"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-hand.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-hand.json" </dev/null 2>/dev/null)"
  check "the same cache, newer than the index but older than half an hour, is made again" "only-in-the-index" "$model"
  # A line that starts with "#" is never a row, whatever its second column.
  hand_cache "$tmp/menu-hand.cache.tsv" "$tmp/index-hand.json" '#note\tnot-a-row\tlatest\t' 'a-row\ta-row\tlatest\t'
  : >"$tmp/log"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-hand.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-hand.json" </dev/null 2>/dev/null)"
  check "a line of the cache that starts with # is not offered" "a-row:1:0" "$model:$(logged args | grep -c 'Showing 1\.'):$(logged args | grep -c 'not-a-row')"

  # The index named by a relative path, as the library's own default is
  # (ollama-get-models/code/ollama_models.json). The line that says which
  # index a cache is from was read as a row and offered first: choosing 0001
  # pulled the path of the index.
  mkdir -p "$tmp/pa/idx" "$tmp/pb/idx"
  printf '[{"name":"only-in-a","sizes":["7b"]},{"name":"second-in-a"}]\n' >"$tmp/pa/idx/models.json"
  printf '[{"name":"only-in-b"}]\n' >"$tmp/pb/idx/models.json"
  touch -t 200001010000 "$tmp/pa/idx/models.json" "$tmp/pb/idx/models.json"
  : >"$tmp/log"
  model="$(cd "$tmp/pa" && unset OLLAMA_MODEL_MENU_CACHE_FILE && FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model idx/models.json </dev/null 2>/dev/null)"; rc=$?
  check "with a relative index path the first item is the first model" "0:only-in-a" "$rc:$model"
  check "and the menu has the two models, not the cache's first line" "1:0" "$(logged args | grep -c 'Showing 2\.'):$(logged args | grep -c '#index')"
  # Two indexes named by the same relative path from two directories, and one
  # cache path given by the caller: each gets its own menu.
  shared="$tmp/shared.cache.tsv"
  model="$(cd "$tmp/pa" && OLLAMA_MODEL_MENU_CACHE_FILE="$shared" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model idx/models.json </dev/null 2>/dev/null)"
  check "(the first directory's menu, through the shared cache path)" "only-in-a" "$model"
  model="$(cd "$tmp/pb" && OLLAMA_MODEL_MENU_CACHE_FILE="$shared" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model idx/models.json </dev/null 2>/dev/null)"
  check "the same relative path in another directory is another index" "only-in-b" "$model"
  # The directory is resolved from here, whatever CDPATH says, and the answer
  # is one line whatever the path holds.
  check "a relative index is found from the current directory, not through CDPATH" "$(cd "$tmp/pa/idx" && pwd -P)/models.json" "$(cd "$tmp/pa" && CDPATH="$tmp/pb" _ollama_index_id idx/models.json)"
  mkdir -p "$tmp/pa/two"$'\n'"lines"
  check "an index path with a line break in it is still named on one line" "one line" "$(id="$(_ollama_index_id "$tmp/pa/two"$'\n'"lines/models.json")"; if [[ "$id" == *$'\n'* ]]; then echo "more than one"; else echo "one line"; fi)"
  # And one index spelled three ways is one index: the cache is used again,
  # shown by a row added to it by hand.
  model="$(cd "$tmp/pa" && OLLAMA_MODEL_MENU_CACHE_FILE="$shared" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model idx/models.json </dev/null 2>/dev/null)"
  printf 'marker\tmarker\tlatest\t\n' >>"$shared"
  check "one index spelled three ways uses one cache" "marker marker marker" "$(for spelled in idx/models.json ./idx/models.json "$tmp/pa/idx/models.json"; do (cd "$tmp/pa" && OLLAMA_MODEL_MENU_CACHE_FILE="$shared" FAKE_DIALOG_ANSWER=0003 ollama_dialog_select_model "$spelled" </dev/null 2>/dev/null); done | tr '\n' ' ' | sed 's/ $//')"

  # The other shape the index may have: {"models": [...]}.
  printf '{"models":[{"name":"wrapped","sizes":["1b","2b"]},{"name":"hf.co/o/m","sizes":[]}]}\n' >"$tmp/index-obj.json"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-obj.cache.tsv" FAKE_DIALOG_ANSWER=0002 ollama_dialog_select_model "$tmp/index-obj.json" </dev/null 2>/dev/null)"; rc=$?
  check "an index wrapped in an object gives the same menu" "0:wrapped" "$rc:$model"
  check "its sizes are found" "2b" "$(FAKE_DIALOG_ANSWER=2b ollama_dialog_select_size "$tmp/index-obj.json" wrapped </dev/null 2>/dev/null)"
  check "and its names are listed" "hf.co/o/m wrapped" "$(ollama_list_models "$tmp/index-obj.json" | sort | tr '\n' ' ' | sed 's/ $//')"

  # What the index names goes into a command line and into the .env that the
  # install flow writes and load_env sources. Only a name that can be a model
  # reference is offered, and an entry that is no entry is passed over.
  cat >"$tmp/index-bad.json" <<'INDEX'
[{"name":"good","sizes":["7b","8b;touch MARK","$(id)","ok-1","-x","--help","a/b","7b:x","9b\nzz","a..b","two words",7,null]},
 "a string", 7, null, ["a list"],
 {"name":"x/y;touch MARK"},{"name":"$(id)"},{"name":"two words"},{"name":"--menu/x"},{"name":"-x"},
 {"name":""},{"description":"an entry with no name"},{"name":7},{"name":null},
 {"name":"qwen3:"},{"name":"a..b//c/"},{"name":"trailing/"},{"name":":7b"},{"name":"a::b"},
 {"name":"line\nbreak"},{"name":"tab\there"},{"name":"mod\u00e8le"},{"name":"esc\u001b[2J"},{"name":"unit\u001fsep"},
 {"name":"registry.example:5000/team/model","sizes":{"a":"7b"}},
 {"name":"hf.co/org/tagged:Q4_K_M","sizes":["7b"]}]
INDEX
  : >"$tmp/log"
  model="$(OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-bad.cache.tsv" FAKE_DIALOG_ANSWER=0003 ollama_dialog_select_model "$tmp/index-bad.json" </dev/null 2>/dev/null)"; rc=$?
  check "an index with unusable entries still gives a menu, of the usable ones" "0:registry.example:5000/team/model" "$rc:$model"
  check "three rows, and nothing of the others in the menu" "3:0" "$(grep -vc '^#' "$tmp/menu-bad.cache.tsv" | tr -d ' '):$(grep -c -e 'touch' -e 'two words' -e '--menu/x' -e '(id)' -e 'qwen3:' -e 'trailing' -e 'break' -e "$(printf '\303\250')" -e 'esc' -e 'unit' "$tmp/log")"
  case "$(logged args)" in
    *"good | sizes: 7b, ok-1 "*"hf.co/org/tagged:Q4_K_M | sizes: in the name "*) ok "the menu shows only the sizes that can be a tag, and none for a name that has its tag" ;;
    *) error "sizes shown: $(logged args)" ;;
  esac
  check "names that are not a reference are not listed either" "good hf.co/org/tagged:Q4_K_M registry.example:5000/team/model" "$(ollama_list_models "$tmp/index-bad.json" | sort | tr '\n' ' ' | sed 's/ $//')"
  check "a size that is not a tag is not offered: not an operator, not an option, not a path" "7b ok-1" "$(: >"$tmp/log"; FAKE_DIALOG_ANSWER=7b ollama_dialog_select_size "$tmp/index-bad.json" good </dev/null >/dev/null 2>&1; logged args | sed -E 's/.* 10 //' | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  check "sizes that are not a list are no sizes, and nothing is asked" "latest:" "$(: >"$tmp/log"; ollama_dialog_select_size "$tmp/index-bad.json" registry.example:5000/team/model </dev/null 2>/dev/null):$(cat "$tmp/log")"
  # A name that carries its tag is the whole reference: a size chosen for it
  # would be written to .env and never pulled.
  check "a name with a tag gets no size menu" "latest:" "$(: >"$tmp/log"; ollama_dialog_select_size "$tmp/index-bad.json" hf.co/org/tagged:Q4_K_M </dev/null 2>/dev/null):$(cat "$tmp/log")"
  # An index with no usable name gives no cache at all, not an empty one.
  printf '[{"name":"x;y"},"a string"]\n' >"$tmp/index-none.json"
  check "an index with nothing to offer is an error, and leaves no cache" "1:no" "$(ollama_prepare_model_menu_cache "$tmp/index-none.json" "$tmp/menu-none.cache.tsv" >/dev/null 2>&1; echo "$?:$(if [[ -e "$tmp/menu-none.cache.tsv" ]]; then echo yes; else echo no; fi)")"
  # An index that cannot be read is an error. It used to answer "latest".
  printf 'not json\n' >"$tmp/index-broken.json"
  check "an index jq cannot read has no sizes to offer, and says so" "1:" "$(ollama_dialog_select_size "$tmp/index-broken.json" good </dev/null 2>/dev/null; echo "$?:")"
  check "nor names to list" "1:" "$(ollama_list_models "$tmp/index-broken.json" 2>/dev/null; echo "$?:")"
  # A reader that has what it wants and leaves (`... | head -n 1`) is not a
  # failure of the list, also for a caller with pipefail. bash writes a line
  # at a time, so the reader can be gone before the last one, and SIGPIPE
  # then ended the function. `| true` leaves before the first.
  { printf '['; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do printf '{"name":"model-%s"},' "$n"; done; printf '{"name":"last"}]\n'; } >"$tmp/index-forty.json"
  pipe_failures=0
  for n in 1 2 3 4 5 6 7 8 9 10; do
    first="$(set -o pipefail; ollama_list_models "$tmp/index-forty.json" 2>"$tmp/pipe.err" | head -n 1; echo "rc=$?")"
    [[ "$first" == "model-1"$'\n'"rc=0" && ! -s "$tmp/pipe.err" ]] || pipe_failures=$((pipe_failures + 1))
  done
  check "the first name of a list, read under pipefail: ten runs, none failed and nothing on stderr" "0" "$pipe_failures"
  check "a reader that leaves without reading is not a failure either, and nothing is said" "0 0:" "$(set -o pipefail; ollama_list_models "$tmp/index-forty.json" 2>"$tmp/pipe.err" | true; echo "${PIPESTATUS[*]}:$(cat "$tmp/pipe.err")")"
  if [[ -e /dev/full ]]; then
    check "a write that fails for another reason is a failure, and says so" "1:1" "$(ollama_list_models "$tmp/index-forty.json" 2>"$tmp/pipe.err" >/dev/full; echo "$?:$(grep -c 'Could not write the model names' "$tmp/pipe.err")")"
  else
    note "SKIP: no /dev/full here, so a write that fails without a closed pipe is not exercised"
  fi
  check "and the list is the 41 names, one a line" "41:model-1:last" "$(ollama_list_models "$tmp/index-forty.json" | wc -l | tr -d ' '):$(ollama_list_models "$tmp/index-forty.json" | sed -n '1p'):$(ollama_list_models "$tmp/index-forty.json" | tail -n 1)"
  check "an index with no usable name lists nothing, and that is not a failure" "0:" "$(ollama_list_models "$tmp/index-none.json" 2>/dev/null; echo "$?:")"

  # The rule, in one function. lib/ollama_endpoint.sh has its own for the same
  # thing: the two must give one answer. This one gives it in any locale.
  shlib_import ollama_endpoint
  # The rules are pinned to the C locale. That only shows in a locale where
  # [A-Za-z] takes an accented letter, and not every machine has one: it is
  # looked for, and when there is none the cases say SKIP, not ok.
  accent="$(printf 'mod\303\250le')"
  wide_locale=""
  for locale in en_US.UTF-8 $(locale -a 2>/dev/null | grep -i -E 'utf-?8$' | grep -v -i -E '^(C|POSIX)\.'); do
    if (LC_ALL=$locale; [[ "$accent" =~ ^[A-Za-z]+$ ]]) 2>/dev/null; then wide_locale="$locale"; break; fi
  done
  rule_locales=(C)
  if [[ -z "$( (LC_ALL=C.UTF-8) 2>&1)" ]]; then rule_locales+=(C.UTF-8); fi
  if [[ -n "$wide_locale" ]]; then rule_locales+=("$wide_locale"); fi
  rule_differs=""
  for name in qwen3 qwen3:8b hf.co/org/model user/model registry.example:5000/team/model:7b Qwen3.5:4B a_b-c.d \
              '' ' ' 'qwen3:' 'qwen3/' ':7b' '/x' '-x' '--help' '.hidden' 'a..b' 'a//b' 'a::b' 'a/:b' 'a:/b' \
              'a b' 'a;b' 'a$b' 'a@b' 'a\b' "a'b" 'a"b' 'a*b' 'a?b' 'a#b' 'a%b' 'a+b' 'a=b' 'a,b' 'a~b' \
              "$(printf 'mod\303\250le')" "$(printf 'a\tb')" "$(printf 'a\033b')"; do
    for locale in "${rule_locales[@]}"; do
      one="$(LC_ALL=$locale; if _ollama_is_model_ref "$name" 2>/dev/null; then echo yes; else echo no; fi)"
      other="$(LC_ALL=C; if _ollama_ep_is_model "$name"; then echo yes; else echo no; fi)"
      [[ "$one" == "$other" ]] || rule_differs="$rule_differs [$name in $locale: menu $one, endpoint $other]"
    done
  done
  check "the menu's rule and the endpoint module's rule agree on every name tried" "" "$rule_differs"
  if [[ -n "$wide_locale" ]]; then
    # One answer per rule: a reference, a tag, a command argument, an env key.
    check "in $wide_locale, where [A-Za-z] takes an accented letter, no rule does" "no no no no" "$(LC_ALL=$wide_locale; shopt -s nocasematch
      for call in "_ollama_is_model_ref $accent" "_ollama_is_model_tag $accent" "_ollama_ref_is_arg $(printf '\303\250x')" "_ollama_env_key_ok $accent"; do
        # Split on purpose: a function and its one argument.
        # shellcheck disable=SC2086
        if $call; then echo yes; else echo no; fi
      done | tr '\n' ' ' | sed 's/ $//')"
  else
    note "SKIP: no locale here in which [A-Za-z] takes an accented letter, so the C-locale pin of the rules is not exercised"
  fi
  check "a letter with an accent is not a reference in the locales that are here (${rule_locales[*]})" "" "$(for locale in "${rule_locales[@]}"; do (LC_ALL=$locale; shopt -s nocasematch; if _ollama_is_model_ref "$accent"; then echo "$locale"; fi); done | tr '\n' ' ' | sed 's/ $//')"
  check "a tag is a name without a slash, a colon or two dots" "yes yes no no no no no" "$(for size in 7b Q4_K_M a/b 7b:x -x '' a..b; do if _ollama_is_model_tag "$size"; then echo yes; else echo no; fi; done | tr '\n' ' ' | sed 's/ $//')"

  # Case does not tell two models apart; of two that differ only by case, the
  # one written the same way is the current one.
  printf '[{"name":"alpha"},{"name":"hf.co/Org/Model-GGUF"}]\n' >"$tmp/index-case.json"
  : >"$tmp/log"
  OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-case.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-case.json" hf.co/org/model-gguf </dev/null >/dev/null 2>&1
  case "$(logged args)" in
    *"--default-item 0002 --menu"*) ok "the current model is the default item whatever its case" ;;
    *) error "default item by case: $(logged args)" ;;
  esac
  check "matching without case is not left switched on for the caller" "off" "$(shopt -q nocasematch && echo on || echo off)"
  check "nor switched off for a caller that had it on" "on" "$(shopt -s nocasematch; OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-case.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-case.json" </dev/null >/dev/null 2>&1; shopt -q nocasematch && echo on || echo off)"
  printf '[{"name":"Org/Model"},{"name":"org/model"},{"name":"ORG/model"}]\n' >"$tmp/index-twins.json"
  default_item() { : >"$tmp/log"; OLLAMA_MODEL_MENU_CACHE_FILE="$tmp/menu-twins.cache.tsv" FAKE_DIALOG_ANSWER=0001 ollama_dialog_select_model "$tmp/index-twins.json" "$1" </dev/null >/dev/null 2>&1; logged args | sed -n -E 's/.*--default-item ([0-9]+) .*/\1/p'; }
  check "of names that differ only by case, the one written the same way is the default item" "0001 0002 0003" "$(default_item Org/Model) $(default_item org/model) $(default_item ORG/model)"
  check "and written a fourth way, the first of them" "0001" "$(default_item oRg/MoDeL)"

  # A name that carries its tag is the whole reference.
  check "a size is the tag of a name without one" "hf.co/org/model:Q4" "$(ollama_model_ref hf.co/org/model Q4)"
  check "a name with a tag does not get a second" "hf.co/org/model:Q4_K_M" "$(ollama_model_ref hf.co/org/model:Q4_K_M 7b)"
  check "a port in the registry host is not a tag" "registry.example:5000/team/model:7b" "$(ollama_model_ref registry.example:5000/team/model 7b)"
  check "latest is no tag" "qwen3" "$(ollama_model_ref qwen3 latest)"

  # The install flow, with a stand-in for the ollama command. The index is a
  # directory that is not a git checkout, so nothing is cloned.
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'echo "$# args: $*" >>"$FAKE_OLLAMA_LOG"' >"$tmp/bin/ollama"; chmod +x "$tmp/bin/ollama"
  export FAKE_OLLAMA_LOG="$tmp/ollama.log"
  mkdir -p "$tmp/repo/code"
  printf '[{"name":"zeta"},{"name":"alpha"},{"name":"hf.co/org/tagged:Q4_K_M","sizes":["7b"]}]\n' >"$tmp/repo/code/ollama_models.json"
  flow() { ( unset OLLAMA_MODEL_MENU_CACHE_FILE model size; "$@" ) </dev/null >/dev/null 2>"$tmp/flow.err"; echo $?; }
  : >"$tmp/ollama.log"
  check "the install flow runs for a caller with set -u and no env file yet" "0" "$(flow bash -c 'set -u; source ./helpers.sh; shlib_import logging os file json env python dialog ollama; FAKE_DIALOG_ANSWER=0001 ollama_install_model_flow "$1"' _ "$tmp/repo")"
  check "and pulls what was chosen, as one argument" "2 args: pull alpha" "$(cat "$tmp/ollama.log")"
  : >"$tmp/ollama.log"
  check "with an env file that does not exist yet, too" "0" "$(flow bash -c 'set -u; source ./helpers.sh; shlib_import logging os file json env python dialog ollama; FAKE_DIALOG_ANSWER=0002 ollama_install_model_flow "$1" "$2"' _ "$tmp/repo" "$tmp/flow.env")"
  check "a name with a tag is pulled as it is, and no size is recorded for it" "2 args: pull hf.co/org/tagged:Q4_K_M|model=hf.co/org/tagged:Q4_K_M size=latest" "$(cat "$tmp/ollama.log")|$(tr '\n' ' ' <"$tmp/flow.env" | sed 's/ $//')"
  # The index is sorted on every run. Sorting an index that is sorted already
  # must not make it newer than its menu cache, or the cache is never reused:
  # a row added to the cache by hand is still offered on the next run.
  # The index is given an old time, so "newer" does not hang on two files
  # written within one second (bash 3.2 compares whole seconds).
  touch -t 200001010000 "$tmp/repo/code/ollama_models.json"
  printf 'marker\tmarker\tlatest\t\n' >>"$tmp/repo/code/ollama_models.model-menu.cache.tsv"
  : >"$tmp/ollama.log"
  flow bash -c 'source ./helpers.sh; shlib_import logging os file json env python dialog ollama; FAKE_DIALOG_ANSWER=0004 ollama_install_model_flow "$1"' _ "$tmp/repo" >/dev/null
  check "a second run of the flow reuses the menu cache" "2 args: pull marker" "$(cat "$tmp/ollama.log")"
  # The flow with the library's default index path, which is relative.
  mkdir -p "$tmp/relflow/ollama-get-models/code"
  printf '[{"name":"alpha","sizes":[]},{"name":"beta"}]\n' >"$tmp/relflow/ollama-get-models/code/ollama_models.json"
  : >"$tmp/ollama.log"
  flow bash -c 'cd "$2" || exit 9; source "$1/helpers.sh"; shlib_import logging os file json env python dialog ollama; FAKE_DIALOG_ANSWER=0001 ollama_install_model_flow "" flow.env' _ "$root_dir" "$tmp/relflow" >/dev/null
  check "the flow with the default, relative index pulls the first model and records it" "2 args: pull alpha|model=alpha size=latest" "$(cat "$tmp/ollama.log")|$(tr '\n' ' ' <"$tmp/relflow/flow.env" | sed 's/ $//')"

  # What reaches `ollama pull` and `ollama run` is one word that starts with a
  # letter or a digit, whoever built it.
  for bad in '' '-x' '--insecure' 'two words' ':7b'; do
    : >"$tmp/ollama.log"
    check "ollama_pull_model refuses '$bad' and runs nothing" "1:" "$(ollama_pull_model "$bad" >/dev/null 2>&1; echo "$?:$(cat "$tmp/ollama.log")")"
  done
  : >"$tmp/ollama.log"
  check "ollama_run_model refuses an option as well" "1:" "$(ollama_run_model '-x' >/dev/null 2>&1; echo "$?:$(cat "$tmp/ollama.log")")"
  : >"$tmp/ollama.log"
  check "a control character in the name is refused too" "1:" "$(ollama_pull_model "$(printf 'a\001b')" >/dev/null 2>&1; echo "$?:$(cat "$tmp/ollama.log")")"
  # The functions that take the runtime hold the model to the same rule. The
  # models directory is one of this test's, so nothing is made elsewhere.
  printf 'ollama_shared_model_store=0\nollama_local_models_dir=%s\n' "$tmp/rt-models" >"$tmp/rt.env"
  : >"$tmp/ollama.log"
  check "ollama_runtime_pull_model refuses an option and runs nothing" "1:" "$(ollama_runtime_pull_model local "$tmp/rt.env" '-x' </dev/null >/dev/null 2>&1; echo "$?:$(cat "$tmp/ollama.log")")"
  check "ollama_runtime_export_model too, and makes no directory for it" "1::no" "$(ollama_runtime_export_model local "$tmp/rt.env" '-x' "$tmp/export-out/model.bin" </dev/null >/dev/null 2>&1; echo "$?:$(cat "$tmp/ollama.log"):$(if [[ -e "$tmp/export-out" ]]; then echo yes; else echo no; fi)")"
  # It starts the model in the background: given a second to show up in the log.
  check "ollama_runtime_run_model too" "1:" "$(ollama_runtime_run_model local "$tmp/rt.env" '-x' </dev/null >/dev/null 2>&1; rc=$?; sleep 1; echo "$rc:$(cat "$tmp/ollama.log")")"
  : >"$tmp/ollama.log"
  check "and a reference goes through them as one argument" "0:2 args: pull hf.co/org/model:Q4" "$(ollama_runtime_pull_model local "$tmp/rt.env" hf.co/org/model Q4 </dev/null >/dev/null 2>&1; echo "$?:$(cat "$tmp/ollama.log")")"
  : >"$tmp/ollama.log"
  check "a reference goes through as one argument, a digest too" "0:2 args: pull hf.co/org/model:Q4|2 args: pull name@sha256:abc" "$(ollama_pull_model hf.co/org/model Q4 >/dev/null 2>&1; rc=$?; ollama_pull_model name@sha256:abc >/dev/null 2>&1; echo "$rc:$(tr '\n' '|' <"$tmp/ollama.log" | sed 's/|$//')")"
  model="$(FAKE_DIALOG_RC=1 ollama_dialog_select_model "$tmp/index.json" </dev/null 2>/dev/null)"; rc=$?
  check "cancelling the model menu prints nothing on stdout" "1:" "$rc:$model"
  unset OLLAMA_MODEL_MENU_CACHE_FILE
else
  note "SKIP: jq is needed for the selector cases"
fi

note "the distro selectors"
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' \
  '[ "$1" = "--help" ] && { echo "help=asked" >>"$FAKE_DIALOG_LOG"; printf "cdialog (ComeOn Dialog!) version 1.3-stand-in\nUsage: dialog <options>\n  --stdout --menu --checklist --inputbox --passwordbox --msgbox --infobox --yesno --gauge --title --default-item --defaultno --insecure --no-shadow\n"; exit 0; }' \
    'n=0; for a in "$@"; do [ "$a" = "--stdout" ] && n=$((n+1)); done' \
    'echo "stdout-flags=$n" >>"$FAKE_DIALOG_LOG"; echo "args=$*" >>"$FAKE_DIALOG_LOG"' \
    'echo "SCREEN-ERR" >&2' '[ "${FAKE_DIALOG_RC:-0}" = 0 ] && printf "%s\n" "${FAKE_DIALOG_ANSWER-picked}"' 'exit "${FAKE_DIALOG_RC:-0}"' >"$tmp/bin/dialog"
  # The two take the caller's DISTROS and refuse bash 3.2 (require_bash4). An
  # indexed array stands in for the associative one here, as in file_test.sh:
  # the menu is built from its keys and labels either way.
  # shellcheck disable=SC2034  # read by the two selectors
  DISTROS=("Ubuntu" "Debian")
  fresh; export SHLIB_DIALOG_TTY="$tty_file"
  one="$(FAKE_DIALOG_ANSWER=1 select_distro </dev/null 2>/dev/null)"; rc=$?
  check "one distro: the choice, with the screen on the terminal" "0:1:1" "$rc:$one:$(grep -c "SCREEN-ERR" "$tty_file")"
  check "--stdout once" "1" "$(logged stdout-flags)"
  case "$(logged args)" in *" --menu "*"0 Ubuntu"*"1 Debian"*|*" --menu "*"1 Debian"*"0 Ubuntu"*) ok "it is a menu of the caller's entries" ;; *) error "not that menu: $(logged args)" ;; esac
  fresh
  many="$(FAKE_DIALOG_ANSWER="0 1" select_multiple_distros </dev/null 2>/dev/null)"
  check "several distros: the choices" "0 1" "$many"
  check "--stdout once there too" "1" "$(logged stdout-flags)"
  case "$(logged args)" in *" --checklist "*) ok "it is a checklist" ;; *) error "not a checklist: $(logged args)" ;; esac
  one="$(FAKE_DIALOG_RC=1 select_distro </dev/null 2>"$tmp/caller-err")"; rc=$?
  check "cancel: a failure, nothing on stdout" "1:" "$rc:$one"
  check "and the message on stderr" "1" "$(grep -c "No distro selected" "$tmp/caller-err")"
  many="$(FAKE_DIALOG_RC=1 select_multiple_distros </dev/null 2>/dev/null)"; rc=$?
  check "the same for several" "1:" "$rc:$many"
else
  note "SKIP: the distro selectors take an associative array (bash 4)"
fi

note "a caller that runs strict"
strict() { # strict <VAR=value>... -- <script>
  local -a vars=()
  while [[ "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift
  env "${vars[@]}" bash -euo pipefail -c "source ./helpers.sh; shlib_import logging dialog; $1" 2>/dev/null
}
# Single quotes on purpose: the inner shell expands these.
# shellcheck disable=SC2016
check "a cancel inside if does not end the caller" "cancelled after" "$(strict "SHLIB_DIALOG_TTY=$tty_file" FAKE_DIALOG_RC=1 -- 'if x=$(dialog_capture --menu t 10 40 2 a A); then echo chose; else echo cancelled; fi; echo after' | tr '\n' ' ' | sed 's/ $//')"
# shellcheck disable=SC2016
check "no terminal, asked inside if, does not end the caller" "none after" "$(strict "SHLIB_DIALOG_TTY=$tmp/none/tty" -- 'if dialog_has_tty; then echo has; else echo none; fi; echo after' | tr '\n' ' ' | sed 's/ $//')"


if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
