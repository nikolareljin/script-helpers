# trap_stack

Temp files and directories that are removed when the shell exits or is
interrupted, registered from nested functions. A second registration adds to
the stack; it does not replace the first.

```bash
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import trap_stack

work="$(mktemp -d)" || exit 1
trap_stack_push "$work"
# ... calls that push and pop paths of their own ...
trap_stack_pop            # removes $work
```

- While a path is registered, `EXIT`, `HUP`, `INT` and `TERM` remove every
  registered path, newest first. Ctrl-C leaves no temp directory behind.
- A trap the caller already has for one of them is kept and runs after the
  removal. With no trap of the caller's, `HUP`, `INT` and `TERM` exit `129`,
  `130` and `143`. A signal the caller ignores stays ignored. The caller's `EXIT`
  trap sees the exit status the script ended with.
- The caller's traps are put back when the last path is popped. A trap the
  caller sets while a path is registered is kept: the next push chains onto it,
  and a pop does not replace it.
- Works under `set -euo pipefail` and on bash 3.2.
- Push and pop in the same shell. A path pushed inside `$( ... )` or `( ... )`
  belongs to that subshell and is removed when it exits, unless it is popped
  with `--keep` first. A subshell does not remove a path its parent registered.
- bash 3.2, in a subshell: a trap the subshell set itself before the first push
  is not chained, and the last pop resets it. bash 3.2 lists the parent's traps
  in a subshell and cannot tell the two apart, and a parent's `EXIT` trap must
  not run in the subshell.

The library's own temp directories are registered this way: `fetch_to_file`
(the partial file), `fetch_verified_gpg_key`, the Node.js step of `deps`,
`gitleaks_install`, `foxguard_install`, `ollama_install`, `docker_install`,
`docs_site_check`, `screencap_record` and `android_sign`.

Functions
---------

- trap_stack_push path
  - Purpose: Register a file or directory for removal on `EXIT`, `HUP`, `INT` and `TERM`.
  - Behavior: A relative path is registered as it resolves at the push; a later `cd` does not change what is removed.
  - Returns: 0 registered; 2 an empty path or `/`.

- trap_stack_pop [--keep]
  - Purpose: Take the newest registered path off the stack and remove it (`rm -rf`). With `--keep` the path is left in place.
  - Behavior: Popping the last path puts the caller's traps back.
  - Returns: 0, also with nothing registered in this shell.
