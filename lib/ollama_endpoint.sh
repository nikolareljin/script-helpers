#!/usr/bin/env bash
# Ollama endpoint helpers: which models a project needs, which of them an
# Ollama already has, and whether the machine can take the rest -- decided
# before anything is pulled.
#
# A project lists its models by purpose in one env-style file (NAME=model).
# A start script asks three questions in order: what is needed, what is
# missing at this endpoint, and does the missing part fit (disk for the
# download, memory for the largest model). Only a yes to the last one pulls.
#
# Expected imports by caller (via shlib_import): logging
#
# Written for bash 3.2 and BSD userland: no arrays that may be empty under
# `set -u`, no associative arrays, awk and sed in their POSIX forms.

# --- the models file ---------------------------------------------------------

# Usage: ollama_models_file_get <file> <NAME>; prints the value of NAME, or
# nothing. Spaces around the name and the value do not count, nor does a
# carriage return from a file saved on Windows. The last line for a name wins.
ollama_models_file_get() {
  local file="$1" name="$2"
  [[ -f "$file" ]] || return 0
  sed -n -E "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*//p" "$file" \
    | tail -n 1 | sed -E 's/[[:space:]]+$//'
}

# Usage: ollama_models_file_names <file>; prints every NAME the file sets,
# one per line, in file order, each once.
ollama_models_file_names() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -n -E 's/^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=.*/\1/p' "$file" \
    | awk '!seen[$0]++'
}

# Usage: ollama_model_tagged <model>; prints the model with a tag. A name
# without one gets ":latest", which is how Ollama lists it. The tag is looked
# for in the last path segment only: "registry.example:5000/team/model" has a
# port, not a tag.
ollama_model_tagged() {
  local model="$1" last
  [[ -n "$model" ]] || return 0
  last="${model##*/}"
  case "$last" in
    *:*) printf '%s\n' "$model" ;;
    *)   printf '%s:latest\n' "$model" ;;
  esac
}

# Usage: ollama_models_required <file> [NAME...]; prints the models a start
# needs, tagged, one per line, each once.
#
# With no NAME, every name in the file that is not part of a large tier
# (NAME_LARGE, NAME_LARGE_VRAM_GB). For each name the environment wins over
# the file when it holds a non-blank value, so a caller that has loaded its
# own .env gets that machine's choice.
ollama_models_required() {
  local file="$1" name value names
  shift
  if [[ $# -gt 0 ]]; then
    names="$(printf '%s\n' "$@")"
  else
    names="$(ollama_models_file_names "$file" | grep -v -E '_LARGE(_VRAM_GB)?$' || true)"
  fi
  printf '%s\n' "$names" | while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    value="${!name:-}"
    # Trimmed: a padded value in the environment is the same model.
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$value" ]] || value="$(ollama_models_file_get "$file" "$name")"
    [[ -n "$value" ]] || continue
    ollama_model_tagged "$value"
  done | awk '!seen[$0]++'
}

# --- what an endpoint has ----------------------------------------------------

# Usage: ollama_endpoint_models <base_url> [timeout_seconds=5]; prints the
# models that Ollama has, one per line, as it names them (with tags).
# Returns 1 when nothing answers there or what answers is not an Ollama.
ollama_endpoint_models() {
  local url="${1%/}" timeout="${2:-5}" body
  body="$(curl -fsS -m "$timeout" "${url}/api/tags" 2>/dev/null)" || return 1
  # Any web server answers 200 to something. An Ollama's answer has "models".
  printf '%s' "$body" | grep -q '"models"[[:space:]]*:' || return 1
  printf '%s' "$body" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/^"name"[[:space:]]*:[[:space:]]*"//; s/"$//' || true
}

# Usage: ollama_models_missing <needed> <present>; both are newline-separated
# lists. Prints the needed models that are not present, one per line. A model
# matches only its whole name: "qwen:7b" is not satisfied by "qwen:7b-instruct".
ollama_models_missing() {
  local needed="$1" present="$2" model
  printf '%s\n' "$needed" | while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    printf '%s\n' "$present" | grep -qxF -- "$model" || printf '%s\n' "$model"
  done
}

# --- how big, and how much room ----------------------------------------------

_ollama_ep_is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Bytes as "N.N GB". A GB here is 10^9 bytes, as Ollama shows a model's size,
# so the figures in a refusal can be held against `ollama list`.
_ollama_ep_gb() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f GB", b / 1000000000 }'
}

# Usage: ollama_registry_size_bytes <model>; prints the size of the model's
# download in bytes, from the registry's manifest.
# Returns 1 when the registry did not answer or has no such model, 2 when the
# model lives on another registry host (its size is not asked for).
# OLLAMA_REGISTRY_URL (default https://registry.ollama.ai) and
# OLLAMA_REGISTRY_TIMEOUT (default 15) apply.
#
# The figure is every layer in the manifest. Layers the machine already holds
# for another model are counted again, so it can only overstate.
ollama_registry_size_bytes() {
  local ref tag name path body
  local base="${OLLAMA_REGISTRY_URL:-https://registry.ollama.ai}"
  ref="$(ollama_model_tagged "$1")"
  [[ -n "$ref" ]] || return 1
  tag="${ref##*:}"
  name="${ref%:"$tag"}"
  case "$name" in
    */*/*) return 2 ;;
    */*)   path="$name" ;;
    *)     path="library/$name" ;;
  esac
  body="$(curl -fsS -m "${OLLAMA_REGISTRY_TIMEOUT:-15}" \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "${base%/}/v2/${path}/manifests/${tag}" 2>/dev/null)" || return 1
  printf '%s' "$body" | grep -o '"size"[[:space:]]*:[[:space:]]*[0-9][0-9]*' \
    | awk -F: '{ total += $2; n++ } END { if (!n) exit 1; printf "%.0f\n", total }'
}

