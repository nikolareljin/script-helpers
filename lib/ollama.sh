#!/usr/bin/env bash
# Ollama helpers: install CLI, prepare models index, select and pull models.
# Mirrors logic used in ai-runner/include.sh and integrates with script-helpers modules.

# Expected imports by caller (via shlib_import): logging, os, dialog, file, json, env (python optional)

# Usage: _ollama_default_repo_url; prints default models repo URL.
_ollama_default_repo_url() {
  echo "https://github.com/webfarmer/ollama-get-models.git"
}

_ollama_project_root() {
  if [[ -n "${ROOT_DIR:-}" ]]; then
    echo "$ROOT_DIR"
    return 0
  fi
  if command -v get_project_root >/dev/null 2>&1; then
    get_project_root
    return 0
  fi
  pwd
}

_ollama_python_deps_ok() {
  local python_cmd
  python_cmd="$(_ollama_resolve_python_cmd)" || return 1
  "$python_cmd" - <<'PY'
try:
    # beautifulsoup4 installs as 'bs4'
    import bs4  # noqa: F401
    import requests  # noqa: F401
except ImportError:
    raise SystemExit(1)
PY
}

_ollama_ensure_python_deps() {
  local python_cmd
  if _ollama_python_deps_ok; then
    return 0
  fi
  python_cmd="$(_ollama_resolve_python_cmd)" || {
    print_error "Python 3 not found; install python3 and try again."
    return 1
  }
  if command -v apt-get >/dev/null 2>&1; then
    print_info "Installing Python deps via apt (python3-bs4, python3-requests)..."
    if ! run_with_optional_sudo true apt-get update; then
      print_warning "apt-get update failed; attempting install with existing package lists."
    fi
    if ! run_with_optional_sudo true apt-get install -y python3-bs4 python3-requests; then
      print_warning "Failed to install Python deps via apt (python3-bs4, python3-requests); falling back to pip."
      if ! _ollama_install_python_deps_pip "$python_cmd"; then
        return 1
      fi
    fi
  else
    if ! _ollama_install_python_deps_pip "$python_cmd"; then
      return 1
    fi
  fi
  if ! _ollama_python_deps_ok; then
    print_error "Python deps are still missing after installation attempt."
    return 1
  fi
  return 0
}

_ollama_install_python_deps_pip() {
  local python_cmd="$1"
  local -a pip_args=("--upgrade")
  if ! "$python_cmd" -m pip --version >/dev/null 2>&1; then
    print_error "pip not available for python3. Install python3-pip or use a system package manager."
    return 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    pip_args+=("--user")
  fi
  print_warning "Installing Python deps via pip; prefer system packages to avoid conflicts."
  print_info "Installing Python deps for models index (beautifulsoup4, requests)..."
  if ! "$python_cmd" -m pip install "${pip_args[@]}" beautifulsoup4 requests; then
    print_error "Failed to install Python deps via pip (beautifulsoup4, requests)."
    return 1
  fi
  return 0
}

_ollama_is_valid_models_json() {
  local json_path="$1"
  jq -e '(type == "array" and length > 0)
        or (type == "object" and has("models") and (.models | type == "array" and length > 0))' \
     "$json_path" >/dev/null 2>&1
}

_ollama_resolve_python_cmd() {
  # Prefer shared python module if available, otherwise fall back locally.
  local python_cmd
  if command -v python_resolve_3 >/dev/null 2>&1; then
    python_cmd="$(python_resolve_3 "" 3 8)" && {
      echo "$python_cmd"
      return 0
    }
  fi
  if command -v shlib_import >/dev/null 2>&1; then
    shlib_import python >/dev/null 2>&1 || true
    if command -v python_resolve_3 >/dev/null 2>&1; then
      python_cmd="$(python_resolve_3 "" 3 8)" && {
        echo "$python_cmd"
        return 0
      }
    fi
  fi
  if command -v python3 >/dev/null 2>&1 && python3 - <<'PY'
import sys
raise SystemExit(0 if (sys.version_info[0] == 3 and sys.version_info[1] >= 8) else 1)
PY
  then
    echo "python3"
    return 0
  fi
  if command -v python >/dev/null 2>&1 && python - <<'PY'
import sys
raise SystemExit(0 if (sys.version_info[0] == 3 and sys.version_info[1] >= 8) else 1)
PY
  then
    echo "python"
    return 0
  fi
  return 1
}

