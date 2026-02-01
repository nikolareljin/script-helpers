#!/usr/bin/env bash
# Ollama helpers: install CLI, prepare models index, select and pull models.
# Mirrors logic used in ai-runner/include.sh and integrates with script-helpers modules.

# Expected imports by caller (via shlib_import): logging, os, dialog, file, json, env

# Usage: _ollama_default_repo_url; prints default models repo URL.
_ollama_default_repo_url() {
  echo "https://github.com/webfarmer/ollama-get-models.git"
}

_ollama_python_cmd() {
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return 0
  fi
  if command -v python >/dev/null 2>&1 && python - <<'PY'
import sys
raise SystemExit(0 if sys.version_info[0] == 3 else 1)
PY
  then
    echo "python"
    return 0
  fi
  return 1
}

_ollama_python_deps_ok() {
  local python_cmd
  python_cmd="$(_ollama_python_cmd)" || return 1
  "$python_cmd" - <<'PY'
try:
    import bs4  # noqa: F401
    import requests  # noqa: F401
except Exception:
    raise SystemExit(1)
PY
}

_ollama_ensure_python_deps() {
  local python_cmd
  if _ollama_python_deps_ok; then
    return 0
  fi
  python_cmd="$(_ollama_python_cmd)" || {
    print_error "python3 not found; install it and try again."
    return 1
  }
  if command -v apt-get >/dev/null 2>&1; then
    print_info "Installing Python deps via apt (python3-bs4, python3-requests)..."
    if ! run_with_optional_sudo true apt-get update; then
      print_warning "apt-get update failed; attempting install with existing package lists."
    fi
    run_with_optional_sudo true apt-get install -y python3-bs4 python3-requests
    return 0
  else
    if ! "$python_cmd" -m pip --version >/dev/null 2>&1; then
      print_error "pip not available for python3. Install python3-pip or use a system package manager."
      return 1
    fi
    print_info "Installing Python deps for models index (beautifulsoup4, requests)..."
    "$python_cmd" -m pip install --user --upgrade beautifulsoup4 requests
  fi
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
  json_path="$repo_dir/code/ollama_models.json"

  if [[ -d "$repo_dir/.git" ]]; then
    print_info "Updating models repo: $repo_dir"
    (cd "$repo_dir" && git pull --ff-only) || {
      print_warning "git pull failed; continuing with existing index if present."
    }
  elif [[ -d "$repo_dir" ]]; then
    print_warning "$repo_dir exists but is not a git repo. Using as-is."
  else
    print_info "Cloning models repo: $repo_url -> $repo_dir"
    git clone "$repo_url" "$repo_dir" || {
      print_error "Failed to clone $repo_url"
      return 1
    }
  fi

  if [[ -f "$json_path" ]]; then
    print_info "Using existing models index: $json_path"
  else
    # Generate the models JSON via provided script
    if [[ -f "$repo_dir/get_ollama_models.py" ]]; then
      _ollama_ensure_python_deps || {
        print_error "Missing Python deps for model index."
        return 1
      }
      (cd "$repo_dir" && "$(_ollama_python_cmd)" get_ollama_models.py) || {
        if [[ -f "$json_path" ]]; then
          print_warning "Model index generation failed; using existing JSON."
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

  local options line key value selected pre=""
  local -a menu_items=()
  while IFS= read -r line; do
    key=$(echo "$line" | awk '{print $1}')
    value=$(echo "$line" | awk '{$1=""; print $0}')
    if [[ "$key" == "$current_model" ]]; then
      menu_items+=("$key" "$value" "on")
      pre="$key"
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

# Pull a model: ollama pull "name:size"
ollama_pull_model() {
  local model="$1"; local size="${2:-latest}"
  if ! command -v ollama >/dev/null 2>&1; then
    print_error "ollama CLI not found; install it first."
    return 1
  fi
  print_info "Pulling model: ${model}:${size}"
  ollama pull "${model}:${size}"
}

# Run a model in background: ollama run name:size &
ollama_run_model() {
  local model="$1"; local size="${2:-latest}"
  if ! command -v ollama >/dev/null 2>&1; then
    print_error "ollama CLI not found; install it first."
    return 1
  fi
  print_info "Running model: ${model}:${size}"
  nohup ollama run "${model}:${size}" >/dev/null 2>&1 &
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
