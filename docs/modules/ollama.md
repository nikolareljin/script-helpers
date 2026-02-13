# ollama

Helpers to install the Ollama CLI, prepare a models index, select a model/size via dialog, pull/run models, and manage local vs Docker Ollama runtime.

Expected imports
----------------

- logging, os, dialog, file, json, env
- `python` module is recommended; if not imported, ollama falls back to local Python detection.

Functions
---------

- ollama_install_cli
  - Purpose: Install the Ollama CLI (Linux/macOS). Prints an error on unsupported platforms.
  - Linux: `curl -fsSL https://ollama.com/install.sh | sh`
  - macOS: `brew install ollama/tap/ollama`

- ollama_prepare_models_index [repo_dir=ollama-get-models] [repo_url=https://github.com/webfarmer/ollama-get-models.git]
  - Purpose: Ensure a repo containing the models index exists; update/clone; generate `code/ollama_models.json`.
  - Behavior: Uses existing `code/ollama_models.json` if present; otherwise ensures Python deps and runs `get_ollama_models.py` with Python 3; sorts JSON by name; prints path to the JSON.
  - Returns: non-zero on failure.

Environment
-----------

- `OLLAMA_MODELS_REPO_REF`: optional git ref (tag/commit) to pin the models repo before executing scripts.

- ollama_models_json_path [repo_dir=ollama-get-models]
  - Purpose: Convenience function to print the expected JSON path within the repo.

- ollama_list_models json_file
  - Purpose: Print model names from the JSON index.

- ollama_dialog_select_model json_file [current_model]
  - Purpose: Use a dialog radiolist to select a model; returns selected name on stdout.

- ollama_dialog_select_size json_file model [current_size]
  - Purpose: Use a dialog menu to select a size for the model; returns `latest` if none are listed.

- ollama_model_ref model [size=latest]
  - Purpose: Build model reference for Ollama (`name` or `name:tag` when tag is not `latest`).

- ollama_model_ref_safe model [size=latest]
  - Purpose: Backward-compatible alias for `ollama_model_ref`.

- ollama_pull_model model [size=latest]
  - Purpose: `ollama pull name:size`.

- ollama_run_model model [size=latest]
  - Purpose: `nohup ollama run name:size &`.

- ollama_update_env [env_file=.env] key value
  - Purpose: Create/update a `key=value` line in a dotenv file.

- ollama_install_model_flow [repo_dir=ollama-get-models] [env_file]
  - Purpose: Full flow: ensure index, select model and size, optionally persist to env, then `ollama pull` the selection.

Runtime functions
-----------------

- ollama_runtime_type env_file [runtime_override]
  - Purpose: Resolve runtime mode (`local` or `docker`).

- ollama_runtime_scheme env_file
- ollama_runtime_host env_file
- ollama_runtime_port env_file
  - Purpose: Resolve runtime URL pieces from env with defaults (`http`, `localhost`, `11434`).

- ollama_runtime_build_base_url env_file
  - Purpose: Build normalized base URL from runtime scheme/host/port.

- ollama_runtime_sync_env_url env_file
  - Purpose: Compute base URL and persist `ollama_url` in env.

- ollama_runtime_api_base_url env_file
  - Purpose: Resolve effective API base URL from runtime fields, `ollama_url`, or legacy `website`.

- ollama_runtime_generate_endpoint env_file
  - Purpose: Build `/api/generate` endpoint URL.

- ollama_runtime_container_name env_file
- ollama_runtime_image env_file
  - Purpose: Resolve Docker container/image config for Ollama runtime.

- ollama_runtime_data_dir env_file
- ollama_runtime_local_models_dir env_file
  - Purpose: Resolve and create runtime model data directories.

- ollama_runtime_local_cmd env_file command [args...]
  - Purpose: Run `ollama` command with runtime-local model directory.

- ollama_runtime_host_port base_url
  - Purpose: Extract host port from base URL (fallback `11434`).

- ollama_runtime_ensure_docker_container env_file
  - Purpose: Ensure Docker container exists and is running for runtime mode.

- ollama_runtime_ensure_ready runtime env_file
  - Purpose: Prepare runtime prerequisites (currently Docker container startup).

- ollama_runtime_pull_model runtime env_file model [size=latest]
  - Purpose: Pull model through selected runtime.

- ollama_runtime_supports_export runtime env_file
  - Purpose: Detect whether runtime supports `ollama export`.

- ollama_runtime_export_model runtime env_file model_ref output_path
  - Purpose: Export model through selected runtime to file.

- ollama_runtime_run_model runtime env_file model [size=latest]
  - Purpose: Run model via local runtime (`docker` mode is API-only).

- ollama_runtime_ps runtime env_file
  - Purpose: Show runtime status (`docker ps` summary or local `ollama ps`).

Internals
---------

- _ollama_python_deps_ok
  - Purpose: Check that `bs4` and `requests` are importable by Python 3.
  - Returns: zero when deps are available; non-zero otherwise.

- _ollama_ensure_python_deps
  - Purpose: Ensure Python deps for the models index are installed (`beautifulsoup4`, `requests`).
  - Behavior: Uses `apt-get` to install `python3-bs4` and `python3-requests` when available; otherwise uses `pip` (requires `python3-pip`).
  - Returns: non-zero on failure.

- _ollama_install_python_deps_pip
  - Purpose: Install Python deps via pip with appropriate flags.

- _ollama_is_valid_models_json
  - Purpose: Validate the models index JSON structure.

- _ollama_resolve_python_cmd
  - Purpose: Resolve a Python 3 executable, preferring the shared python module when available.

Dependencies
------------

- `curl`, `git`, `python3` (3.8+), `jq`, `dialog`, `ollama`.
- `pip` is required only when `apt-get` is not available for installing Python deps.
