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
# Written for bash 3.2 and BSD userland, and for a caller that runs with
# `set -euo pipefail` as well as one that does not: no pipeline here may end a
# strict caller, and no function reads a positional parameter it was not given.

# --- what counts as a name, a model, a number --------------------------------

# A variable name. Checked before a name reaches `${!name}` (an indirect
# expansion evaluates a subscript: `x[$(cmd)]` runs cmd) or a sed program.
_ollama_ep_is_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# A model reference: letters, digits and . _ - / : @ only, no "..". Checked
# before a model reaches a URL or a JSON string built by hand.
_ollama_ep_is_model() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] || return 1
  case "$1" in *..*|*//*) return 1 ;; esac
  return 0
}

# Usage: _ollama_ep_uint <value>; prints value as a base-10 integer, or fails.
# Up to 15 digits: more wraps bash arithmetic. Leading zeros are dropped,
# because bash reads "08" as bad octal and "010" as eight.
_ollama_ep_uint() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  while [[ "${#value}" -gt 1 && "${value:0:1}" == "0" ]]; do value="${value:1}"; done
  [[ "${#value}" -le 15 ]] || return 1
  printf '%s\n' "$value"
}

# Bytes as "N.N GB". A GB here is 10^9 bytes, as Ollama shows a model's size,
# so the figures in a refusal can be held against `ollama list`.
_ollama_ep_gb() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f GB", b / 1000000000 }'
}

# A URL as it may be shown: without the user and password it can carry
# (http://user:secret@host). Messages go to logs. Everything up to the last
# "@" of the authority goes, which is where curl ends the credentials too: a
# password may itself contain an "@".
_ollama_ep_shown() {
  printf '%s' "${1:-}" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/?\#]*@#\1#' || true
}

# Text from the other end as it may be shown: one line, printable characters
# only, cut short. What an endpoint answers is not ours, and a terminal obeys
# the escape sequences in what it is shown.
_ollama_ep_said() {
  printf '%s' "${1:-}" | tr -d '\r' | tail -n 1 | LC_ALL=C tr -cd '[:print:]' | cut -c1-300 || true
}

# --- the models file ---------------------------------------------------------
#
# One assignment per line: NAME=model. Read as an env file is read: `export `
# before the name, spaces around `=`, one pair of quotes around the value and a
# trailing ` # comment` are not part of the value, nor is a carriage return.

# Usage: ollama_models_file_get <file> <NAME>; prints the value of NAME, or
# nothing. The last line for a name wins. Returns 2 for a NAME that is not a
# variable name.
ollama_models_file_get() {
  local file="${1:-}" name="${2:-}" value
  _ollama_ep_is_name "$name" || return 2
  [[ -f "$file" ]] || return 0
  value="$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*=[[:space:]]*//p" "$file" | tail -n 1)" || true
  value="${value%$'\r'}"
  case "$value" in
    \"*\"*) value="${value#\"}"; value="${value%%\"*}" ;;
    \'*\'*) value="${value#\'}"; value="${value%%\'*}" ;;
    *)
      value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//')" || true
      ;;
  esac
  printf '%s\n' "$value"
}

# Usage: ollama_models_file_names <file>; prints every name the file assigns,
# one per line, in file order, each once.
ollama_models_file_names() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 0
  sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$file" \
    | awk '!seen[$0]++' || true
}

# Usage: ollama_model_tagged <model>; prints the model as Ollama lists it:
# with a tag (":latest" when none is given), and without the default
# registry's host or its "library/" namespace, which Ollama leaves out.
# The tag is looked for in the last path segment only:
# "registry.example:5000/team/model" has a port, not a tag.
ollama_model_tagged() {
  local model="${1:-}" last
  [[ -n "$model" ]] || return 0
  model="${model#registry.ollama.ai/}"
  model="${model#library/}"
  last="${model##*/}"
  case "$last" in
    *:*) printf '%s\n' "$model" ;;
    *)   printf '%s:latest\n' "$model" ;;
  esac
}

