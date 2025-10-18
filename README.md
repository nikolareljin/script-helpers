script-helpers
================

Reusable Bash helpers extracted from projects in this workspace. Source modules you need (docker, logging, dialog, file, json, ports, etc.) and reuse them across scripts.

Quick start
-----------

- Add as a subfolder (recommended for local repo):
  - Copy or symlink `script-helpers` into your project (e.g., `scripts/script-helpers`).
  - Source the loader and import modules in your script:

    ```bash
    #!/usr/bin/env bash
    set -euo pipefail
    SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(dirname "$0")/script-helpers}"
    # Load the loader
    # shellcheck source=/dev/null
    source "$SCRIPT_HELPERS_DIR/helpers.sh"
    # Import only what you need
    shlib_import logging docker dialog file json env ports browser traps certs hosts clipboard
    ```

- Git submodule (once this repo is hosted remotely):
  - `git submodule add <remote-url> scripts/script-helpers`
  - Source as shown above.

Loader and modules
------------------

- `helpers.sh`: resolves library path and provides `shlib_import` to source modules by name.
- Modules live in `lib/*.sh` and are small, dependency-light files:
  - `logging.sh` — color constants and logging helpers (`print_info`, `log_info`, etc.).
  - `dialog.sh` — dialog sizing helpers and `get_value`.
  - `os.sh` — OS detection (`get_os`, `getos`), clipboard helpers.
  - `deps.sh` — install utilities (`install_dependencies`) where applicable.
  - `docker.sh` — docker compose detection/wrapper (`docker_compose`, `run_docker_compose_command`, etc.).
  - `file.sh` — file/dir helpers, checksum verification.
  - `json.sh` — json utilities (`json_escape`, `format_response`, `format_md_response`).
  - `env.sh` — `.env` loading, `require_env`, project-root detection.
  - `ports.sh` — port usage/availability helpers.
  - `browser.sh` — `open_url`, `open_frontend_when_ready`.
  - `traps.sh` — cleanup and signal traps.
  - `certs.sh` — self-signed cert creation and trust-store helpers.
  - `hosts.sh` — `/etc/hosts` helpers.
  - `clipboard.sh` — `copy_to_clipboard`.
  - `ollama.sh` — Ollama helpers (`ollama_install_cli`, prepare models index from webfarmer/ollama-get-models, dialog selection, `ollama_pull_model`, `ollama_run_model

Compatibility notes
-------------------

- Function names from existing projects are preserved where possible. Where multiple variants existed, this library accepts both styles (e.g., `print_color` accepts either ANSI code constants or color names like `red`, `green`).
- Some functions (e.g., `download_iso`) expect data like `DISTROS` associative array to be supplied by the caller project.
- `install_dependencies` may run `sudo` and perform network installs; use cautiously in CI or locked-down environments.

Example usage
-------------

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/script-helpers}"
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging docker env file json

print_info "Project root: $(get_project_root)"
compose_cmd=$(get_docker_compose_cmd)
log_info "Compose cmd: $compose_cmd"
```

Testing locally
---------------

- Source `helpers.sh` from a shell and import modules to try functions interactively:

```bash
source ./helpers.sh
shlib_import logging json
print_success "It works!"
```

Conventions
-----------

- Shell: POSIX-friendly where possible; scripts should set `set -euo pipefail` in the caller.
- Filenames are `snake_case`. Functions are preserved from original includes for compatibility.

