#!/usr/bin/env bash
# Ollama endpoint helpers for a project's start script. They answer three
# questions, in order, before anything is pulled:
#   1. Which models does the project need?
#   2. Which of them does this Ollama not have yet?
#   3. Does the machine have room for those (disk for the download, memory
#      for the largest model)?
# Models are pulled only if the answer to 3 is yes.
#
# A project lists its models in one env-style file, one NAME=model per line.
#
# Expected imports by caller (via shlib_import): logging
#
# Works on bash 3.2 and BSD tools. Safe for a caller that uses
# `set -euo pipefail`: no pipeline here can end such a caller, and no function
# reads an argument it was not given.

# --- what counts as a name, a model, a number --------------------------------

# True for a valid variable name. Checked before the name is used in
# `${!name}` (bash would run a command hidden in `x[$(cmd)]`) or in a sed
# program.
_ollama_ep_is_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# True for a valid model reference: letters, digits and . _ - / : only, and no
# "..". Checked before the model is put into a URL or a JSON string.
# "@" is not allowed. It would mean credentials (user:secret@registry/model),
# which must not be printed or stored, or a digest (model@sha256:...), which
# cannot be sized here or matched against the names an Ollama lists.
_ollama_ep_is_model() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]] || return 1
  case "$1" in *..*|*//*) return 1 ;; esac
  return 0
}

# Usage: _ollama_ep_uint <value>; prints value as a whole number, or fails.
# At most 15 digits, because more overflows bash arithmetic. Leading zeros are
# removed, because bash reads "08" as an invalid octal number and "010" as 8.
_ollama_ep_uint() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  while [[ "${#value}" -gt 1 && "${value:0:1}" == "0" ]]; do value="${value:1}"; done
  [[ "${#value}" -le 15 ]] || return 1
  printf '%s\n' "$value"
}

# Bytes as "N.N GB". 1 GB is 10^9 bytes, the same unit `ollama list` uses, so
# the numbers in a message can be compared with it.
_ollama_ep_gb() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f GB", b / 1000000000 }'
}