# Usage: ollama_models_required <file> [NAME...]; prints the models a start
# needs, as Ollama lists them, one per line, each once.
#
# With no NAME, every name in the file that is not part of a large tier (a
# name ending in _LARGE or _LARGE_VRAM_GB). For each name a non-blank value in
# the environment wins over the file, so a caller that has loaded its own .env
# gets that machine's choice.
#
# Returns 2, printing nothing, when a NAME is not a variable name: a list cut
# short at the bad name would start a project with some of its models.
ollama_models_required() {
  local file="${1:-}" name value names
  [[ $# -eq 0 ]] || shift
  if [[ $# -gt 0 ]]; then
    for name in "$@"; do
      if ! _ollama_ep_is_name "$name"; then
        print_error "Not a variable name: ${name}" >&2
        return 2
      fi
    done
    names="$(printf '%s\n' "$@")"
  else
    names="$(ollama_models_file_names "$file" | grep -v -E '_LARGE(_VRAM_GB)?$' || true)"
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    value="${!name:-}"
    # Trimmed: a padded value in the environment is the same model.
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
    [[ -n "$value" ]] || value="$(ollama_models_file_get "$file" "$name")"
    [[ -n "$value" ]] || continue
    ollama_model_tagged "$value"
  done <<<"$names" | awk '!seen[$0]++'
  return 0
}

# --- what an endpoint has ----------------------------------------------------

# Usage: ollama_endpoint_models <base_url> [timeout_seconds=5]; prints the
# models that Ollama has, one per line, as it names them (with tags).
# Returns 1 when nothing answers there or what answers is not an Ollama.
ollama_endpoint_models() {
  local url="${1:-}" timeout="${2:-5}" body names
  url="${url%/}"
  [[ -n "$url" ]] || return 1
  body="$(curl -fsS -m "$timeout" "${url}/api/tags" 2>/dev/null | tr -d '\n\r')" || return 1
  # Any web server answers 200 to something. An Ollama's answer has "models".
  grep -q '"models"[[:space:]]*:' <<<"$body" || return 1
  # A model's entry has "name" and then "model". A "name" anywhere else in the
  # answer (a nested object) is not followed by one.
  names="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*"model"' <<<"$body" || true)"
  if [[ -z "$names" ]]; then
    # An Ollama old enough to list "name" alone: the first key of each entry.
    names="$(grep -o '{[[:space:]]*"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$body" || true)"
  fi
  [[ -n "$names" ]] || return 0
  sed -E 's/^[^:]*:[[:space:]]*"//; s/".*$//' <<<"$names"
}

# Usage: ollama_models_missing <needed> <present>; both are newline-separated
# lists. Prints the needed models that are not present, one per line. A model
# matches only its whole name: "qwen:7b" is not satisfied by "qwen:7b-instruct".
ollama_models_missing() {
  local needed="${1:-}" present="${2:-}" model
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    grep -qxF -- "$model" <<<"$present" || printf '%s\n' "$model"
  done <<<"$needed"
  return 0
}

# --- how big, and how much room ----------------------------------------------

# Usage: ollama_registry_size_bytes <model>; prints the size of the model's
# download in bytes, from the registry's manifest.
# Returns 1 when the registry did not answer, has no such model, answered
# with something that is not a model's manifest, or the model is not a model
# reference; 2 when the model lives on another registry host (its size is not
# asked for).
# OLLAMA_REGISTRY_URL (default https://registry.ollama.ai) and
# OLLAMA_REGISTRY_TIMEOUT (default 15) apply.
#
# The figure is every layer in the manifest. Layers the machine already holds
# for another model are counted again, so it can only overstate.
ollama_registry_size_bytes() {
  local ref tag name path body first
  local base="${OLLAMA_REGISTRY_URL:-https://registry.ollama.ai}"
  ref="$(ollama_model_tagged "${1:-}")"
  _ollama_ep_is_model "$ref" || return 1
  tag="${ref##*:}"
  name="${ref%:"$tag"}"
  [[ -n "$tag" && -n "$name" ]] || return 1
  # A colon left in the name is a host's port: another registry.
  [[ "$name" != *:* ]] || return 2
  first="${name%%/*}"
  case "$name" in
    */*/*) return 2 ;;
    */*)
      # host/model: a first segment with a dot is a host, not a namespace.
      case "$first" in *.*|localhost) return 2 ;; esac
      path="$name"
      ;;
    *) path="library/$name" ;;
  esac
  body="$(curl -fsS -m "${OLLAMA_REGISTRY_TIMEOUT:-15}" \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "${base%/}/v2/${path}/manifests/${tag}" 2>/dev/null | tr -d '\n\r')" || return 1
  # A model's manifest has layers. An index of manifests, or a web page that
  # happens to say "size", does not, and its sum would pass any budget.
  grep -q '"layers"[[:space:]]*:' <<<"$body" || return 1
  { grep -o '"size"[[:space:]]*:[[:space:]]*[0-9][0-9]*[^0-9.eE]' <<<"$body" || true; } \
    | awk -F: '{ gsub(/[^0-9]/, "", $2); if ($2 != "") { total += $2; n++ } }
               END { if (!n) exit 1; printf "%.0f\n", total }'
}

# Usage: ollama_disk_free_bytes <path>; prints the bytes free on the
# filesystem holding path (or its nearest existing parent). Nothing when it
# cannot be told. OLLAMA_BUDGET_DISK_FREE_BYTES overrides.
ollama_disk_free_bytes() {
  local path="${1:-.}" stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_DISK_FREE_BYTES:-}")"; then
    printf '%s\n' "$stated"
    return 0
  fi
  while [[ -n "$path" && "$path" != "/" && "$path" != "." && ! -e "$path" ]]; do
    path="$(dirname "$path")"
  done
  # "Available" is the field before the one that ends in %. Counted from the
  # left it moves when the filesystem's name has a space in it.
  { df -Pk "${path:-/}" 2>/dev/null || true; } | awk '
    NR == 2 {
      for (i = NF; i > 1; i--) if ($i ~ /^[0-9]+%$/) {
        if ($(i - 1) ~ /^[0-9]+$/) printf "%.0f\n", $(i - 1) * 1024
        exit
      }
    }'
}