# Install Ollama CLI for supported OSes.
ollama_install_cli() {
  local os; os=$(get_os)
  case "$os" in
    linux)
      print_info "Installing Ollama CLI on Linux..."
      curl -fsSL https://ollama.com/install.sh | sh
      ;;
    mac)
      print_info "Installing Ollama CLI on macOS..."
      if command -v brew >/dev/null 2>&1; then
        brew install ollama/tap/ollama
      else
        print_error "Homebrew not found; install Homebrew or Ollama manually."
        return 1
      fi
      ;;
    windows)
      print_error "Ollama installation is not supported in this shell on Windows."
      return 1
      ;;
    *)
      print_error "Unsupported OS for Ollama installation."
      return 1
      ;;
  esac
}

# Ensure repo with models index exists and is up to date; generate JSON index.
# Args:
#   $1 - target directory (default: ./ollama-get-models)
#   $2 - repo URL (default: webfarmer/ollama-get-models)
# Returns: print path to models JSON on success
ollama_prepare_models_index() {
  local repo_dir="${1:-ollama-get-models}"
  local repo_url="${2:-$(_ollama_default_repo_url)}"
  local json_path
  local skip_generate
  local python_cmd
  json_path="$repo_dir/code/ollama_models.json"

  if [[ -d "$repo_dir/.git" ]]; then
    print_info "Updating models repo: $repo_dir"
    if [[ -n "${OLLAMA_MODELS_REPO_REF:-}" ]]; then
      (cd "$repo_dir" && git fetch --tags --prune) || {
        print_warning "git fetch failed; continuing with existing index if present."
      }
    else
      (cd "$repo_dir" && git pull --ff-only) || {
        print_warning "git pull failed; continuing with existing index if present."
      }
    fi
  elif [[ -d "$repo_dir" ]]; then
    print_warning "$repo_dir exists but is not a git repo. Using as-is."
  else
    print_info "Cloning models repo: $repo_url -> $repo_dir"
    git clone "$repo_url" "$repo_dir" || {
      print_error "Failed to clone $repo_url"
      return 1
    }
  fi

  if [[ -n "${OLLAMA_MODELS_REPO_REF:-}" ]]; then
    (cd "$repo_dir" && git checkout --detach "$OLLAMA_MODELS_REPO_REF") || {
      print_error "Failed to checkout OLLAMA_MODELS_REPO_REF=$OLLAMA_MODELS_REPO_REF"
      return 1
    }
  else
    print_warning "OLLAMA_MODELS_REPO_REF not set; executing unpinned repo scripts."
  fi

  if [[ -f "$json_path" ]]; then
    if _ollama_is_valid_models_json "$json_path"; then
      print_info "Using existing models index: $json_path"
      skip_generate=true
    else
      print_warning "Existing models index is invalid; regenerating."
      skip_generate=false
    fi
  else
    skip_generate=false
  fi

  if [[ "$skip_generate" != "true" ]]; then
    # Generate the models JSON via provided script
    if [[ -f "$repo_dir/get_ollama_models.py" ]]; then
      _ollama_ensure_python_deps || return 1
      python_cmd="$(_ollama_resolve_python_cmd)" || return 1
      (cd "$repo_dir" && "$python_cmd" get_ollama_models.py) || {
        if [[ -f "$json_path" ]]; then
          if _ollama_is_valid_models_json "$json_path"; then
            print_warning "Model index generation failed; using existing JSON."
          else
            print_error "Model index generation failed and JSON is invalid."
            return 1
          fi
        else
          print_error "Failed to generate models index via Python script."
          return 1
        fi
      }
    else
      print_warning "get_ollama_models.py not found in $repo_dir; expecting prebuilt index."
    fi
  fi

  if [[ ! -f "$json_path" ]]; then
    print_error "Models JSON not found at: $json_path"
    return 1
  fi
  # Sort deterministically by name
  jq -S 'sort_by(.name)' "$json_path" >"$json_path.tmp" && mv "$json_path.tmp" "$json_path"
  echo "$json_path"
}

