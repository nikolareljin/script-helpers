#!/usr/bin/env bash
# SCRIPT: dialog_pty_test.sh
# DESCRIPTION: The dialog functions against the real dialog program, inside a pseudo-terminal.
# USAGE: ./tests/dialog_pty_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dialog_pty_test.sh
# ----------------------------------------------------
#
# tests/dialog_capture_test.sh proves the functions against a stand-in. A
# stand-in encodes what its author believes dialog does, and the first belief
# written into it was wrong (that a --stdout box draws on stderr; dialog
# reopens the terminal by itself; it is a box without --stdout, an inputbox or
# a msgbox, that draws into a captured stdout: measured with dialog 1.3, 2,235
# bytes of screen in the caller's variable and nothing on the terminal). So
# this runs the program: a child shell
# gets a pseudo-terminal as its controlling terminal, a box is opened, a key
# is sent once the screen has been drawn, and what reached the terminal and
# what reached the caller are told apart.
#
# Skips when dialog or python3 is not installed. No real terminal is touched.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[dialog_pty_test] $*"; }
error() { echo "[dialog_pty_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[dialog_pty_test]   ok  $*"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else error "$1: expected [$2], got [$3]"; fi; }

command -v dialog >/dev/null 2>&1 || { note "SKIP: dialog is not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { note "SKIP: python3 is needed for the pseudo-terminal"; exit 0; }
python3 -c 'import pty' 2>/dev/null || { note "SKIP: this python has no pty module"; exit 0; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

cat >"$tmp/in_pty.py" <<'PY'
"""in_pty.py <key> <bash snippet>: run the snippet in bash with a pseudo-terminal
as its controlling terminal. Once a screen has been drawn on that terminal, send
the key. Print `screen=yes|no` and the lines the snippet marked with `OUT:`."""
import os, pty, re, select, sys, time

key = {"enter": b"\r", "escape": b"\x1b", "none": b""}[sys.argv[1]]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm"
    os.execvp("bash", ["bash", "--norc", "--noprofile", "-c", sys.argv[2] + "; echo; echo FINISHED"])
out, sent, drew_at, start = b"", False, None, time.time()
DREW = re.compile(rb"\x1b\[\d+;\d+H|\x1b\[\?1049h")
while time.time() - start < 30:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if drew_at is None and DREW.search(out):
        drew_at = time.time()
    # A moment after the first draw, so the box is up before the key arrives.
    if not sent and key and drew_at is not None and time.time() - drew_at > 0.4:
        os.write(fd, key)
        sent = True
    if b"FINISHED" in out:
        break
try:
    os.kill(pid, 9)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except OSError:
    pass
text = out.decode("utf-8", "replace")
print("screen=" + ("yes" if drew_at is not None else "no"))
print("finished=" + ("yes" if "FINISHED" in text else "no"))
for line in re.findall(r"OUT:([^\r\n]*)", text):
    print("out=" + line)
PY

load="cd '$root_dir'; source ./helpers.sh; shlib_import logging dialog"
in_pty() { python3 "$tmp/in_pty.py" "$1" "$load; $2" 2>&1; }
field() { grep "^$1=" <<<"$result" | head -n 1 | cut -d= -f2-; }
menu='--menu Pick 10 40 2 a First b Second'

note "an answer"
# shellcheck disable=SC2016
result="$(in_pty enter "x=\$(dialog_capture $menu 2>/dev/null </dev/null); echo \"OUT:rc=\$? answer=[\$x]\"")"
check "the menu is drawn on the terminal with the caller's stderr and stdin elsewhere" "yes" "$(field screen)"
check "and the answer comes back, alone" "rc=0 answer=[a]" "$(field out)"
# shellcheck disable=SC2016
result="$(in_pty escape "x=\$(dialog_capture $menu); echo \"OUT:rc=\$? answer=[\$x]\"")"
check "escape: dialog's status, and nothing as the answer" "rc=255 answer=[]" "$(field out)"

note "a value"
# shellcheck disable=SC2016
result="$(in_pty enter 'x=$(get_value "Title" "Message" "the default"); echo "OUT:rc=$? value=[$x]"')"
check "get_value's box is drawn on the terminal though its stdout is captured" "yes" "$(field screen)"
check "and the value is the value, not the screen" "rc=0 value=[the default]" "$(field out)"