# Usage: ollama_mem_total_bytes; prints the machine's memory in bytes, or
# nothing when it cannot be told. OLLAMA_BUDGET_MEM_TOTAL_BYTES overrides.
ollama_mem_total_bytes() {
  local stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_MEM_TOTAL_BYTES:-}")"; then
    printf '%s\n' "$stated"
  elif [[ -r /proc/meminfo ]]; then
    awk '$1 == "MemTotal:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo || true
  elif command -v sysctl >/dev/null 2>&1; then
    { sysctl -n hw.memsize 2>/dev/null || true; } | awk '/^[0-9]+$/ { print }'
  fi
}

# Usage: ollama_mem_available_bytes; prints the memory a new process could
# have now, or nothing when it cannot be told.
# OLLAMA_BUDGET_MEM_AVAILABLE_BYTES overrides.
ollama_mem_available_bytes() {
  local stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_MEM_AVAILABLE_BYTES:-}")"; then
    printf '%s\n' "$stated"
  elif [[ -r /proc/meminfo ]]; then
    awk '$1 == "MemAvailable:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo || true
  elif command -v vm_stat >/dev/null 2>&1; then
    # macOS: free and inactive pages can both be handed to a new process.
    { vm_stat 2>/dev/null || true; } | awk '
      /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) size = $i }
      /^Pages free:/ || /^Pages inactive:/ { gsub(/[^0-9]/, "", $NF); pages += $NF }
      END { if (size && pages) printf "%.0f\n", size * pages }'
  fi
}

