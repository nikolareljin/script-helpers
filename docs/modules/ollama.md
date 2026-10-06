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
  - Behavior: Uses existing `code/ollama_models.json` if present; otherwise ensures Python deps and runs `get_ollama_models.py` with Python 3. The default generator reads `https://ollama.com/library` only, so its index holds the library's own models and no namespaced ones (`hf.co/org/model`, `user/model`); those come from an index of your own (`repo_url`, or a file edited by hand). The index is then sorted by name, and left untouched when it is sorted already (rewritten on every call, it was always newer than its menu cache) (a top-level array, or the `models` array of a `{"models": [...]}` object), and prints the JSON path.
  - Output: stdout carries only the JSON path, so `json_file="$(ollama_prepare_models_index)"` is safe; progress, warnings, git and generator output go to stderr.
  - Returns: non-zero on failure, including when the index cannot be sorted (no `.tmp` file is left behind).

Environment
-----------

- `OLLAMA_MODELS_REPO_REF`: optional git ref (tag/commit) to pin the models repo before executing scripts.
- `OLLAMA_MODEL_MENU_CACHE_FILE`: optional parsed selector-cache path to reuse a prepared model menu instead of regenerating it.

- ollama_models_json_path [repo_dir=ollama-get-models]
  - Purpose: Convenience function to print the expected JSON path within the repo.

- ollama_list_models json_file
  - Purpose: Print model names from the JSON index, in either of its shapes (a top-level array, or `{"models": [...]}`). Only names that can be a model reference are printed, as in the menu; an entry that is not an object or has no name is passed over, and so is a name the rule does not take, without a message.
  - Output: one name a line. A reader that stops early (`ollama_list_models file | head -n 1`) does not make the function fail, also for a caller with `pipefail`.
  - Returns: 0, also for an index with no usable name; 1 when the file is not there, when jq cannot read it, or when the names cannot be written for a reason other than a reader that left (a full disk).

- ollama_model_menu_cache_path json_file
  - Purpose: Build the persistent parsed menu-cache path for a JSON model index.

- ollama_model_menu_cache_is_fresh cache_file [max_age_seconds=1800]
  - Purpose: Check whether a parsed menu-cache file exists, is non-empty, and is recent enough to reuse.

- ollama_prepare_model_menu_cache json_file [cache_file]
  - Purpose: Convert the models in the JSON index, in either of its shapes, into a TSV cache for the dialog menu. Namespaced models (`hf.co/org/model`, `user/model`) are kept when the index lists them.
  - Names: only an entry whose name can be a model reference is kept: letters, digits and `. _ - / :`, starting with a letter or a digit, with no empty part (`..`, `//`, `::`, a `:` or `/` at the end) and no control character. It is the rule `lib/ollama_endpoint.sh` has for a reference, applied in the C locale so that an accented letter is not a letter. A name from the index ends up in a command line and in the `.env` that `ollama_install_model_flow` writes and `load_env` sources. An entry that is not an object, has no name, or has another kind of name is left out and does not end the menu. The rule is narrower than Ollama's own in two places: Ollama takes a name that starts with `_` and one with `..` in it (`_x`, `a..b`), and neither is offered here.
  - Sizes: only sizes that can be a tag are shown (letters, digits and `. _ -`). A model with none is written as `latest`, and one whose name carries its tag as `in the name`, so no column is empty (an empty one made the description read as the sizes).
  - Format: the first line is `#index`, a tab and the full path of the index the cache was made from, with its directory resolved, so the same index spelled another way (`x.json`, `./x.json`) gives the same line and the same relative path in another directory does not. A line that starts with `#` is never a row. Then one row per model (name, name, sizes, description, separated by tabs). A description is text with its control characters turned into spaces.
  - Returns: 0, printing the cache path; 1 when the index cannot be read or has nothing to offer. No cache is written then; one already at that path stays as it was.
  - Behavior: Writes cache updates atomically so interrupted or failed refreshes do not leave partial cache files behind, and refreshes a caller-supplied cache path in place when `OLLAMA_MODEL_MENU_CACHE_FILE` is set.

