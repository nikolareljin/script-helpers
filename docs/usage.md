# Usage

In your script
--------------

```bash
#!/usr/bin/env bash
set -euo pipefail

# Adjust the path to where you vendored this repo
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(dirname "$0")/script-helpers}"

# 1) Load the loader
source "$SCRIPT_HELPERS_DIR/helpers.sh"

# 2) Import the modules you need
shlib_import logging docker dialog file json env ports browser traps certs hosts clipboard ollama os

# 3) Call functions
print_info "Project root: $(get_project_root)"
docker_status
```

Import patterns
---------------

- `shlib_import name [name ...]` sources the given modules from `lib/*.sh`.
- Logging is auto-imported first if not explicitly requested to ensure logs are available.
- `shlib_import_all` is available when you want everything (handy for interactive sessions).

Environment variables
---------------------

- `SCRIPT_HELPERS_DIR` — absolute or relative path to this repository. The loader auto-detects; set explicitly when needed.
- `DEBUG=true` — enables `log_debug` output in logging.
- `DOWNLOAD_USE_DIALOG` — download UI preference for `file::download_file`:
  - `auto` (default): use dialog gauge if `dialog` is installed.
  - `true`/`1`: force dialog if available.
  - `false`/`0`/`never`: disable dialog UI.
- `PORT_DETECTION_ALLOW_SUDO` — allow sudo when probing ports (`ports` module). Default: `false`.
- `FRONTEND_HOST`, `FRONTEND_PORT` — host/port for `browser::open_frontend_when_ready`.

Using as a library in other projects
------------------------------------

- Vendor this folder under `scripts/script-helpers` or similar.
- Source `helpers.sh` from your scripts and import the modules you need.
- Keep examples in `scripts/` handy for quick reference; you can copy/paste and adapt.

Common snippets
---------------

Minimal logging
```bash
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging
print_success "It works!"
```

Load .env and require variables
```bash
shlib_import logging env
load_env .env
require_env DATABASE_URL SECRET_KEY
```

Download with a progress gauge
```bash
shlib_import dialog file logging
dialog_download_file "https://example.com/file.iso" "/tmp/file.iso" auto
# or via file::download_file which uses the gauge automatically when available
download_file "https://example.com/file.iso" "/tmp/file.iso"
```

Docker compose detection and status
```bash
shlib_import logging docker
compose_cmd=$(get_docker_compose_cmd)
log_info "Compose: $compose_cmd"
docker_status
```