# Usage: ollama_gpu_mem_bytes; prints the memory of this machine's NVIDIA
# GPUs together, in bytes, or 0. Together, because Ollama spreads a model
# over them. OLLAMA_BUDGET_GPU_BYTES overrides. Apple silicon shares its
# memory with the GPU and is covered by ollama_mem_total_bytes.
ollama_gpu_mem_bytes() {
  local stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_GPU_BYTES:-}")"; then
    printf '%s\n' "$stated"
  elif command -v nvidia-smi >/dev/null 2>&1; then
    # A driver that cannot be reached is no GPU, not a reason to stop.
    { nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true; } \
      | awk '/^[0-9]+/ { sum += $1 } END { printf "%.0f\n", sum * 1048576 }'
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
#   must fit in the machine's memory and its GPUs' together, since Ollama
#   splits a model between them. More than that is a refusal. Not fitting in
#   what is available *now* is only a warning: that changes by the minute.
# - A figure that cannot be read (no df, no /proc/meminfo) is said and
#   skipped, not guessed.
# - OLLAMA_IGNORE_BUDGET=1 turns each refusal into a warning and returns 0.
#
# The figures are this machine's unless each OLLAMA_BUDGET_* is stated: for an
# Ollama on another machine, state all four.
ollama_budget_check() {
  local dir="${3:-.}" pull largest reserve_gb headroom
  local free total available gpu need reserve after capacity
  local disk_short=0 mem_short=0 say=print_error
  pull="$(_ollama_ep_uint "${1:-0}")" || pull=0
  largest="$(_ollama_ep_uint "${2:-0}")" || largest=0
  reserve_gb="$(_ollama_ep_uint "${OLLAMA_DISK_RESERVE_GB:-10}")" || reserve_gb=10
  headroom="$(_ollama_ep_uint "${OLLAMA_MEM_HEADROOM_PERCENT:-20}")" || headroom=20
  # A reserve or headroom beyond any machine is a typing mistake, not a wish.
  [[ "$reserve_gb" -le 100000 ]] || reserve_gb=10
  [[ "$headroom" -le 1000 ]] || headroom=20
  [[ "${OLLAMA_IGNORE_BUDGET:-0}" != "1" ]] || say=print_warning

  if [[ "$pull" -gt 0 ]]; then
    free="$(_ollama_ep_uint "$(ollama_disk_free_bytes "$dir")")" || free=""
    if [[ -n "$free" ]]; then
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
    total="$(_ollama_ep_uint "$(ollama_mem_total_bytes)")" || total=0
    gpu="$(_ollama_ep_uint "$(ollama_gpu_mem_bytes)")" || gpu=0
    capacity=$((total + gpu))
    if [[ "$need" -le "$gpu" ]]; then
      : # The GPUs hold it, whatever the rest of the machine is.
    elif [[ "$total" -eq 0 ]]; then
      print_warning "This machine's memory could not be read; the largest model ($(_ollama_ep_gb "$largest")) was not checked against it." >&2
    elif [[ "$need" -gt "$capacity" ]]; then
      mem_short=1
      "$say" "Not enough memory for the largest model: it needs about $(_ollama_ep_gb "$need") to load, and this machine has $(_ollama_ep_gb "$total") of memory and $(_ollama_ep_gb "$gpu") on its GPUs." >&2
    else
      available="$(_ollama_ep_uint "$(ollama_mem_available_bytes)")" || available=""
      if [[ -n "$available" && "$need" -gt $((available + gpu)) ]]; then
        print_warning "The largest model needs about $(_ollama_ep_gb "$need") to load and $(_ollama_ep_gb "$available") of memory is available right now. It fits this machine, but not beside what is running." >&2
      fi
    fi
  fi

  [[ "${OLLAMA_IGNORE_BUDGET:-0}" != "1" ]] || return 0
  return $((disk_short + 2 * mem_short))
}

# --- pulling what is missing, when it fits -----------------------------------