- ollama_dialog_select_model json_file [current_model]
  - Purpose: Use a dialog menu to select a model from the index; returns the selected full model name on stdout.
  - Behavior: Uses the cache at `OLLAMA_MODEL_MENU_CACHE_FILE`, or at the default cache path, while it says it was made from this index, is newer than it, is less than 30 minutes old and has no empty column (one written by an earlier version may); otherwise the cache is rebuilt first. So an index with a newer modification time is in the menu at once (a file put in place with an older time is not, until the cache ages). A cached row whose name cannot be a model reference is skipped. `current_model` is made the default item whatever its letter case; of names that differ only by case, the one written the same way. When the dialog is cancelled, the function prints a message to stderr and returns a non-zero status, so callers using `set -e` must handle cancellations explicitly to avoid script termination. If the prepared cache contains no selectable models, the function returns a clear stderr error instead of invoking an empty dialog.

- ollama_dialog_select_size json_file model [current_size]
  - Purpose: Use a dialog menu to select a size for the model; returns `latest` if none are listed. Only a size that can be a tag (letters, digits and `. _ -`) is offered, each as its own item whatever the caller's `IFS` is. A model name that carries its tag (`hf.co/org/model:Q4_K_M`) gets no menu and `latest`: the name is the whole reference.
  - Behavior: Returns status `2` when the size dialog is cancelled so callers can reopen model selection; `1` when jq cannot read the index (it used to answer `latest`).

- ollama_model_ref model [size=latest]
  - Purpose: Build model reference for Ollama (`name` or `name:tag` when tag is not `latest`). A name that already carries a tag (`hf.co/org/model:Q4_K_M`) is returned as it is; a port in a registry host is not a tag.

- ollama_model_ref_safe model [size=latest]
  - Purpose: Backward-compatible alias for `ollama_model_ref`.

- ollama_pull_model model [size=latest]
  - Purpose: `ollama pull name:size`.
  - Returns: 1, running nothing, when the reference does not start with a letter or a digit, or has a space or a control character in it (empty, an option such as `-x`, `_x`, two words). The same holds for `ollama_run_model`, `ollama_runtime_pull_model` and `ollama_runtime_export_model`. `ollama_runtime_run_model` checks only where it would run something: with the `docker` runtime, or without the `ollama` command, it returns 0 before it looks at the model.
  - Note: Ollama itself takes a name that starts with `_`. Such a name is refused here.

- ollama_run_model model [size=latest]
  - Purpose: `nohup ollama run name:size &`.

- ollama_update_env [env_file=.env] key value
  - Purpose: Create/update a `key=value` line in a dotenv file.
  - Behavior: The key is matched literally against the text before the first `=`; the value is written byte-for-byte (backslashes included, unquoted as before). A replaced file is rewritten in place, so it keeps its permissions and, when the env file is a symlink, the link stays and the update reaches its target.
  - Key: a letter or an underscore, then letters, digits, underscores and dots, judged in the C locale. A dash, a leading digit and an accented letter are refused. A key with a dot is written, but bash does not read `a.b=v` as an assignment: `load_env` prints `command not found` for that line and loads the rest, and a caller running with `set -e` ends there.
  - Returns: 0; 1 when the key is empty or not a name, when the key or value contains a newline or carriage return, when the value contains a space, a quote or a shell operator (`; & | $ ( ) < >` or a backquote) or ends in a backslash, or on a write error. A refused value leaves the file unchanged: the file is one `load_env` sources, where `model=two words` runs `words`, `model=x;touch f` runs `touch`, and a backslash at the end of a line joins the next line to it. The reason goes to stderr; stdout stays empty.
  - Written as given, though `load_env` reads them changed: a backslash inside the value (`a\b` loads as `ab`) and a `~` at its start (`~/x` loads as `x` in the home directory).

