# file

File/dir helpers and download utilities.

Functions
---------

- command_exists name
  - Purpose: Return success if a command is available in PATH.

- directory_exists path
- file_exists path
  - Purpose: Test for directory/file existence.

- create_directory path
  - Purpose: Create a directory if missing; prints a message. Returns 0 on success or if it already exists.

- download_file url [output]
  - Purpose: Download a file using `curl` or `wget`.
  - Behavior:
    - If `dialog` is installed and `DOWNLOAD_USE_DIALOG` is not `false`/`0`/`never`, automatically uses `dialog::dialog_download_file` for a progress gauge.
    - Falls back silently to `curl` or `wget` with minimal output. `curl` runs with `-f`, so an HTTP error (404, 500, ...) is a failure rather than an error page saved as the file.
    - The download goes to a temporary file beside the destination (`output.XXXXXX`) and is moved into place only on success, with the mode the umask gives a new file. On failure the temporary file is removed: no partial or error-page file is left at the destination, and a file that was already there is left untouched.
  - Returns: 0 on success; the downloader's non-zero status on failure; 1 when neither `curl` nor `wget` is installed or the temporary file cannot be created.
  - Args:
    - url — source URL.
    - output — destination path; default derived from URL.
  - Env:
    - `DOWNLOAD_USE_DIALOG`: `auto` (default) | `true`/`1` | `false`/`0`/`never`.

- is_valid_iso file
  - Purpose: Heuristically check if a file is an ISO image (via `file`).

- is_valid_checksum file
  - Purpose: Heuristically check if a file looks like an ASCII checksum list.

- verify_checksum iso_file checksum_file [checksum_type=sha256sum]
  - Purpose: Verify checksum using the specified tool (e.g., `sha256sum`).
  - Behavior: Finds the entry for `iso_file`'s basename in `checksum_file` (`HASH  name`, `HASH *name`, or tagged `ALGO (name) = HASH`; a listed path matches on its basename), hashes `iso_file` with `checksum_type`, and compares (case-insensitive). Other entries in the list do not matter. With `shasum`, whose default is SHA-1, the algorithm is chosen from the length of the listed digest (40, 56, 64, 96, 128 hex digits: SHA-1, -224, -256, -384, -512), as `shasum -c` does.
  - Returns: 0 when that entry exists and matches; 1 when it does not match, when the list has no entry for the file, or when the tool is missing; prints success/error.

- download_iso distro_name
  - Requires bash 4.0 or newer: it reads a `DISTROS` associative array supplied
    by the caller, and calls `require_bash4` when the shell is older.
  - Purpose: Download ISO based on a `DISTROS` associative array defined by the caller.
  - Behavior: When the output file already exists, the download is skipped (with a warning) and the existing file is validated; otherwise downloads it. Prints success/error; validates ISO structure.

Dependencies
------------

- `curl` or `wget` for download, `dialog` for optional UI, `file` for validation.

