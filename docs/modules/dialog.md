# dialog

Dialog sizing, prompts, multi/single select, and a rich download progress gauge.

Functions
---------

- dialog_init
  - Purpose: Initialize `DIALOG_WIDTH`/`DIALOG_HEIGHT` based on the terminal size.

- check_if_dialog_installed
  - Purpose: Ensure `dialog` exists; prints an error and returns non-zero otherwise. Also calls `dialog_init`.

- dialog_has_tty
  - Purpose: True when the terminal device can be opened. Opened, not only looked at: with no controlling terminal `/dev/tty` still exists and is readable and writable by its mode, and opening it fails.
  - Env: `DIALOG_TTY` names another device (default `/dev/tty`).
  - Returns: 0 or 1; prints nothing.

- has_interactive_dialog_session
  - Purpose: True when a person can be shown a dialog: one of the standard streams is a terminal, or the terminal device opens. False under cron, a systemd unit, CI: prompt for nothing there.

- dialog_run dialog-args...
  - Purpose: Run `dialog` for a box with no answer to capture (`--msgbox`, `--infobox`, `--yesno`), on the terminal device when there is one, so the box shows whatever the caller did with its streams.
  - Returns: dialog's own status.

- dialog_capture dialog-args...
  - Purpose: Run `dialog` and print the answer on stdout: `choice=$(dialog_capture --menu ...)`.
  - Behavior: `choice=$(dialog --stdout --menu ...)` draws its menu on stderr, so a caller that has redirected stderr, or runs with its streams piped, shows a menu nobody can see. This puts the screen on the terminal device when there is one and leaves stdout to the answer. Do not pass `--stdout`: it is added. With no terminal device it is plain `dialog --stdout`.
  - Returns: dialog's own status (1 cancel, 255 escape), printing nothing unless it is 0.

- get_value title message [default]
  - Purpose: Prompt a value using a dialog input box; prints the value to stdout.
  - Behavior: The box is drawn on the terminal device when there is one. On cancel the message goes to stderr and nothing is printed: stdout is the value.
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
- `DIALOG_TTY`: the terminal device the functions above draw on. Default `/dev/tty`.
- `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG` — set to `0`, `false`, or `never` to suppress dialog error popups in `dialog_download_file`.

Dependencies
------------

- `dialog`, `awk`, `stat` (GNU/BSD), and `curl` or `wget`.