# Return path to models JSON for a repo directory (does not generate)
ollama_models_json_path() {
  local repo_dir="${1:-ollama-get-models}"
  echo "$repo_dir/code/ollama_models.json"
}

# List model names from JSON index
ollama_list_models() {
  local json_file="$1"
  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file"
    return 1
  fi
  jq -r '.[].name' "$json_file"
}

# Use dialog to select a model; preselect current_model if provided.
# Prints selected model name to stdout.
ollama_dialog_select_model() {
  local json_file="$1"; local current_model="${2:-}"
  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file"
    return 1
  fi

  dialog_init; check_if_dialog_installed || return 1

  local line key value selected
  local -a menu_items=()
  while IFS= read -r line; do
    key=$(echo "$line" | awk '{print $1}')
    value=$(echo "$line" | awk '{$1=""; print $0}')
    if [[ "$key" == "$current_model" ]]; then
      menu_items+=("$key" "$value" "on")
    else
      menu_items+=("$key" "$value" "off")
    fi
  done < <(jq -r '.[] | "\(.name) sizes:\t\(.sizes)"' "$json_file")

  selected=$(dialog --radiolist "Select an Ollama model to download" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
  local status=$?
  if [[ $status -ne 0 || -z "$selected" ]]; then
    print_error "No model selected."
    return 1
  fi
  echo "$selected"
}

# Use dialog to select size for a given model. If none available, returns 'latest'.
ollama_dialog_select_size() {
  local json_file="$1"; local model="$2"; local current_size="${3:-}"
  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file"
    return 1
  fi

  local sizes; sizes=$(jq -r --arg m "$model" '.[] | select(.name == $m) | .sizes[]?' "$json_file")
  if [[ -z "$sizes" ]]; then
    print_warning "No sizes listed for $model; using 'latest'."
    echo "latest"
    return 0
  fi

  dialog_init; check_if_dialog_installed || return 1
  local -a menu_items=()
  local s; for s in $sizes; do
    menu_items+=("$s" "$s")
  done

  local selected
  selected=$(dialog --menu "Select a size for: $model" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
  if [[ -z "$selected" ]]; then
    selected="${current_size:-latest}"
    print_info "No size selected; using '$selected'."
  fi
  echo "$selected"
}

# Build Ollama model reference. Omits tag when size is empty/latest.
ollama_model_ref() {
  local model_name="$1"
  local model_size="${2:-latest}"
  if [[ -z "$model_size" || "$model_size" == "latest" ]]; then
    echo "$model_name"
  else
    echo "${model_name}:${model_size}"
  fi
}

# Backward-compatible alias used by older scripts.
ollama_model_ref_safe() {
  ollama_model_ref "$@"
}

# Resolve runtime mode from env/override: local|docker.
ollama_runtime_type() {
  local env_file="$1"
  local runtime_override="${2:-}"
  local runtime

  if [[ -n "$runtime_override" ]]; then
    runtime="$runtime_override"
  else
    runtime="$(resolve_env_value "ollama_runtime" "local" "$env_file")"
  fi

  runtime="$(echo "$runtime" | tr '[:upper:]' '[:lower:]')"
  if [[ "$runtime" != "local" && "$runtime" != "docker" ]]; then
    print_warning "Invalid ollama_runtime '$runtime'; defaulting to 'local'."
    runtime="local"
  fi

  echo "$runtime"
}

ollama_runtime_scheme() {
  local env_file="$1"
  resolve_env_value "ollama_scheme" "http" "$env_file"
}

ollama_runtime_host() {
  local env_file="$1"
  resolve_env_value "ollama_host" "localhost" "$env_file"
}

ollama_runtime_port() {
  local env_file="$1"
  resolve_env_value "ollama_port" "11434" "$env_file"
}

ollama_runtime_build_base_url() {
  local env_file="$1"
  local scheme host port base

  scheme="$(ollama_runtime_scheme "$env_file")"
  host="$(ollama_runtime_host "$env_file")"
  port="$(ollama_runtime_port "$env_file")"

  host="${host%/}"
  if [[ "$host" == *"://"* ]]; then
    base="$host"
  else
    base="${scheme}://${host}"
  fi

  if [[ ! "$base" =~ :[0-9]+$ ]]; then
    base="${base}:${port}"
  fi

  echo "${base%/}"
}

ollama_runtime_sync_env_url() {
  local env_file="$1"
  local base_url

  base_url="$(ollama_runtime_build_base_url "$env_file")"
  if [[ -n "$env_file" ]]; then
    ollama_update_env "$env_file" ollama_url "$base_url"
  fi
  echo "$base_url"
}

ollama_runtime_api_base_url() {
  local env_file="$1"
  local base_url
  local host_value

  host_value="$(resolve_env_value "ollama_host" "" "$env_file")"
  if [[ -n "$host_value" ]]; then
    base_url="$(ollama_runtime_build_base_url "$env_file")"
  else
    base_url="$(resolve_env_value "ollama_url" "" "$env_file")"
  fi
  if [[ -z "$base_url" ]]; then
    local website
    website="$(resolve_env_value "website" "http://localhost:11434/api/generate" "$env_file")"
    base_url="${website%/api/generate}"
  fi

  base_url="${base_url%/}"
  if [[ -z "$base_url" ]]; then
    base_url="http://localhost:11434"
  fi

  echo "$base_url"
}

ollama_runtime_generate_endpoint() {
  local env_file="$1"
  echo "$(ollama_runtime_api_base_url "$env_file")/api/generate"
}

ollama_runtime_container_name() {
  local env_file="$1"
  resolve_env_value "ollama_docker_container" "ai-runner-ollama" "$env_file"
}

ollama_runtime_image() {
  local env_file="$1"
  resolve_env_value "ollama_docker_image" "ollama/ollama:latest" "$env_file"
}

ollama_runtime_data_dir() {
  local env_file="$1"
  local data_dir
  local project_root

  data_dir="$(resolve_env_value "ollama_data_dir" "./models/ollama-data" "$env_file")"
  if [[ "$data_dir" != /* ]]; then
    project_root="$(_ollama_project_root)"
    data_dir="$project_root/$data_dir"
  fi

  create_directory "$data_dir" >/dev/null
  (cd "$data_dir" && pwd)
}

ollama_runtime_local_models_dir() {
  local env_file="$1"
  local shared_store local_models_dir data_dir project_root

  shared_store="$(resolve_env_value "ollama_shared_model_store" "1" "$env_file")"
  shared_store="$(echo "$shared_store" | tr '[:upper:]' '[:lower:]')"
  if [[ "$shared_store" == "1" || "$shared_store" == "true" || "$shared_store" == "yes" ]]; then
    data_dir="$(ollama_runtime_data_dir "$env_file")"
    local_models_dir="${data_dir}/models"
  else
    local_models_dir="$(resolve_env_value "ollama_local_models_dir" "${OLLAMA_MODELS:-$HOME/.ollama/models}" "$env_file")"
  fi

  if [[ "$local_models_dir" != /* ]]; then
    project_root="$(_ollama_project_root)"
    local_models_dir="$project_root/$local_models_dir"
  fi
  create_directory "$local_models_dir" >/dev/null
  (cd "$local_models_dir" && pwd)
}

ollama_runtime_local_cmd() {
  local env_file="$1"
  shift
  local local_models_dir
  local_models_dir="$(ollama_runtime_local_models_dir "$env_file")"
  OLLAMA_MODELS="$local_models_dir" ollama "$@"
}

ollama_runtime_host_port() {
  local base_url="$1"
  if [[ "$base_url" =~ :([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "11434"
  fi
}

ollama_runtime_ensure_docker_container() {
  local env_file="$1"
  local container image data_dir base_url host_port

  if ! command -v docker >/dev/null 2>&1; then
    print_error "Docker runtime selected but 'docker' CLI is not available."
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    print_error "Docker runtime selected but Docker daemon is not reachable."
    return 1
  fi

  container="$(ollama_runtime_container_name "$env_file")"
  image="$(ollama_runtime_image "$env_file")"
  data_dir="$(ollama_runtime_data_dir "$env_file")"
  base_url="$(ollama_runtime_api_base_url "$env_file")"
  host_port="$(ollama_runtime_host_port "$base_url")"

  if docker ps --filter "name=^/${container}$" --filter "status=running" -q | grep -q .; then
    return 0
  fi

  if docker ps -a --filter "name=^/${container}$" -q | grep -q .; then
    print_info "Starting Docker Ollama container: ${container}"
    docker start "$container" >/dev/null
    return 0
  fi

  print_info "Creating Docker Ollama container '${container}' from ${image}"
  print_info "Mounting model data: ${data_dir} -> /root/.ollama"
  docker run -d \
    --name "$container" \
    -p "${host_port}:11434" \
    -v "${data_dir}:/root/.ollama" \
    "$image" >/dev/null
}

ollama_runtime_ensure_ready() {
  local runtime="$1"
  local env_file="$2"

  if [[ "$runtime" == "docker" ]]; then
    ollama_runtime_ensure_docker_container "$env_file"
  fi
}

ollama_runtime_pull_model() {
  local runtime="$1"
  local env_file="$2"
  local model="$3"
  local size="${4:-latest}"
  local model_ref

  model_ref="$(ollama_model_ref "$model" "$size")"
  if [[ "$runtime" == "docker" ]]; then
    local container
    ollama_runtime_ensure_docker_container "$env_file" || return 1
    container="$(ollama_runtime_container_name "$env_file")"
    print_info "Pulling model in Docker: ${model_ref}"
    docker exec "$container" ollama pull "$model_ref"
    return $?
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    print_error "ollama CLI not found; install it or set ollama_runtime=docker."
    return 1
  fi

  print_info "Pulling model locally: ${model_ref}"
  ollama_runtime_local_cmd "$env_file" pull "$model_ref"
}

ollama_runtime_supports_export() {
  local runtime="$1"
  local env_file="$2"
  local out=""
  local rc=0

  if [[ "$runtime" == "docker" ]]; then
    local container
    ollama_runtime_ensure_docker_container "$env_file" || return 1
    container="$(ollama_runtime_container_name "$env_file")"
    out="$(docker exec "$container" ollama export --help 2>&1)" || rc=$?
  else
    if ! command -v ollama >/dev/null 2>&1; then
      return 1
    fi
    out="$(ollama_runtime_local_cmd "$env_file" export --help 2>&1)" || rc=$?
  fi

  if [[ $rc -eq 0 ]] || [[ "$out" == *"Usage:"* ]] || [[ "$out" == *"export"* ]]; then
    return 0
  fi
  if [[ "$out" == *"unknown command"* ]] || [[ "$out" == *"is not a command"* ]]; then
    return 1
  fi

  return 1
}

ollama_runtime_export_model() {
  local runtime="$1"
  local env_file="$2"
  local model_ref="$3"
  local output_path="$4"

  create_directory "$(dirname "$output_path")" >/dev/null

  if [[ "$runtime" == "docker" ]]; then
    local container
    ollama_runtime_ensure_docker_container "$env_file" || return 1
    container="$(ollama_runtime_container_name "$env_file")"
    print_info "Exporting ${model_ref} from Docker to ${output_path}"
    if ! docker exec "$container" ollama export "$model_ref" > "$output_path"; then
      rm -f "$output_path"
      return 1
    fi
    return 0
  fi

  print_info "Exporting ${model_ref} locally to ${output_path}"
  ollama_runtime_local_cmd "$env_file" export "$model_ref" > "$output_path"
}

ollama_runtime_run_model() {
  local runtime="$1"
  local env_file="$2"
  local model="$3"
  local size="${4:-latest}"

  if [[ "$runtime" == "docker" ]]; then
    print_info "Docker runtime selected; model serve is handled by container API."
    return 0
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    print_warning "ollama CLI not found; skipping local 'ollama run'."
    return 0
  fi

  local model_ref
  model_ref="$(ollama_model_ref "$model" "$size")"
  nohup bash -lc "OLLAMA_MODELS=\"$(ollama_runtime_local_models_dir "$env_file")\" ollama run \"$model_ref\"" >/dev/null 2>&1 &
}

ollama_runtime_ps() {
  local runtime="$1"
  local env_file="$2"
  if [[ "$runtime" == "docker" ]]; then
    local container
    container="$(ollama_runtime_container_name "$env_file")"
    if command -v docker >/dev/null 2>&1; then
      print_info "Docker container status:"
      docker ps --filter "name=^/${container}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
    fi
  else
    if command -v ollama >/dev/null 2>&1; then
      ollama_runtime_local_cmd "$env_file" ps || true
    fi
  fi
}

# Pull a model: ollama pull "name:size"
ollama_pull_model() {
  local model="$1"; local size="${2:-latest}"
  local model_ref
  if ! command -v ollama >/dev/null 2>&1; then
    print_error "ollama CLI not found; install it first."
    return 1
  fi
  model_ref="$(ollama_model_ref "$model" "$size")"
  print_info "Pulling model: ${model_ref}"
  ollama pull "$model_ref"
}

# Run a model in background: ollama run name:size &
ollama_run_model() {
  local model="$1"; local size="${2:-latest}"
  local model_ref
  if ! command -v ollama >/dev/null 2>&1; then
    print_error "ollama CLI not found; install it first."
    return 1
  fi
  model_ref="$(ollama_model_ref "$model" "$size")"
  print_info "Running model: ${model_ref}"
  nohup ollama run "$model_ref" >/dev/null 2>&1 &
}

# Update key=value in .env (create or replace line); portable sed/awk approach.
ollama_update_env() {
  local env_file="${1:-.env}" key="$2" value="$3"
  if [[ -z "$key" ]]; then
    print_error "env key is required"
    return 1
  fi
  touch "$env_file"
  if grep -qE "^${key}=" "$env_file"; then
    # Replace line
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} {print}' "$env_file" >"$env_file.tmp" && mv "$env_file.tmp" "$env_file"
  else
    printf "%s=%s\n" "$key" "$value" >>"$env_file"
  fi
}

# Orchestrated flow: ensure index, pick model+size, optionally persist to .env, then pull.
# Args:
#   $1 - repo_dir (default: ollama-get-models)
#   $2 - env_file to update (optional)
# Side effects: updates env_file with model/size if provided.
ollama_install_model_flow() {
  local repo_dir="${1:-ollama-get-models}" env_file="${2:-}"
  local json_file model size
  json_file=$(ollama_prepare_models_index "$repo_dir") || return 1

  # Read current selections from env (if provided)
  local current_model current_size
  if [[ -n "$env_file" && -f "$env_file" ]]; then
    current_model=$(resolve_env_value "model" "" "$env_file")
    current_size=$(resolve_env_value "size" "" "$env_file")
  fi

  model=$(ollama_dialog_select_model "$json_file" "$current_model") || return 1
  size=$(ollama_dialog_select_size "$json_file" "$model" "$current_size") || return 1

  if [[ -n "$env_file" ]]; then
    ollama_update_env "$env_file" model "$model"
    ollama_update_env "$env_file" size "$size"
  fi

  ollama_pull_model "$model" "$size"
}
