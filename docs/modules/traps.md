# traps

Basic EXIT/INT/TERM traps with error reporting.

Functions
---------

- cleanup [exit_code]
  - Purpose: Trap handler that prints a non-zero exit code via `log_error` when a script exits with failure. Takes the status as `$1`; without it, reads `$?` on entry.

- setup_traps
  - Purpose: Install traps: `EXIT` -> `cleanup "$?"` (status captured before any other command in the handler), `INT` -> prints interrupt and exits 130, `TERM` -> prints terminated and exits 143. On INT and TERM the `EXIT` handler then also prints "Script failed with exit code 130" (or 143).

Notes
-----

- Import `logging` to format trap errors as styled logs.