note "a box with no answer"
# shellcheck disable=SC2016
result="$(in_pty enter 'x=$(dialog_run --msgbox "Hello" 6 30); echo "OUT:rc=$? captured=${#x}"')"
check "dialog_run's box is drawn on the terminal though stdout is captured" "yes" "$(field screen)"
check "and nothing of it reaches the caller" "rc=0 captured=0" "$(field out)"

note "the hub setup's boxes, with dialog forced and stdout captured"
hub_load="cd '$root_dir'; source ./helpers.sh; shlib_import logging dialog hub"
# shellcheck disable=SC2016
result="$(python3 "$tmp/in_pty.py" enter "$hub_load; "'x=$(HUB_UI=dialog _hub__ui_yesno "Title" "Sure?"; echo "rc=$?"); echo "OUT:captured=[$x]"' 2>&1)"
check "the yes/no question is drawn on the terminal" "yes" "$(field screen)"
check "and only its answer reaches the caller (Enter on a box that defaults to No)" "captured=[rc=1]" "$(field out)"
# shellcheck disable=SC2016
result="$(python3 "$tmp/in_pty.py" enter "$hub_load; "'x=$(HUB_UI=dialog _hub__ui_note "hello"); echo "OUT:captured=${#x}"' 2>&1)"
check "the note is drawn on the terminal, and none of it is captured" "yes captured=0" "$(field screen) $(field out)"

note "a gauge"
# A gauge draws on stdout as well, and reads its progress from stdin.
# shellcheck disable=SC2016
result="$(in_pty none 'x=$( (echo 30; sleep 1; echo 90; sleep 1) | dialog_gauge --no-shadow --title T --gauge "Preparing" 7 50 0); echo "OUT:rc=$? captured=${#x}"')"
check "dialog_gauge draws on the terminal though stdout is captured" "yes" "$(field screen)"
check "none of it reaches the caller, and it ends when its progress does" "rc=0 captured=0" "$(field out)"

# The call site of the model pull gauge, which draws only when stderr is a terminal.
ollama_load="cd '$root_dir'; source ./helpers.sh; shlib_import logging dialog os file json env ollama"
# shellcheck disable=SC2016
result="$(python3 "$tmp/in_pty.py" none "$ollama_load; "'x=$(_ollama_dialog_pull_command "Pulling" "alpha:7b" sleep 2); echo "OUT:rc=$? captured=${#x}"' 2>&1)"
check "the model pull gauge is drawn on the terminal, and none of it is captured" "yes rc=0 captured=0" "$(field screen) $(field out)"

note "the hub setup's prompts, with dialog forced, stdout captured and stdin elsewhere"
# shellcheck disable=SC2016
result="$(python3 "$tmp/in_pty.py" enter "$hub_load; "'x=$(HUB_UI=dialog _hub__ui_menu "Title" "Pick" b a First b Second </dev/null); echo "OUT:rc=$? answer=[$x]"' 2>&1)"
check "the choice is drawn on the terminal and answered from it" "yes rc=0 answer=[b]" "$(field screen) $(field out)"
# shellcheck disable=SC2016
result="$(python3 "$tmp/in_pty.py" enter "$hub_load; "'x=$(HUB_UI=dialog _hub__ui_input "Title" "Name" "the default" </dev/null); echo "OUT:rc=$? answer=[$x]"' 2>&1)"
check "so is the input" "yes rc=0 answer=[the default]" "$(field screen) $(field out)"
# shellcheck disable=SC2016
result="$(python3 "$tmp/in_pty.py" escape "$hub_load; "'x=$(HUB_UI=dialog _hub__ui_secret "Title" "Key" </dev/null); echo "OUT:rc=$? answer=[$x]"' 2>&1)"
check "and the secret: escape is a refusal, with nothing as the answer" "yes rc=1 answer=[]" "$(field screen) $(field out)"

note "is there a terminal"
# shellcheck disable=SC2016
result="$(in_pty none 'if dialog_has_tty </dev/null >/dev/null 2>&1; then echo "OUT:tty=yes"; else echo "OUT:tty=no"; fi')"
check "inside a terminal session the device opens, whatever the streams are" "tty=yes" "$(field out)"
# shellcheck disable=SC2016
result="$(in_pty none 'if has_interactive_dialog_session </dev/null >/dev/null 2>&1; then echo "OUT:session=yes"; else echo "OUT:session=no"; fi')"
check "and the session is interactive" "session=yes" "$(field out)"
# shellcheck disable=SC2016
result="$(in_pty none 'export SHLIB_DIALOG_TTY=/nonexistent/tty; if dialog_has_tty; then echo "OUT:tty=yes"; else echo "OUT:tty=no"; fi; if has_interactive_dialog_session; then echo "OUT:session=yes"; else echo "OUT:session=no"; fi')"
check "a stream that is a terminal makes the session interactive even when the device does not open" "tty=no session=yes" "$(grep '^out=' <<<"$result" | cut -d= -f2- | tr '\n' ' ' | sed 's/ $//')"

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
