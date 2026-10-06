# dialog

Dialog sizing, prompts, multi/single select, and a rich download progress gauge.

Functions
---------

- dialog_init
  - Purpose: Initialize `DIALOG_WIDTH`/`DIALOG_HEIGHT` based on the terminal size.

- check_if_dialog_installed
  - Purpose: Ensure `dialog` exists; prints an error and returns non-zero otherwise. Also calls `dialog_init`.

- dialog_has_tty
  - Purpose: True when the terminal device can be opened for reading and writing.
  - Behavior: Opened, not only looked at: with no controlling terminal `/dev/tty` still exists and is readable and writable by its mode, and opening it fails. Never creates anything: a path that is not there, a directory or a FIFO is not a terminal.
  - Returns: 0 or 1; prints nothing. Under `set -e`, call it inside `if` or with `||`: a false answer is a non-zero status.

- has_interactive_dialog_session
  - Purpose: True when a person can be shown a dialog: one of the standard streams is a terminal, or the terminal device opens. False under cron, a systemd unit, CI: prompt for nothing there.
  - Returns: 0 or 1; the same note under `set -e`.

- dialog_run dialog-args...
  - Purpose: Run `dialog` for a box with no answer to capture (`--msgbox`, `--infobox`, `--yesno`), on the terminal device when there is one.
  - Behavior: `dialog` draws such a box on its standard output, so `$(...)` around it captures the screen and shows nobody anything. Here the box shows whatever the caller did with its streams. Keys come from the terminal too, so it is not for a gauge, which reads its progress from stdin. With no terminal device it is plain `dialog`.
  - Returns: dialog's own status (`--yesno`: 1 for No). 255, before anything is drawn, for an option `dialog` does not know (`dialog` itself would print its help and exit 0, which a `--yesno` caller would read as Yes). Under `set -e`, guard it.

- dialog_gauge dialog-args...
  - Purpose: Run `dialog` for a `--gauge`, on the terminal device when there is one: `progress | dialog_gauge --gauge ...`.
  - Behavior: The progress is read from stdin, as `dialog` reads it; only the screen is moved. A gauge draws on its standard output like any box without an answer, so under `$(...)` it showed nothing and the caller captured the screen. With no terminal device it is plain `dialog`.
  - Returns: dialog's own status; 255 for an option `dialog` does not know. Under `set -e`, guard it.

- dialog_capture dialog-args...
  - Purpose: Run `dialog` and print the answer on stdout: `choice=$(dialog_capture --menu ...)`.
  - Behavior: The screen and the keys are on the terminal device when there is one; stdout carries the answer and nothing else. Do not pass `--stdout`: it is added. Nothing is written to disk. With `dialog` 1.3 a `--stdout` box finds the terminal by itself, so for a menu this gives what `$(dialog --stdout ...)` gives; it does not depend on that, and it is the same call for an `--inputbox`, which otherwise answers on stderr and draws on stdout. What `dialog` says about a malformed call goes to the terminal with the screen, not to the caller's stderr.
  - Returns: dialog's own status (1 cancel; 255 escape, or an error of dialog's), printing nothing unless it is 0. Also 255, printing nothing, for an option `dialog` does not know or a box given no arguments: `dialog` answers both with its help text and exit 0, which would otherwise be the answer. Under `set -e`, `choice=$(dialog_capture ...)` ends the caller on a cancel unless it is inside `if` or followed by `||`.

- get_value title message [default]
  - Purpose: Prompt a value using a dialog input box; prints the value to stdout.
  - Behavior: Drawn through `dialog_capture`, so the box shows when the caller captures stdout: `value=$(get_value ...)` used to put the whole screen into the value and nothing on the terminal. On cancel or an empty answer it returns 1, the message goes to stderr and nothing is printed: stdout is the value.
  - Returns: 0 on success; non-zero (with error message) if canceled or empty.

> **Requires bash 4.0 or newer.** The two selectors below take a `DISTROS`
> associative array **from the caller**, which is the one contract in this
> library that cannot be expressed on bash 3.2. They call `require_bash4` and
> fail with an actionable message (`brew install bash` on macOS) rather than
> returning wrong values silently, which is what an associative array degrades
> to on bash 3.2. Everything else here runs on 3.2 unchanged.

- select_multiple_distros
  - Purpose: Checklist selection used by the iso-forge workflow.
  - Requirements: Associative array `DISTROS` mapping name -> URL must be defined by the caller.
  - Returns: space-separated selected names.

- select_distro
  - Purpose: Menu selection used by the iso-forge workflow.
  - Requirements: `DISTROS` associative array.
  - Returns: selected name.

- dialog_download_file url [output_path] [tool=auto]
  - Purpose: Download a URL with a live `dialog` gauge showing percentage, size, speed, and ETA.
  - Args:
    - url — source URL.
    - output_path — destination path (defaults from URL).
    - tool — `auto` (default), `curl`, or `wget`.
  - Behavior:
    - Shows progress while downloading; handles unknown `Content-Length` with rolling progress and no ETA.
    - On errors, shows a dialog box with exit code and error details unless disabled by env.
  - Returns: 0 on success; non-zero on failure/cancel.

Environment
-----------

- `DIALOG_WIDTH`, `DIALOG_HEIGHT` — set by `dialog_init`.
- `SHLIB_DIALOG_TTY`: the terminal device the functions above draw on. Default `/dev/tty`. For tests, which give it a file. (`DIALOG_TTY` is a variable of `dialog`'s own and is not read here.)
- `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG` — set to `0`, `false`, or `never` to suppress dialog error popups in `dialog_download_file`.

Dependencies
------------

- `dialog`, `awk`, `stat` (GNU/BSD), and `curl` or `wget`.