# A URL that is safe to print. Removed:
# - user and password (user:secret@host, with or without a scheme). Everything
#   up to the last "@" before the first "/" goes, because a password may
#   contain an "@" itself; curl reads it the same way.
# - the query and fragment (?... and #...), where a token may be.
# - control characters.
_ollama_ep_shown() {
  # Backslashes are doubled, last. The logging helpers print with `echo -e`,
  # which would turn the text \033[2J into a real escape sequence.
  printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177' \
    | sed -E 's|[?#].*$||; s|^([a-zA-Z][a-zA-Z0-9+.-]*://)?[^/]*@|\1|; s|\\|\\\\|g' || true
}

# Text from the other side (Ollama, curl) that is safe to print: the last
# line only, no control characters, at most 300 characters. A terminal obeys
# escape sequences in what it prints, and this text is not ours.
_ollama_ep_said() {
  # - Control characters are removed by octal range. Not all `tr` know
  #   [:print:] (busybox reads it as plain letters).
  # - Credentials in any URL (://user:secret@) are removed before the cut to 300
  #   characters. A cut in the middle of them would leave half a password.
  # - Backslashes are doubled, for the same `echo -e` as in _ollama_ep_shown.
  printf '%s' "${1:-}" | tr -d '\r' | tail -n 1 | LC_ALL=C tr -d '\000-\037\177' \
    | sed -E 's|(://)[^/@[:space:]]*@|\1|g' | cut -c1-300 | sed 's|\\|\\\\|g' || true
}

# --- the models file ---------------------------------------------------------
#
# One NAME=model per line, read like an env file. Not part of the value:
# `export ` before the name, spaces around `=`, one pair of quotes, a trailing
# ` # comment`, and a carriage return (Windows line ends).

# Usage: ollama_models_file_get <file> <NAME>; prints the value of NAME, or
# nothing. If NAME is set twice, the last line wins. Returns 2 if NAME is not
# a valid variable name.
ollama_models_file_get() {
  local file="${1:-}" name="${2:-}" value bom=$'\xef\xbb\xbf'
  _ollama_ep_is_name "$name" || return 2
  [[ -f "$file" ]] || return 0
  # Remove a byte-order mark (some editors add one at the start of a file).
  # With it, the first variable in the file was never found.
  value="$(sed -n -E "1s/^${bom}//; s/^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*=[[:space:]]*//p" "$file" | tail -n 1)" || true
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
  local file="${1:-}" bom=$'\xef\xbb\xbf'
  [[ -f "$file" ]] || return 0
  # The byte-order mark: see ollama_models_file_get.
  sed -n -E "1s/^${bom}//; "'s/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$file" \
    | awk '!seen[$0]++' || true
}

# Usage: ollama_model_tagged <model>; prints the model the way Ollama lists
# it: with a tag (":latest" if none is given), and without the default
# registry's host or "library/" prefix.
# Only the part after the last "/" is checked for a tag:
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
# needs, the way Ollama lists them, one per line, each once.
#
# With no NAME: every name in the file, except the ones for other machine
# classes. A name ending in _SMALL, _LARGE or _XLARGE is the model for another
# class; a name ending in _RAM_GB or _VRAM_GB after that is a number used to
# pick the class, not a model.
# A non-blank value in the environment wins over the file. So a caller that
# has loaded its own .env gets that machine's choice.
#
# Returns 2 and prints nothing if a NAME is not a valid variable name. A list
# that stopped at the bad name would start a project with only some of its
# models.
# Returns 1 and prints nothing if a file is given and does not exist. A
# mistyped path would otherwise mean "this project needs no models", and the
# start would check nothing. Pass "" to use no file.
ollama_models_required() {
  local file="${1:-}" name value names
  [[ $# -eq 0 ]] || shift
  if [[ -n "$file" && ! -f "$file" ]]; then
    print_error "No models file at $(_ollama_ep_said "$file")" >&2
    return 1
  fi
  if [[ $# -gt 0 ]]; then
    for name in "$@"; do
      if ! _ollama_ep_is_name "$name"; then
        print_error "Not a variable name: $(_ollama_ep_said "$name")" >&2
        return 2
      fi
    done
    names="$(printf '%s\n' "$@")"
  else
    names="$(ollama_models_file_names "$file" | grep -v -E '_(SMALL|LARGE|XLARGE)(_V?RAM_GB)?$' || true)"
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    value="${!name:-}"
    # Trimmed: a padded value in the environment is the same model.
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
    [[ -n "$value" ]] || value="$(ollama_models_file_get "$file" "$name")"
    [[ -n "$value" ]] || continue
    ollama_model_tagged "$value"
  done <<<"$names" | awk '!seen[tolower($0)]++'
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
  # Any web server may answer 200. An Ollama's answer contains "models".
  grep -q '"models"[[:space:]]*:' <<<"$body" || return 1
  # In a model's entry "name" is followed by "model". A "name" elsewhere in
  # the answer (inside a nested object) is not.
  names="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*"model"' <<<"$body" || true)"
  if [[ -z "$names" ]]; then
    # An old Ollama lists "name" only: take the first key of each entry.
    names="$(grep -o '{[[:space:]]*"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$body" || true)"
  fi
  [[ -n "$names" ]] || return 0
  sed -E 's/^[^:]*:[[:space:]]*"//; s/".*$//' <<<"$names"
}

# Usage: ollama_models_missing <needed> <present>; both are lists, one model
# per line. Prints the needed models that are not present.
# Only a whole name matches: "qwen:7b-instruct" does not count as "qwen:7b".
# Upper and lower case are the same, as they are to Ollama ("Qwen:7B" is the
# model it lists as "qwen:7b").
ollama_models_missing() {
  local needed="${1:-}" present="${2:-}" model
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    grep -qixF -- "$model" <<<"$present" || printf '%s\n' "$model"
  done <<<"$needed"
  return 0
}

# --- how big, and how much room ----------------------------------------------

# Usage: ollama_registry_size_bytes <model>; prints the download size of the
# model in bytes, read from the registry's manifest.
# Returns 1 if the registry does not answer, does not have the model, answers
# with something that is not a model's manifest, or the model reference is not
# valid. Returns 2 if the model is on another registry host: its size is not
# asked for.
# Env: OLLAMA_REGISTRY_URL (default https://registry.ollama.ai),
# OLLAMA_REGISTRY_TIMEOUT (default 15 seconds).
#
# The size is the sum of all layers in the manifest. Layers the machine
# already has from another model are counted again, so the number can be too
# high but never too low.
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
  # A model's manifest has "layers". A list of manifests, or a web page that
  # contains "size", does not. Summing those would give a number that passes
  # any check.
  grep -q '"layers"[[:space:]]*:' <<<"$body" || return 1
  { grep -o '"size"[[:space:]]*:[[:space:]]*[0-9][0-9]*[^0-9.eE]' <<<"$body" || true; } \
    | awk -F: '{ gsub(/[^0-9]/, "", $2); if ($2 != "") { total += $2; n++ } }
               END { if (!n) exit 1; printf "%.0f\n", total }'
}

# Usage: ollama_disk_free_bytes <path>; prints the free bytes on the
# filesystem that holds path (or its nearest existing parent). Prints nothing
# if it cannot be read. OLLAMA_BUDGET_DISK_FREE_BYTES overrides.
ollama_disk_free_bytes() {
  local path="${1:-.}" stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_DISK_FREE_BYTES:-}")"; then
    printf '%s\n' "$stated"
    return 0
  fi
  while [[ -n "$path" && "$path" != "/" && "$path" != "." && ! -e "$path" ]]; do
    path="$(dirname "$path")"
  done
  # "Available" is the field just before the one ending in "%". Counting
  # fields from the left fails when the filesystem's name contains a space.
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

# Usage: ollama_gpu_mem_bytes; prints the total memory of this machine's
# NVIDIA GPUs in bytes, or 0. The total, because Ollama spreads one model over
# several GPUs. OLLAMA_BUDGET_GPU_BYTES overrides. On Apple silicon the GPU
# shares the machine's memory, which ollama_mem_total_bytes already reports.
ollama_gpu_mem_bytes() {
  local stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_GPU_BYTES:-}")"; then
    printf '%s\n' "$stated"
  elif command -v nvidia-smi >/dev/null 2>&1; then
    # If the driver does not answer, count no GPU instead of failing.
    { nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true; } \
      | awk '/^[0-9]+/ { sum += $1 } END { printf "%.0f\n", sum * 1048576 }'
  else
    echo 0
  fi
}

# Usage: ollama_budget_check <pull_bytes> <largest_model_bytes> <models_dir>
#
# Checks that the machine can download pull_bytes into models_dir and then
# load a model of largest_model_bytes. Prints what does not fit, with the
# numbers, on stderr.
#
# Returns 0 if it fits, 1 if the disk is too small, 2 if memory is too small,
# 3 if both are. Returns 4 if a size is not a whole number: then nothing was
# checked, also with OLLAMA_IGNORE_BUDGET set.
#
# - Disk: after the download, at least OLLAMA_DISK_RESERVE_GB (default 10)
#   must stay free.
# - Memory: the largest model plus OLLAMA_MEM_HEADROOM_PERCENT (default 20)
#   must fit in the machine's memory plus its GPUs' memory, because Ollama
#   splits a model between the two. If it does not fit, that is a refusal.
#   If it fits the machine but not the memory free right now, that is only a
#   warning: free memory changes from minute to minute.
# - A number that cannot be read (no df, no /proc/meminfo) is reported and
#   skipped, never guessed.
# - OLLAMA_IGNORE_BUDGET=1 turns each refusal into a warning and returns 0.
#
# The numbers are this machine's. For an Ollama on another machine, set all
# four OLLAMA_BUDGET_* variables.
ollama_budget_check() {
  local dir="${3:-.}" pull largest reserve_gb headroom
  local free total available gpu need reserve after capacity
  local disk_short=0 mem_short=0 say=print_error shown_dir
  # A size that is not a number is the caller's mistake. Reading it as zero
  # would approve a download that was never measured. No argument means zero.
  if ! pull="$(_ollama_ep_uint "${1:-0}")" || ! largest="$(_ollama_ep_uint "${2:-0}")"; then
    print_error "ollama_budget_check: a size in bytes is a whole number of at most 15 digits; got '$(_ollama_ep_said "${1:-}")' and '$(_ollama_ep_said "${2:-}")'." >&2
    return 4
  fi
  reserve_gb="$(_ollama_ep_uint "${OLLAMA_DISK_RESERVE_GB:-10}")" || reserve_gb=10
  headroom="$(_ollama_ep_uint "${OLLAMA_MEM_HEADROOM_PERCENT:-20}")" || headroom=20
  # A reserve or headroom larger than any machine is a typo: use the default.
  [[ "$reserve_gb" -le 100000 ]] || reserve_gb=10
  [[ "$headroom" -le 1000 ]] || headroom=20
  [[ "${OLLAMA_IGNORE_BUDGET:-0}" != "1" ]] || say=print_warning
  # The directory name comes from the caller: make it safe to print.
  shown_dir="$(_ollama_ep_said "$dir")"

  if [[ "$pull" -gt 0 ]]; then
    free="$(_ollama_ep_uint "$(ollama_disk_free_bytes "$dir")")" || free=""
    if [[ -n "$free" ]]; then
      reserve=$((reserve_gb * 1000000000))
      after=$((free - pull))
      if [[ "$after" -lt "$reserve" ]]; then
        disk_short=1
        "$say" "Not enough disk for the models: the download is $(_ollama_ep_gb "$pull"), $(_ollama_ep_gb "$free") is free at ${shown_dir}, and ${reserve_gb} GB must stay free (OLLAMA_DISK_RESERVE_GB)." >&2
      fi
    else
      print_warning "Free disk space at ${shown_dir} could not be read; the download of $(_ollama_ep_gb "$pull") was not checked against it." >&2
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
# model and waits until it is done. It uses the HTTP API, so it works the same
# for an Ollama on this machine and one in a container, without the CLI.
#
# There is no time limit for the whole download: a large model on a slow line
# takes hours. The pull is given up only if nothing at all arrives for
# OLLAMA_PULL_STALL_SECONDS (default 600).
# Progress is printed on stderr, one line for each 10% of every layer of
# 100 MB or more, so a long download does not look like a hang.
# Returns 1 if the pull did not end in success, and prints the last thing
# Ollama said on stderr.
ollama_endpoint_pull() {
  local url="${1:-}" model="${2:-}" verdict stall
  url="${url%/}"
  if [[ -z "$url" ]] || ! _ollama_ep_is_model "$model"; then
    print_error "Not a model reference: $(_ollama_ep_shown "$model")" >&2
    return 1
  fi
  stall="$(_ollama_ep_uint "${OLLAMA_PULL_STALL_SECONDS:-600}")" || stall=600
  # The answer is a stream: one JSON object per line, and the last line says
  # how it ended.
  # - An "error" anywhere in the stream is a failure, whatever the HTTP status.
  # - curl's own error message goes into the same stream (2>&1) and becomes the
  #   last line, so a broken transfer is not a success either.
  # - The stream is read line by line and not stored: hours of progress lines
  #   are many megabytes.
  # - The model is sent under two keys: "model" is the API's name for it, and
  #   "name" is what an older Ollama reads.
  verdict="$(curl -sS -N --speed-limit 1 --speed-time "$stall" -H 'Content-Type: application/json' \
    -d "{\"model\": \"${model}\", \"name\": \"${model}\", \"stream\": true}" "${url}/api/pull" 2>&1 \
    | awk -v model="$model" '
      function field(key,   text) {
        if (!match($0, "\"" key "\"[ \t]*:[ \t]*[0-9]+")) return -1
        text = substr($0, RSTART, RLENGTH); sub(/^.*:[ \t]*/, "", text)
        return text + 0
      }
      {
        sub(/\r$/, "")
        if ($0 == "") next
        last = $0
        if ($0 ~ /"error"[ \t]*:/) failed = 1
        total = field("total"); done = field("completed")
        if (total < 100000000 || done < 0) next
        layer = match($0, /"digest"[ \t]*:[ \t]*"[^"]*"/) ? substr($0, RSTART, RLENGTH) : "-"
        tenth = int(done * 10 / total)
        if (!(layer in said)) {
          # First time a layer is seen: print nothing if it has not started
          # (0%) or Ollama already has all of it (100%).
          said[layer] = tenth
          if (tenth == 0 || tenth >= 10) next
        } else if (tenth <= said[layer]) next
        said[layer] = tenth
        # Printed through `cat 1>&2`, which keeps stderr as it is. Some awks
        # open /dev/stderr as a new file, which would overwrite the start of a
        # log the caller is writing to.
        # (No apostrophe may appear in this awk program: it would end the
        # shell string around it.)
        printf "  %s: %d%% of %.1f GB\n", model, tenth * 10, total / 1000000000 | "cat 1>&2"
        fflush("cat 1>&2")
      }
      END {
        if (!failed && last ~ /^[ \t]*[{][ \t]*"status"[ \t]*:[ \t]*"success"/) print "ok"
        else print "no:" last
      }')" || true
  [[ "$verdict" != "ok" ]] || return 0
  # curl prints the URL it could not reach, credentials included. Replace
  # the whole URL before the text is cut to length, so no part of it is left.
  verdict="${verdict#no:}"
  verdict="${verdict//"$url"/$(_ollama_ep_shown "$url")}"
  verdict="$(_ollama_ep_said "$verdict")"
  print_error "The Ollama at $(_ollama_ep_shown "$url") did not pull ${model}: ${verdict:-no answer}" >&2
  return 1
}

# Usage: ollama_endpoint_ensure_models <base_url> <models_dir> <model>...
#
# Makes sure that Ollama has every model listed. Missing models are pulled
# only if the machine has room for all of them: nothing is pulled unless
# everything fits. A start with half its models is worse than a clear "no".
#
# models_dir is where that Ollama stores its models, for the disk check: a
# directory on this machine, or Docker's data root for an Ollama in a
# container.
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
  # If the directory is left out, there are no models either: the only
  # argument left is the URL, and it must not be read as a model.
  if [[ $# -ge 2 ]]; then shift 2; else shift $#; fi
  shown="$(_ollama_ep_shown "$url")"
  needed=""
  for model in "$@"; do
    model="$(ollama_model_tagged "$model")"
    [[ -n "$model" ]] || continue
    if ! _ollama_ep_is_model "$model"; then
      print_error "Not a model reference: $(_ollama_ep_shown "$model")" >&2
      return 8
    fi
    grep -qixF -- "$model" <<<"$needed" || needed="${needed}${needed:+$'\n'}${model}"
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

  # Get the size of every needed model. The missing ones add up to the
  # download. The largest of all of them must fit in memory.
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
    # Already present, so no download. But it may be the largest model.
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
      # Unknown free space is as bad as unknown size: refuse.
      print_error "Free disk space at $(_ollama_ep_said "$dir") could not be read, so nothing says whether $(_ollama_ep_gb "$pull_bytes") fits. State it with OLLAMA_BUDGET_DISK_FREE_BYTES, or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked." >&2
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