# Usage: ollama_disk_free_bytes <path>; prints the bytes free on the
# filesystem holding path (or its nearest existing parent). Nothing when it
# cannot be told. OLLAMA_BUDGET_DISK_FREE_BYTES overrides.
ollama_disk_free_bytes() {
  local path="${1:-.}"
  if _ollama_ep_is_uint "${OLLAMA_BUDGET_DISK_FREE_BYTES:-}"; then
    printf '%s\n' "$OLLAMA_BUDGET_DISK_FREE_BYTES"
    return 0
  fi
  while [[ -n "$path" && "$path" != "/" && ! -e "$path" ]]; do
    path="$(dirname "$path")"
  done
  df -Pk "${path:-/}" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { printf "%.0f\n", $4 * 1024 }'
}

# Usage: ollama_mem_total_bytes; prints the machine's memory in bytes, or
# nothing when it cannot be told. OLLAMA_BUDGET_MEM_TOTAL_BYTES overrides.
ollama_mem_total_bytes() {
  if _ollama_ep_is_uint "${OLLAMA_BUDGET_MEM_TOTAL_BYTES:-}"; then
    printf '%s\n' "$OLLAMA_BUDGET_MEM_TOTAL_BYTES"
  elif [[ -r /proc/meminfo ]]; then
    awk '$1 == "MemTotal:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.memsize 2>/dev/null | awk '/^[0-9]+$/ { print }'
  fi
}

# Usage: ollama_mem_available_bytes; prints the memory a new process could
# have now, or nothing when it cannot be told.
# OLLAMA_BUDGET_MEM_AVAILABLE_BYTES overrides.
ollama_mem_available_bytes() {
  if _ollama_ep_is_uint "${OLLAMA_BUDGET_MEM_AVAILABLE_BYTES:-}"; then
    printf '%s\n' "$OLLAMA_BUDGET_MEM_AVAILABLE_BYTES"
  elif [[ -r /proc/meminfo ]]; then
    awk '$1 == "MemAvailable:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo
  elif command -v vm_stat >/dev/null 2>&1; then
    # macOS: free and inactive pages can both be handed to a new process.
    vm_stat 2>/dev/null | awk '
      /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) size = $i }
      /^Pages free:/ || /^Pages inactive:/ { gsub(/[^0-9]/, "", $NF); pages += $NF }
      END { if (size && pages) printf "%.0f\n", size * pages }'
  fi
}

