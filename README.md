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
  
  ```bash
  git submodule add git@github.com:nikolareljin/script-helpers.git scripts/script-helpers
  ```
  
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

Download dialog gauge
---------------------

- `dialog_download_file URL [output_path] [tool]`
  - Shows a real-time `dialog` gauge with percent, downloaded vs total size, speed, and ETA.
  - `tool` can be `auto` (default), `curl`, or `wget`.
  - Example:

    ```bash
    source ./helpers.sh
    shlib_import dialog logging
    dialog_download_file "https://example.com/big.iso" "/tmp/big.iso" auto
    ```

Notes:
- Requires `dialog` to be installed. Uses `curl` (preferred) or `wget` for downloading.
- If server does not provide Content-Length, the gauge will show downloaded bytes and speed with a rolling progress bar and no ETA.

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

Download behavior
-----------------

- `file.sh::download_file URL [output]`
  - Automatically uses the dialog gauge (`dialog_download_file`) when `dialog` is installed.
  - Control via env var `DOWNLOAD_USE_DIALOG`:
    - `auto` (default): use dialog if available.
    - `true`/`1`: force dialog if available, otherwise fallback.
    - `false`/`0`/`never`: disable dialog and use plain `curl`/`wget`.
  - Falls back to plain `curl` or `wget` with no interactive gauge if dialog is unavailable or fails.

Examples
--------

- `scripts/example_download.sh` — Download a URL with the dialog progress gauge.
- `scripts/example_dialog_input.sh` — Prompt for a value using `dialog`.
- `scripts/example_logging.sh` — Showcase logging helpers (`print_*`, `log_*`).
- `scripts/example_env.sh` — Use env helpers (`get_project_root`, `resolve_env_value`, `require_env`).
- `scripts/example_docker_compose_cmd.sh` — Detect the Docker Compose command.
- `scripts/example_json.sh` — JSON helpers demo (`json_escape`, `format_response`).

Run examples with Makefile
--------------------------

- `make examples` runs safe, non-interactive demos.
- Opt-in flags:
  - `RUN_INTERACTIVE=1` to include `dialog` input demo.
  - `RUN_NETWORK=1` to include the download demo.
  
Example:

```bash
make examples RUN_INTERACTIVE=1 RUN_NETWORK=1
```

- Shell: POSIX-friendly where possible; scripts should set `set -euo pipefail` in the caller.
- Filenames are `snake_case`. Functions are preserved from original includes for compatibility.