# Usage: ollama_endpoint_pull <base_url> <model>; asks that Ollama to pull the
# model and waits for it. Through the API, so it works for an Ollama on this
# machine and for one in a container alike, with no CLI.
#
# The download is not given a deadline: a large model on a slow line takes
# hours. It is given up when nothing at all arrives for
# OLLAMA_PULL_STALL_SECONDS (default 600); Ollama reports progress throughout.
# Returns 1 when the pull did not end in success; what Ollama said last is
# printed on stderr.
ollama_endpoint_pull() {
  local url="${1:-}" model="${2:-}" body status stall
  url="${url%/}"
  if [[ -z "$url" ]] || ! _ollama_ep_is_model "$model"; then
    print_error "Not a model reference: ${model}" >&2
    return 1
  fi
  stall="$(_ollama_ep_uint "${OLLAMA_PULL_STALL_SECONDS:-600}")" || stall=600
  status=0
  body="$(curl -sS -N --speed-limit 1 --speed-time "$stall" -H 'Content-Type: application/json' \
    -d "{\"name\": \"${model}\", \"stream\": true}" "${url}/api/pull" 2>&1)" || status=$?
  # The stream is one JSON object per line; the last says how it ended. An
  # error anywhere in it is a failed pull, whatever the HTTP status was.
  if [[ "$status" -eq 0 ]] && ! grep -q '"error"[[:space:]]*:' <<<"$body"; then
    if tail -n 1 <<<"$body" | grep -q '^[[:space:]]*{[[:space:]]*"status"[[:space:]]*:[[:space:]]*"success"'; then
      return 0
    fi
  fi
  body="$(_ollama_ep_said "$body")"
  # curl names the URL it could not reach, credentials and all.
  body="${body//"$url"/$(_ollama_ep_shown "$url")}"
  print_error "The Ollama at $(_ollama_ep_shown "$url") did not pull ${model}: ${body:-no answer}" >&2
  return 1
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
#   7  the budget could not be checked: a missing model's size, or the free
#      disk space, could not be learned
#   8  an argument is not a model reference
#
# Env: OLLAMA_PULL_MISSING (default 1), OLLAMA_IGNORE_BUDGET, and everything
# ollama_budget_check, ollama_registry_size_bytes and ollama_endpoint_pull read.
ollama_endpoint_ensure_models() {
  local url="${1:-}" dir="${2:-.}" present needed missing model size shown
  local pull_bytes=0 largest=0 unknown="" unsized="" status=0
  url="${url%/}"
  [[ $# -lt 2 ]] || shift 2
  shown="$(_ollama_ep_shown "$url")"
  needed=""
  for model in "$@"; do
    model="$(ollama_model_tagged "$model")"
    [[ -n "$model" ]] || continue
    if ! _ollama_ep_is_model "$model"; then
      print_error "Not a model reference: ${model}" >&2
      return 8
    fi
    grep -qxF -- "$model" <<<"$needed" || needed="${needed}${needed:+$'\n'}${model}"
  done
  [[ -n "$needed" ]] || return 0

  if ! present="$(ollama_endpoint_models "$url")"; then
    print_error "No Ollama answers at ${shown}." >&2
    return 4
  fi
  missing="$(ollama_models_missing "$needed" "$present")"
  [[ -n "$missing" ]] || return 0

  if [[ "${OLLAMA_PULL_MISSING:-1}" == "0" ]]; then
    print_error "The Ollama at ${shown} lacks: $(tr '\n' ' ' <<<"$missing"). Pulling is off (OLLAMA_PULL_MISSING=0)." >&2
    return 5
  fi

  # Sizes of everything needed: the missing ones add up to the download, and
  # the largest of all of them is what has to fit in memory.
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    size="$(ollama_registry_size_bytes "$model")" || size=""
    if size="$(_ollama_ep_uint "$size")"; then
      [[ "$size" -le "$largest" ]] || largest="$size"
      if grep -qxF -- "$model" <<<"$missing"; then
        pull_bytes=$((pull_bytes + size))
      fi
    elif grep -qxF -- "$model" <<<"$missing"; then
      unknown="${unknown}${model} "
    else
      unsized="${unsized}${model} "
    fi
  done <<<"$needed"

  if [[ -n "$unsized" ]]; then
    # Already there, so nothing to download; but it may be the largest.
    print_warning "The size of ${unsized}could not be learned from the registry; memory was not checked for it." >&2
  fi
  if [[ -n "$unknown" ]]; then
    if [[ "${OLLAMA_IGNORE_BUDGET:-0}" == "1" ]]; then
      print_warning "The size of ${unknown}could not be learned from the registry; pulling without a disk or memory check (OLLAMA_IGNORE_BUDGET=1)." >&2
    else
      print_error "The size of ${unknown}could not be learned from the registry, so nothing says whether it fits. Pull it by hand, or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked." >&2
      return 7
    fi
  fi
  if [[ "$pull_bytes" -gt 0 && "${OLLAMA_IGNORE_BUDGET:-0}" != "1" ]]; then
    if ! _ollama_ep_uint "$(ollama_disk_free_bytes "$dir")" >/dev/null; then
      # Not knowing the room is the same lack as not knowing the size.
      print_error "Free disk space at ${dir} could not be read, so nothing says whether $(_ollama_ep_gb "$pull_bytes") fits. State it with OLLAMA_BUDGET_DISK_FREE_BYTES, or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked." >&2
      return 7
    fi
  fi

  ollama_budget_check "$pull_bytes" "$largest" "$dir" || status=$?
  if [[ "$status" -ne 0 ]]; then
    print_error "Nothing was pulled. Missing: $(tr '\n' ' ' <<<"$missing")" >&2
    return "$status"
  fi

  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    print_info "Pulling ${model} into the Ollama at ${shown}" >&2
    ollama_endpoint_pull "$url" "$model" || return 6
  done <<<"$missing"
  return 0
}
