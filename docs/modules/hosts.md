# hosts

Helpers for editing `/etc/hosts`.

Functions
---------

- add_to_etc_hosts domain ip_address
  - Purpose: Append `ip_address` and `domain` to the hosts file when the domain
    is not already present.
  - Behavior: Writes directly when the file is writable, otherwise through
    `sudo tee`. Prints a success or info message.
  - Env:
    - `HOSTS_FILE` — the file to edit, default `/etc/hosts`. Provided so the
      "already present" test is verifiable without touching the real file.
  - Notes: the presence test uses POSIX `[[:space:]]` rather than GNU `\s`.
    BSD grep does not reject `\s`, it simply never matches it, so on macOS the
    check always concluded "absent" and appended a duplicate line on every call.

Dependencies
------------

- Write access to the hosts file, directly or via `sudo`.