# Usage: ollama_gpu_mem_bytes; prints the memory of the largest NVIDIA GPU in
# bytes, or 0. OLLAMA_BUDGET_GPU_BYTES overrides. Apple silicon shares its
# memory with the GPU and is covered by ollama_mem_total_bytes.
ollama_gpu_mem_bytes() {
  if _ollama_ep_is_uint "${OLLAMA_BUDGET_GPU_BYTES:-}"; then
    printf '%s\n' "$OLLAMA_BUDGET_GPU_BYTES"
  elif command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
      | awk '/^[0-9]+/ { if ($1 > max) max = $1 } END { printf "%.0f\n", max * 1048576 }'
  else
    echo 0
  fi
}

# Usage: ollama_budget_check <pull_bytes> <largest_model_bytes> <models_dir>
#
# Whether the machine can take a download of pull_bytes into models_dir and
# then load a model of largest_model_bytes. Says what does not fit, on stderr,
# with the numbers.
#
# Returns 0 when it fits, 1 when the disk does not, 2 when memory does not,
# 3 when neither does.
#
# - Disk: what is free after the download must stay above
#   OLLAMA_DISK_RESERVE_GB (default 10).
# - Memory: the largest model plus OLLAMA_MEM_HEADROOM_PERCENT (default 20)
#   must fit in the machine's memory or in its GPU's. That is a refusal: no
#   amount of closing other programs makes it fit. Not fitting in what is
#   available *now* is only a warning, because that changes by the minute.
# - A figure that cannot be read (no df, no /proc/meminfo) is said and
#   skipped, not guessed.
# - OLLAMA_IGNORE_BUDGET=1 turns each refusal into a warning and returns 0.
ollama_budget_check() {
  local pull="${1:-0}" largest="${2:-0}" dir="${3:-.}"
  local reserve_gb="${OLLAMA_DISK_RESERVE_GB:-10}" headroom="${OLLAMA_MEM_HEADROOM_PERCENT:-20}"
  local free total available gpu need reserve after capacity
  local disk_short=0 mem_short=0 say=print_error
  _ollama_ep_is_uint "$pull" || pull=0
  _ollama_ep_is_uint "$largest" || largest=0
  _ollama_ep_is_uint "$reserve_gb" || reserve_gb=10
  _ollama_ep_is_uint "$headroom" || headroom=20
  [[ "${OLLAMA_IGNORE_BUDGET:-0}" != "1" ]] || say=print_warning

  if [[ "$pull" -gt 0 ]]; then
    free="$(ollama_disk_free_bytes "$dir")"
    if _ollama_ep_is_uint "$free"; then
      reserve=$((reserve_gb * 1000000000))
      after=$((free - pull))
      if [[ "$after" -lt "$reserve" ]]; then
        disk_short=1
        "$say" "Not enough disk for the models: the download is $(_ollama_ep_gb "$pull"), $(_ollama_ep_gb "$free") is free at ${dir}, and ${reserve_gb} GB must stay free (OLLAMA_DISK_RESERVE_GB)." >&2
      fi
    else
      print_warning "Free disk space at ${dir} could not be read; the download of $(_ollama_ep_gb "$pull") was not checked against it." >&2
    fi
  fi

  if [[ "$largest" -gt 0 ]]; then
    need=$((largest * (100 + headroom) / 100))
    total="$(ollama_mem_total_bytes)"
    gpu="$(ollama_gpu_mem_bytes)"
    _ollama_ep_is_uint "$gpu" || gpu=0
    if _ollama_ep_is_uint "$total"; then
      capacity="$total"
      [[ "$gpu" -le "$capacity" ]] || capacity="$gpu"
      if [[ "$need" -gt "$capacity" ]]; then
        mem_short=1
        "$say" "Not enough memory for the largest model: it needs about $(_ollama_ep_gb "$need") to load, and this machine has $(_ollama_ep_gb "$total") of memory and $(_ollama_ep_gb "$gpu") on its GPU." >&2
      else
        available="$(ollama_mem_available_bytes)"
        if _ollama_ep_is_uint "$available" && [[ "$need" -gt "$available" && "$need" -gt "$gpu" ]]; then
          print_warning "The largest model needs about $(_ollama_ep_gb "$need") to load and $(_ollama_ep_gb "$available") is available right now. It fits this machine, but not beside what is running." >&2
        fi
      fi
    else
      print_warning "This machine's memory could not be read; the largest model ($(_ollama_ep_gb "$largest")) was not checked against it." >&2
    fi
  fi

  [[ "${OLLAMA_IGNORE_BUDGET:-0}" != "1" ]] || return 0
  return $((disk_short + 2 * mem_short))
}

