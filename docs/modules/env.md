# env

Environment and project helpers.

Functions
---------

- get_project_root
  - Purpose: Determine project root as the parent directory of the calling script directory.
  - Behavior: If called from a sourced script, uses `BASH_SOURCE[1]`; otherwise uses CWD.

- load_env [env_file=.env]
  - Purpose: Load environment variables from a dotenv file; exports them for the current shell.
  - Args: env_file — path to a `.env` file; default `.env` in CWD.

- require_env VAR [VAR...]
  - Purpose: Ensure variables are set; errors with list of missing variables and returns non-zero if any missing.

- resolve_env_value key default [env_file=.env]
  - Purpose: Resolve a value from the current environment or from a dotenv file; falls back to a default.
  - Args:
    - key — variable name to resolve.
    - default — value when not set anywhere.
    - env_file — path to search when not present in the environment.
  - Trims quotes/comments/CR and whitespace.

- run_superuser_setup
  - Purpose: Execute `scripts/superuser.sh` in the project root.
  - Behavior: Returns non-zero and logs an error if the script is missing or not executable.

- init_include
  - Purpose: Convenience initializer: sets traps (if available), `cd` to project root, and loads `.env`.
  - Behavior: Calls `setup_traps` when imported; prints debug logs when `DEBUG=true`.