- ollama_install_model_flow [repo_dir=ollama-get-models] [env_file]
  - Purpose: Full flow: ensure index, select model and size, optionally persist to env, then `ollama pull` the selection.
  - Behavior: Reopens model selection when the size dialog is cancelled. Works for a caller under `set -u` with no env file yet.

Runtime functions
-----------------

- ollama_runtime_type env_file [runtime_override]
  - Purpose: Resolve runtime mode (`local` or `docker`).
  - Output: prints only the mode on stdout; the warning for an invalid value (which falls back to `local`) goes to stderr.

- ollama_runtime_scheme env_file
- ollama_runtime_host env_file
- ollama_runtime_port env_file
  - Purpose: Resolve runtime URL pieces from env with defaults (`http`, `localhost`, `11434`).

- ollama_runtime_build_base_url env_file
  - Purpose: Build normalized base URL from runtime scheme/host/port.

- ollama_runtime_sync_env_url env_file
  - Purpose: Compute base URL and persist `ollama_url` in env.
  - Output: stdout carries only the URL, so `url="$(ollama_runtime_sync_env_url "$env_file")"` is safe. An address `ollama_update_env` refuses (a `$` or `&` in a password, for example) is still printed and the function returns 0; a warning on stderr says it was not saved.

- ollama_runtime_api_base_url env_file
  - Purpose: Resolve effective API base URL from runtime fields, `ollama_url`, or legacy `website`.
  - Behavior: Normalizes legacy `website` values by stripping query/fragment and `/api/generate` suffixes.

- ollama_runtime_generate_endpoint env_file
  - Purpose: Build `/api/generate` endpoint URL.

- ollama_runtime_container_name env_file
- ollama_runtime_image env_file
  - Purpose: Resolve Docker container/image config for Ollama runtime.

- ollama_runtime_data_dir env_file
- ollama_runtime_local_models_dir env_file
  - Purpose: Resolve and create runtime model data directories.
  - Returns: absolute path on success; non-zero if directory creation fails.

- ollama_runtime_local_cmd env_file command [args...]
  - Purpose: Run `ollama` command with runtime-local model directory.

- ollama_runtime_host_port base_url
  - Purpose: Extract host port from base URL (fallback `11434`).

- ollama_runtime_ensure_docker_container env_file
  - Purpose: Ensure Docker container exists and is running for runtime mode.
  - Returns: zero on success; non-zero when Docker checks/start/create fail.

- ollama_runtime_ensure_ready runtime env_file
  - Purpose: Prepare runtime prerequisites (currently Docker container startup).

- ollama_runtime_pull_model runtime env_file model [size=latest]
  - Purpose: Pull model through selected runtime.
  - Behavior: Uses a dialog progress gauge when dialog support, `python3`, and an interactive terminal on stderr are available, tails only recent pull output for progress parsing, and cancels the background pull cleanly if the gauge is closed.

- ollama_runtime_supports_export runtime env_file
  - Purpose: Detect whether runtime supports `ollama export`.

- ollama_runtime_export_model runtime env_file model_ref output_path
  - Purpose: Export model through selected runtime to file.
  - Returns: zero on success; non-zero on export/write failure.
  - Behavior: Removes partial output file when export fails.

- ollama_runtime_run_model runtime env_file model [size=latest]
  - Purpose: Run model via local runtime (`docker` mode is API-only).
  - Returns: 0 with the `docker` runtime or without the `ollama` command, having run nothing. With the local runtime and the command there: 1, running nothing, for a model that is not a reference (see `ollama_pull_model`).

- ollama_runtime_ps runtime env_file
  - Purpose: Show runtime status (`docker ps` summary or local `ollama ps`).

Dependencies
------------

- `curl`, `git`, `python3` (3.8+), `jq`, `dialog`, `ollama`.
- `docker` is required only when using the Docker runtime helpers.
- `pip` is required only when `apt-get` is not available for installing Python deps used by the models index generator.