# --- pulling what is missing, when it fits -----------------------------------

# Usage: ollama_endpoint_pull <base_url> <model>; asks that Ollama to pull the
# model and waits for it. Through the API, so it works for an Ollama on this
# machine and for one in a container alike, with no CLI.
# OLLAMA_PULL_TIMEOUT (default 3600 seconds) bounds the wait.
ollama_endpoint_pull() {
  local url="${1%/}" model="$2" body
  body="$(curl -fsS -m "${OLLAMA_PULL_TIMEOUT:-3600}" -H 'Content-Type: application/json' \
    -d "{\"name\": \"${model}\", \"stream\": false}" "${url}/api/pull" 2>/dev/null)" || return 1
  printf '%s' "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'
}

# Usage: ollama_endpoint_ensure_models <base_url> <models_dir> <model>...
#
# Makes sure that Ollama has every model listed, pulling what is missing only
# when the machine can take it. Nothing is pulled unless everything fits: a
# start that ends with half its models is worse than one that says no.
#
# models_dir is where that Ollama keeps its models, for the disk check: a
# directory on this machine, or Docker's data root for one in a container.
#
# Returns:
#   0  every model is there (already, or after pulling)
#   1  the disk cannot take the download        (see ollama_budget_check)
#   2  memory cannot take the largest model
#   3  neither can
#   4  nothing answers at base_url as an Ollama
#   5  models are missing and OLLAMA_PULL_MISSING=0 says not to pull
#   6  a pull failed
#   7  a model's size could not be learned, so the budget could not be checked
#
# Env: OLLAMA_PULL_MISSING (default 1), OLLAMA_IGNORE_BUDGET, and everything
# ollama_budget_check and ollama_registry_size_bytes read.
ollama_endpoint_ensure_models() {
  local url="${1%/}" dir="$2" present needed missing model size
  local pull_bytes=0 largest=0 unknown="" status=0
  shift 2
  needed="$(for model in "$@"; do ollama_model_tagged "$model"; done | awk '!seen[$0]++')"
  [[ -n "$needed" ]] || return 0

  if ! present="$(ollama_endpoint_models "$url")"; then
    print_error "No Ollama answers at ${url}." >&2
    return 4
  fi
  missing="$(ollama_models_missing "$needed" "$present")"
  [[ -n "$missing" ]] || return 0

  if [[ "${OLLAMA_PULL_MISSING:-1}" == "0" ]]; then
    print_error "The Ollama at ${url} lacks: $(printf '%s' "$missing" | tr '\n' ' '). Pulling is off (OLLAMA_PULL_MISSING=0)." >&2
    return 5
  fi

  # Sizes of everything needed: the missing ones add up to the download, and
  # the largest of all of them is what has to fit in memory.
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    if size="$(ollama_registry_size_bytes "$model")" && _ollama_ep_is_uint "$size"; then
      [[ "$size" -le "$largest" ]] || largest="$size"
      if printf '%s\n' "$missing" | grep -qxF -- "$model"; then
        pull_bytes=$((pull_bytes + size))
      fi
    elif printf '%s\n' "$missing" | grep -qxF -- "$model"; then
      unknown="${unknown}${model} "
    fi
  done <<EOF
$needed
EOF

  if [[ -n "$unknown" ]]; then
    if [[ "${OLLAMA_IGNORE_BUDGET:-0}" == "1" ]]; then
      print_warning "The size of ${unknown}could not be learned from the registry; pulling without a disk or memory check (OLLAMA_IGNORE_BUDGET=1)." >&2
    else
      print_error "The size of ${unknown}could not be learned from the registry, so nothing says whether it fits. Pull it by hand, or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked." >&2
      return 7
    fi
  fi

  ollama_budget_check "$pull_bytes" "$largest" "$dir" || status=$?
  if [[ "$status" -ne 0 ]]; then
    print_error "Nothing was pulled. Missing: $(printf '%s' "$missing" | tr '\n' ' ')" >&2
    return "$status"
  fi

  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    print_info "Pulling ${model} into the Ollama at ${url}"
    if ! ollama_endpoint_pull "$url" "$model"; then
      print_error "Pulling ${model} failed." >&2
      return 6
    fi
  done <<EOF
$missing
EOF
  return 0
}
