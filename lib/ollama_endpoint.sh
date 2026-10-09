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
# LC_ALL=C in both rules: in other locales [A-Za-z] takes accented letters.
_ollama_ep_is_name() { local LC_ALL=C; [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# True for a valid model reference: letters, digits and . _ - / : only, and no
# "..". Checked before the model is put into a URL or a JSON string.
# "@" is not allowed. It would mean credentials (user:secret@registry/model),
# which must not be printed or stored, or a digest (model@sha256:...), which
# cannot be sized here or matched against the names an Ollama lists.
_ollama_ep_is_model() {
  local LC_ALL=C
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]] || return 1
  # No empty part: "qwen3:" has no tag, "qwen3/" has no name after the slash.
  # Ollama calls these an invalid model name. Without this they got as far as
  # the registry and failed there with a message about the size.
  case "$1" in *..*|*//*|*:|*/|*::*|*/:*|*:/*) return 1 ;; esac
  return 0
}

# Usage: _ollama_ep_on <NAME> <on|off>; true if the setting NAME is on. The
# second argument is what an unset or empty NAME means.
# On: 1 true yes on. Off: 0 false no off never. Case does not matter.
# Any other value is a typo. It is reported and read as off, which for every
# setting here is the careful side: pull nothing, skip no check.
_ollama_ep_on() {
  local name="${1:-}" default="${2:-off}" value
  _ollama_ep_is_name "$name" || return 1
  value="$(printf '%s' "${!name:-}" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" || true
  case "${value:-$default}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off|never) return 1 ;;
  esac
  print_warning "${name} is neither on (1, true, yes) nor off (0, false, no): '$(_ollama_ep_said "${!name:-}")'. Read as off." >&2
  return 1
}

# Usage: _ollama_ep_pull_mode; prints on, off or ask for OLLAMA_PULL_MISSING
# (default on). ask: pull only after a yes on a terminal (_ollama_ep_ask_pull).
# Anything else is said once and read as off, as _ollama_ep_on does.
_ollama_ep_pull_mode() {
  local value
  value="$(printf '%s' "${OLLAMA_PULL_MISSING:-}" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" || true
  case "${value:-on}" in
    ask) printf 'ask\n' ;;
    1|true|yes|on) printf 'on\n' ;;
    0|false|no|off|never) printf 'off\n' ;;
    *)
      print_warning "OLLAMA_PULL_MISSING is neither on (1, true, yes), off (0, false, no) nor ask: '$(_ollama_ep_said "${OLLAMA_PULL_MISSING:-}")'. Read as off." >&2
      printf 'off\n'
      ;;
  esac
}

# Usage: _ollama_ep_can_ask; true when there is a person to ask: stdin and
# stderr are a terminal. A desktop launcher, a service or CI has neither.
# A function so a test can stand in for the terminal.
_ollama_ep_can_ask() {
  [[ -t 0 && -t 2 ]]
}

# Usage: _ollama_ep_ask_pull <shown url> <listing>; true on a yes. The listing
# is one "model  size" line per missing model. Asked on stderr, read from stdin,
# so a caller that captures stdout still gets the question.
_ollama_ep_ask_pull() {
  local shown="${1:-}" listing="${2:-}" answer=""
  printf 'The Ollama at %s lacks:\n%s\nPull now? [y/N] ' "$shown" "$listing" >&2
  IFS= read -r answer || answer=""
  case "$(printf '%s' "$answer" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" in
    y|yes) return 0 ;;
  esac
  return 1
}

# Usage: _ollama_ep_pull_hint <url> <missing, one per line>; prints the ways
# past a refusal under ask: the exact pull commands, and the setting that pulls
# without asking. OLLAMA_HOST is named unless the address is Ollama's own
# default here, or `ollama pull` would fill another Ollama than this one.
_ollama_ep_pull_hint() {
  local url="${1:-}" missing="${2:-}" host="" cmds="" m
  case "${url#*://}" in
    127.0.0.1:11434|localhost:11434) ;;
    *) host="OLLAMA_HOST=$(_ollama_ep_shown_url "$url") " ;;
  esac
  while IFS= read -r m; do
    [[ -n "$m" ]] && cmds="${cmds}${cmds:+; }${host}ollama pull ${m}"
  done <<<"$missing"
  printf 'Pull it with: %s. Or set OLLAMA_PULL_MISSING=1 to pull without asking.' "$cmds"
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

# A URL as it is named in a message: scheme, host and port only. Besides what
# _ollama_ep_shown removes, the path goes too: a proxy may serve an Ollama
# under a path that holds a key (https://gateway/KEY/ollama).
_ollama_ep_shown_url() {
  printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177' \
    | sed -E -e 's|[?#].*$||' -e 's|^([a-zA-Z][a-zA-Z0-9+.-]*://)?[^/]*@|\1|' \
        -e '/:\/\//!s|^([^/]*)/.*$|\1|' -e 's|^([a-zA-Z][a-zA-Z0-9+.-]*://[^/]*)/.*$|\1|' \
        -e 's|\\|\\\\|g' || true
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
  # Its own variables start with _oep_: a NAME is read through ${!NAME}, and a
  # local called "name" or "value" would be read in place of the caller's.
  local _oep_file="${1:-}" _oep_name _oep_value _oep_names
  [[ $# -eq 0 ]] || shift
  if [[ -n "$_oep_file" && ! -f "$_oep_file" ]]; then
    print_error "No models file at $(_ollama_ep_said "$_oep_file")" >&2
    return 1
  fi
  if [[ $# -gt 0 ]]; then
    for _oep_name in "$@"; do
      if ! _ollama_ep_is_name "$_oep_name"; then
        print_error "Not a variable name: $(_ollama_ep_said "$_oep_name")" >&2
        return 2
      fi
    done
    _oep_names="$(printf '%s\n' "$@")"
  else
    _oep_names="$(ollama_models_file_names "$_oep_file" | grep -v -E '_(SMALL|LARGE|XLARGE)(_V?RAM_GB)?$' || true)"
  fi
  while IFS= read -r _oep_name; do
    [[ -n "$_oep_name" ]] || continue
    _oep_value="${!_oep_name:-}"
    # Trimmed: a padded value in the environment is the same model.
    _oep_value="$(printf '%s' "$_oep_value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
    [[ -n "$_oep_value" ]] || _oep_value="$(ollama_models_file_get "$_oep_file" "$_oep_name")"
    [[ -n "$_oep_value" ]] || continue
    ollama_model_tagged "$_oep_value"
  done <<<"$_oep_names" | awk '!seen[tolower($0)]++'
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
# Returns 1 if the registry does not answer, answers with something that is
# not a model's manifest, or the model reference is not valid. Returns 2 if the
# model is on another registry host: its size is not asked for. Returns 3 if
# the registry answers that it has no such model or tag (measured: HTTP 404
# with the code MANIFEST_UNKNOWN for both). That is a name to correct, not a
# registry to wait for.
# Env: OLLAMA_REGISTRY_URL (default https://registry.ollama.ai),
# OLLAMA_REGISTRY_TIMEOUT (default 15 seconds).
#
# The size is the sum of all layers in the manifest. Layers the machine
# already has from another model are counted again, so the number can be too
# high but never too low.
ollama_registry_size_bytes() {
  local ref tag name path body first answer code
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
  # The status goes on a line of its own after the body: without -f, so that
  # a 404's body can be read.
  answer="$(curl -sS -m "${OLLAMA_REGISTRY_TIMEOUT:-15}" -w '\n%{http_code}' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "${base%/}/v2/${path}/manifests/${tag}" 2>/dev/null)" || return 1
  code="${answer##*$'\n'}"
  body="$(printf '%s' "${answer%$'\n'*}" | tr -d '\n\r')" || true
  if [[ "$code" == "404" ]]; then
    # Only the registry's own "unknown" counts. Any web server says 404 for a
    # path it does not have, and a mistyped OLLAMA_REGISTRY_URL is not a
    # mistyped model.
    grep -q -E '"(MANIFEST|NAME)_UNKNOWN"' <<<"$body" || return 1
    return 3
  fi
  case "$code" in 2??) ;; *) return 1 ;; esac
  # A model's manifest has "layers". A list of manifests, or a web page that
  # contains "size", does not. Summing those would give a number that passes
  # any check.
  grep -q '"layers"[[:space:]]*:' <<<"$body" || return 1
  { grep -o '"size"[[:space:]]*:[[:space:]]*[0-9][0-9]*[^0-9.eE]' <<<"$body" || true; } \
    | awk -F: '{ gsub(/[^0-9]/, "", $2); if ($2 != "") { total += $2; n++ } }
               END { if (!n) exit 1; printf "%.0f\n", total }'
}

# Usage: ollama_models_dir; prints where an Ollama on this machine keeps its
# models, for the disk check:
# - OLLAMA_MODELS when set (Ollama's own variable for it);
# - else the directory of the Linux service, when there is one: the installer
#   sets Ollama up as a service with a user of its own, and that user's home
#   is not $HOME;
# - else ~/.ollama/models (an Ollama started by hand, and macOS).
# The directory need not exist yet: ollama_disk_free_bytes reads its nearest
# existing parent. Not for an Ollama in a container: pass Docker's data root.
ollama_models_dir() {
  local service="${_OLLAMA_EP_SERVICE_MODELS:-/usr/share/ollama/.ollama/models}"
  if [[ -n "${OLLAMA_MODELS:-}" ]]; then
    printf '%s\n' "$OLLAMA_MODELS"
  elif [[ -d "$service" || -d "${service%/.ollama/models}" ]]; then
    # The service user's home is often closed to others (drwxr-x---): its
    # being there is enough, and the disk is read from the nearest parent.
    printf '%s\n' "$service"
  else
    printf '%s\n' "${HOME:-}/.ollama/models"
  fi
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
  local disk_short=0 mem_short=0 say=print_error shown_dir ignore=0
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
  if _ollama_ep_on OLLAMA_IGNORE_BUDGET off; then ignore=1; say=print_warning; fi
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

  [[ "$ignore" -eq 0 ]] || return 0
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
        size[layer] = total
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
        if (!failed && last ~ /^[ \t]*[{][ \t]*"status"[ \t]*:[ \t]*"success"/) {
          # Ollama goes from the last progress line to verifying without ever
          # saying completed == total (measured: a real pull stopped at 90%).
          # A layer that was being counted is said to be done once the pull is.
          for (layer in said) if (said[layer] < 10) {
            printf "  %s: 100%% of %.1f GB\n", model, size[layer] / 1000000000 | "cat 1>&2"
          }
          print "ok"
        } else print "no:" last
      }')" || true
  [[ "$verdict" != "ok" ]] || return 0
  # curl prints the URL it could not reach, credentials included. Replace
  # the whole URL before the text is cut to length, so no part of it is left.
  verdict="${verdict#no:}"
  verdict="${verdict//"$url"/$(_ollama_ep_shown_url "$url")}"
  # A proxy that echoes the request path ("Cannot POST /key/ollama/api/pull")
  # would print the path, and a key in it, through the server's own words.
  local path="${url#*://}"
  if [[ "$path" == */* ]]; then path="/${path#*/}"; verdict="${verdict//"$path"/}"; fi
  verdict="$(_ollama_ep_said "$verdict")"
  print_error "The Ollama at $(_ollama_ep_shown_url "$url") did not pull ${model}: ${verdict:-no answer}" >&2
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
#   5  models are missing and OLLAMA_PULL_MISSING=0 says not to pull, or
#      OLLAMA_PULL_MISSING=ask and the answer was not yes, or there was no
#      terminal to ask on
#   6  a pull failed
#   7  the budget could not be checked: a missing model's size, or the free
#      disk space, could not be learned
#   8  an argument is not a model reference
#
# Env: OLLAMA_PULL_MISSING (on, off or ask; default on), OLLAMA_IGNORE_BUDGET, and everything
# ollama_budget_check, ollama_registry_size_bytes and ollama_endpoint_pull read.
ollama_endpoint_ensure_models() {
  local url="${1:-}" dir="${2:-.}" present needed missing model size shown
  local pull_bytes=0 largest=0 unknown="" unsized="" nowhere="" status=0 ignore=0 asked
  local pull_mode listing=""
  url="${url%/}"
  # If the directory is left out, there are no models either: the only
  # argument left is the URL, and it must not be read as a model.
  if [[ $# -ge 2 ]]; then shift 2; else shift $#; fi
  shown="$(_ollama_ep_shown_url "$url")"
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

  pull_mode="$(_ollama_ep_pull_mode)"
  if [[ "$pull_mode" == "off" ]]; then
    print_error "The Ollama at ${shown} lacks: ${missing//$'\n'/ }. Pulling is off (OLLAMA_PULL_MISSING)." >&2
    return 5
  fi
  # Read once here, and passed on as 1 or 0, so a typo is reported once.
  if _ollama_ep_on OLLAMA_IGNORE_BUDGET off; then ignore=1; fi

  # Get the size of every needed model. The missing ones add up to the
  # download. The largest of all of them must fit in memory.
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    asked=0
    size="$(ollama_registry_size_bytes "$model")" || asked=$?
    [[ "$asked" -eq 0 ]] || size=""
    if size="$(_ollama_ep_uint "$size")"; then
      [[ "$size" -le "$largest" ]] || largest="$size"
      if grep -qxF -- "$model" <<<"$missing"; then
        pull_bytes=$((pull_bytes + size))
        listing="${listing}  ${model}  $(_ollama_ep_gb "$size")"$'\n'
      fi
    elif grep -qxF -- "$model" <<<"$missing"; then
      unknown="${unknown}${model} "
      listing="${listing}  ${model}  size unknown"$'\n'
      [[ "$asked" -ne 3 ]] || nowhere="${nowhere}${model} "
    else
      unsized="${unsized}${model} "
    fi
  done <<<"$needed"

  if [[ -n "$unsized" ]]; then
    # Already present, so no download. But it may be the largest model.
    print_warning "The size of ${unsized}could not be learned from the registry; memory was not checked for it." >&2
  fi
  if [[ -n "$nowhere" && "$ignore" -eq 0 ]]; then
    # Said apart from "could not be learned": waiting or pulling by hand does
    # not help with a name that is wrong.
    # "Or none it shows": the registry answers the same for a model that is
    # private, when asked without signing in.
    print_error "The registry has no model named ${nowhere% }, or none it shows without signing in: check the name and its tag. Nothing was pulled." >&2
    return 7
  fi
  if [[ -n "$unknown" ]]; then
    if [[ "$ignore" -eq 1 ]]; then
      print_warning "The size of ${unknown}could not be learned from the registry; pulling without a disk or memory check (OLLAMA_IGNORE_BUDGET=1)." >&2
    else
      print_error "The size of ${unknown}could not be learned from the registry, so nothing says whether it fits. Pull it by hand, or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked." >&2
      return 7
    fi
  fi
  if [[ "$pull_bytes" -gt 0 && "$ignore" -eq 0 ]]; then
    if ! _ollama_ep_uint "$(ollama_disk_free_bytes "$dir")" >/dev/null; then
      # Unknown free space is as bad as unknown size: refuse.
      print_error "Free disk space at $(_ollama_ep_said "$dir") could not be read, so nothing says whether $(_ollama_ep_gb "$pull_bytes") fits. State it with OLLAMA_BUDGET_DISK_FREE_BYTES, or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked." >&2
      return 7
    fi
  fi

  OLLAMA_IGNORE_BUDGET="$ignore" ollama_budget_check "$pull_bytes" "$largest" "$dir" || status=$?
  if [[ "$status" -ne 0 ]]; then
    print_error "Nothing was pulled. Missing: ${missing//$'\n'/ }" >&2
    return "$status"
  fi

  # Asked only now: a question about a download that would not fit is no
  # question, and the sizes are known for the listing.
  if [[ "$pull_mode" == "ask" ]]; then
    if ! _ollama_ep_can_ask; then
      # A total is only said when every size is known (OLLAMA_IGNORE_BUDGET
      # lets an unknown one through), or it would understate the download.
      local total=""
      [[ -n "$unknown" ]] || total=" ($(_ollama_ep_gb "$pull_bytes") to download)"
      print_error "The Ollama at ${shown} lacks: ${missing//$'\n'/ }${total}. OLLAMA_PULL_MISSING=ask and there is no terminal to ask on, so nothing was pulled. Run this again from a terminal. $(_ollama_ep_pull_hint "$url" "$missing")" >&2
      return 5
    fi
    if ! _ollama_ep_ask_pull "$shown" "${listing%$'\n'}"; then
      print_error "Nothing was pulled. Missing: ${missing//$'\n'/ }. $(_ollama_ep_pull_hint "$url" "$missing")" >&2
      return 5
    fi
  fi

  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    print_info "Pulling ${model} into the Ollama at ${shown}" >&2
    ollama_endpoint_pull "$url" "$model" || return 6
  done <<<"$missing"
  return 0
}

# --- a project's own configuration -------------------------------------------
#
# Projects name the address of their Ollama in different ways: OLLAMA_URL,
# OLLAMA_BASE_URL, OLLAMA_HOST holding a URL, a name with the project's prefix.
# Some put the API path in it, and a project whose backend is in a container
# writes host.docker.internal or the compose service's name. Many keep the
# value in a .env that their start script never sources. The functions below
# turn that into what the rest of this module takes.
#
# Their own variables start with _oep_: a caller's NAME (an address variable
# called "url", a model variable called "name") is read through ${!NAME}, and
# a local of the same name would be read in its place.

# Usage: ollama_endpoint_base_url <address>; prints the base URL of the Ollama
# at an address as a project configures it:
# - "host", "host:port" or ":port" gets http://, and port 11434 when none is
#   given, as Ollama reads OLLAMA_HOST. No host is this machine (127.0.0.1),
#   and an IPv6 address without brackets gets them;
# - a URL keeps its scheme and port (none given stays none: 80 or 443, for an
#   Ollama behind a proxy), its credentials and any path a proxy serves it under;
# - the API path some projects store with it is removed when it ends the URL
#   (/api, /v1, /api/generate, /api/chat, /v1/chat/completions and the other
#   endpoints of the two APIs), with a query, a fragment and a trailing slash.
#   "/api/ollama" is a proxy's path and stays.
# Returns 1, printing nothing, for what is not an address: empty, another
# scheme, a space or a control character in it, a port that is not a number, a
# host with a character no host has, or an "@" after the first "/", "?" or
# "#". That last one is a password with such a character in it: it has to be
# percent-encoded, curl refuses the URL, and read by halves it would be
# printed.
ollama_endpoint_base_url() {
  local LC_ALL=C
  local _oep_value="${1:-}" _oep_scheme _oep_rest _oep_authority _oep_path="" _oep_hostport _oep_user="" _oep_host _oep_port=""
  _oep_value="$(printf '%s' "$_oep_value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
  [[ -n "$_oep_value" ]] || return 1
  [[ "$_oep_value" != *[[:space:][:cntrl:]]* ]] || return 1
  case "$_oep_value" in
    [Hh][Tt][Tt][Pp]://*) _oep_scheme="http"; _oep_rest="${_oep_value#*://}" ;;
    [Hh][Tt][Tt][Pp][Ss]://*) _oep_scheme="https"; _oep_rest="${_oep_value#*://}" ;;
    *://*) return 1 ;;
    # "http:" and "http:/host": a URL that lost its slashes, not a host called http.
    [Hh][Tt][Tt][Pp]:*|[Hh][Tt][Tt][Pp][Ss]:*) return 1 ;;
    *) _oep_scheme=""; _oep_rest="$_oep_value" ;;
  esac
  case "$_oep_rest" in *[/?#]*@*) return 1 ;; esac
  _oep_rest="${_oep_rest%%[?#]*}"
  _oep_authority="${_oep_rest%%/*}"
  [[ "$_oep_rest" != */* ]] || _oep_path="/${_oep_rest#*/}"
  _oep_hostport="$_oep_authority"
  if [[ "$_oep_authority" == *@* ]]; then
    _oep_user="${_oep_authority%@*}@"
    _oep_hostport="${_oep_authority##*@}"
  fi
  case "$_oep_hostport" in
    \[*\]:*) _oep_host="${_oep_hostport%%\]*}]"; _oep_port="${_oep_hostport##*\]:}" ;;
    \[*\]) _oep_host="$_oep_hostport" ;;
    \[*|*\]*) return 1 ;;
    *:*:*) _oep_host="[${_oep_hostport}]" ;;
    *:*) _oep_host="${_oep_hostport%%:*}"; _oep_port="${_oep_hostport##*:}" ;;
    *) _oep_host="$_oep_hostport" ;;
  esac
  [[ -z "$_oep_port" || ( "$_oep_port" =~ ^[0-9]+$ && "${#_oep_port}" -le 5 && "$_oep_port" -ge 1 && "$_oep_port" -le 65535 ) ]] || return 1
  if [[ -z "$_oep_host" ]]; then
    # ":11434" and "http://:11434": the port of this machine, as Ollama reads it.
    [[ -n "$_oep_port" ]] || return 1
    _oep_host="127.0.0.1"
  fi
  case "$_oep_host" in
    \[*\]) [[ "$_oep_host" =~ ^\[[0-9A-Fa-f:.]+(%[A-Za-z0-9._-]+)?\]$ ]] || return 1 ;;
    *) [[ "$_oep_host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1 ;;
  esac
  if [[ -z "$_oep_scheme" ]]; then
    _oep_scheme="http"
    [[ -n "$_oep_port" ]] || _oep_port="11434"
  fi
  # The API path is not part of the base, when it is what the URL ends with.
  # An API path is removed however it was written: /v1, /api/v1, /api/v1/chat/completions.
  local _oep_before=""
  while [[ "$_oep_path" != "$_oep_before" ]]; do
    _oep_before="$_oep_path"
    _oep_path="$(printf '%s' "$_oep_path" | sed -E 's#/+$##; s#/(api(/(generate|chat|tags|embed|embeddings|pull|push|show|version|ps|create|copy|delete))?|v1(/(chat/completions|completions|embeddings|models))?)$##; s#/+$##')" || true
  done
  printf '%s://%s%s%s%s\n' "$_oep_scheme" "$_oep_user" "$_oep_host" "${_oep_port:+:$_oep_port}" "$_oep_path"
}

# Usage: _ollama_ep_host <url>; prints the host of a URL, in lower case,
# without credentials, port, brackets or a trailing dot. The path is cut
# first: an "@" in it is not the end of credentials.
_ollama_ep_host() {
  local _oep_rest="${1:-}"
  _oep_rest="${_oep_rest#*://}"
  _oep_rest="${_oep_rest%%[/?#]*}"
  _oep_rest="${_oep_rest##*@}"
  case "$_oep_rest" in
    \[*) _oep_rest="${_oep_rest#\[}"; _oep_rest="${_oep_rest%%\]*}" ;;
    *) _oep_rest="${_oep_rest%%:*}" ;;
  esac
  _oep_rest="${_oep_rest%.}"
  printf '%s\n' "$_oep_rest" | tr 'A-Z' 'a-z'
}

# True inside a container (Docker writes /.dockerenv).
# Docker and Podman leave a marker file; Kubernetes sets a variable in every
# pod. _OLLAMA_EP_DOCKERENV is a test seam: when set, it alone decides.
_ollama_ep_in_container() {
  if [[ -n "${_OLLAMA_EP_DOCKERENV:-}" ]]; then [[ -e "$_OLLAMA_EP_DOCKERENV" ]]; return; fi
  [[ -e /.dockerenv || -e /run/.containerenv || -n "${KUBERNETES_SERVICE_HOST:-}" ]]
}

# Usage: ollama_endpoint_is_local <url>; returns 0 when the URL points at this
# machine, so that this machine's disk and memory are the ones a pull would
# use: a loopback name or address, 0.0.0.0, this host's name, one of its own
# addresses, and Docker's names for the host (host.docker.internal,
# gateway.docker.internal) when this is not a container itself. Inside one,
# those names are another machine: the host, with a disk this shell cannot see.
# Returns 1 for anything else, a name that only resolves to this machine
# included: read as another machine, nothing is pulled into it unasked, which
# is the safe way to be wrong.
ollama_endpoint_is_local() {
  local LC_ALL=C
  local _oep_host _oep_own
  _oep_host="$(_ollama_ep_host "${1:-}")"
  [[ -n "$_oep_host" ]] || return 1
  case "$_oep_host" in
    localhost|*.localhost|::1|0.0.0.0|::) return 0 ;;
    host.docker.internal|gateway.docker.internal)
      if _ollama_ep_in_container; then return 1; fi
      return 0
      ;;
  esac
  # Loopback as an address, also written as IPv4 inside IPv6.
  [[ ! "$_oep_host" =~ ^(::ffff:)?127\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  [[ ! "$_oep_host" =~ ^::ffff:7f[0-9a-f]{2}:[0-9a-f]{1,4}$ ]] || return 0
  _oep_own="$(hostname 2>/dev/null | tr 'A-Z' 'a-z')" || _oep_own=""
  if [[ -n "$_oep_own" ]] && [[ "$_oep_host" == "$_oep_own" || "$_oep_host" == "${_oep_own%%.*}" ]]; then
    return 0
  fi
  # This machine's own addresses, from every tool there is. Collected first
  # and searched after: `grep -q` leaves a pipeline early, and under pipefail
  # the tools it cut off would make a found address read as not found.
  _oep_own="$({
    ip -o addr 2>/dev/null | awk '{ print $4 }' || true
    ifconfig 2>/dev/null | awk '$1 == "inet" || $1 == "inet6" { print $2 }' || true
  } | sed -E 's#/.*$##; s#%.*$##; s#^addr:##' | tr 'A-Z' 'a-z')" || true
  grep -qxF -- "$_oep_host" <<<"$_oep_own"
}

# Usage: ollama_endpoint_container_reach <url>; for a project whose containers
# call this machine's Ollama at <url> (as the container writes it, e.g.
# http://host.docker.internal:11434). Returns 0 when a container can reach it:
# the Docker bridge's gateway, the address host.docker.internal resolves to
# with host-gateway, answers as an Ollama on <url>'s port.
# The answer on 127.0.0.1 proves nothing for a container: an Ollama that
# listens on loopback only is not on the bridge, unless a forwarder puts it
# there. The probe goes out from 127.0.0.1, not from the host's bridge address:
# a request with that address as its source is dropped on some hosts while
# containers are answered.
# Returns 0, checking nothing, when <url> is another machine (the container
# reaches it as the host does), with no Docker or none answering (compose says
# so itself), and with Docker Desktop or rootless Docker, whose containers do
# not come in on that bridge; the last two say they were not checked.
# Returns 4 when the bridge does not answer as an Ollama, 9 when <url> is not
# an address.
ollama_endpoint_container_reach() {
  local LC_ALL=C
  local _oep_url _oep_port _oep_info _oep_gw _oep_body _oep_scheme _oep_rest _oep_auth _oep_path _oep_user
  if ! _oep_url="$(ollama_endpoint_base_url "${1:-}")"; then
    print_error "Not the address of an Ollama: $(_ollama_ep_shown_url "${1:-}")" >&2
    return 9
  fi
  ollama_endpoint_is_local "$_oep_url" || return 0
  command -v docker >/dev/null 2>&1 || return 0
  _oep_info="$(docker info -f '{{.OperatingSystem}} {{json .SecurityOptions}}' 2>/dev/null)" || return 0
  case "$_oep_info" in
    *"Docker Desktop"*|*name=rootless*)
      print_info "Not checked whether a container reaches this machine's Ollama: with Docker Desktop or rootless Docker, containers do not come in on the bridge." >&2
      return 0
      ;;
  esac
  # The first IPv4 gateway of the default bridge: host-gateway is that address
  # unless the daemon sets host-gateway-ip.
  _oep_gw="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)" || _oep_gw=""
  [[ -n "$_oep_gw" ]] || return 0
  # The URL with its host swapped for the gateway: credentials and a proxy's
  # path stay, since the container sends them too.
  _oep_scheme="${_oep_url%%://*}"
  _oep_rest="${_oep_url#*://}"
  _oep_auth="${_oep_rest%%/*}"
  _oep_path="${_oep_rest#"$_oep_auth"}"
  _oep_user=""
  case "$_oep_auth" in *@*) _oep_user="${_oep_auth%@*}@"; _oep_auth="${_oep_auth##*@}" ;; esac
  _oep_port="${_oep_auth##*]}"
  case "$_oep_port" in
    *:*) _oep_port="${_oep_port##*:}" ;;
    *) if [[ "$_oep_scheme" == https ]]; then _oep_port=443; else _oep_port=80; fi ;;
  esac
  _oep_body="$(curl -sS -m 5 --interface 127.0.0.1 "${_oep_scheme}://${_oep_user}${_oep_gw}:${_oep_port}${_oep_path}/api/tags" 2>/dev/null | tr -d '\n\r')" || _oep_body=""
  # Any web server may answer 200. An Ollama's answer contains "models".
  if ! grep -q '"models"[[:space:]]*:' <<<"$_oep_body"; then
    print_error "A container cannot reach this machine's Ollama: it is not on the Docker bridge (${_oep_gw}:${_oep_port})." >&2
    print_error "An Ollama that listens on 127.0.0.1 only needs a forwarder onto the bridge (NikOS installs one with the engine); or run the project without Docker." >&2
    return 4
  fi
  return 0
}

# Usage: ollama_env_file_export <file> NAME...; exports each NAME from an
# env-style file, unless the environment already has a value for it that is
# not blank (a blank one is no choice, and the file's is used). The file is
# read as ollama_models_file_get reads one, as data: it is never sourced, so a
# value with a "$", a backquote or a space in it is only a value. A file that
# is not there exports nothing.
# Returns 2, exporting nothing, when a NAME is not a variable name.
ollama_env_file_export() {
  local _oep_file="${1:-}" _oep_name _oep_value
  [[ $# -eq 0 ]] || shift
  for _oep_name in "$@"; do
    if ! _ollama_ep_is_name "$_oep_name"; then
      print_error "Not a variable name: $(_ollama_ep_said "$_oep_name")" >&2
      return 2
    fi
  done
  [[ -f "$_oep_file" ]] || return 0
  for _oep_name in "$@"; do
    _oep_value="$(printf '%s' "${!_oep_name:-}" | tr -d ' \t\r\n')" || true
    [[ -z "$_oep_value" ]] || continue
    _oep_value="$(ollama_models_file_get "$_oep_file" "$_oep_name")" || true
    [[ -n "$_oep_value" ]] || continue
    # A caller that holds the variable read-only and blank would keep its
    # blank: the file's setting would be read as "not set", silently.
    if ! export "$_oep_name=$_oep_value" 2>/dev/null; then
      print_error "$_oep_name is set in $(_ollama_ep_said "$_oep_file") and cannot be set here: the caller holds it read-only." >&2
      return 9
    fi
  done
  return 0
}

# What a start check reads from a project's .env besides the models and the
# address.
_ollama_ep_settings() {
  printf '%s' "OLLAMA_MODE OLLAMA_PORT OLLAMA_HOST_PORT OLLAMA_PULL_MISSING OLLAMA_IGNORE_BUDGET OLLAMA_DISK_RESERVE_GB OLLAMA_MEM_HEADROOM_PERCENT OLLAMA_PULL_STALL_SECONDS OLLAMA_REGISTRY_URL OLLAMA_REGISTRY_TIMEOUT OLLAMA_MODELS OLLAMA_BUDGET_DISK_FREE_BYTES OLLAMA_BUDGET_MEM_TOTAL_BYTES OLLAMA_BUDGET_MEM_AVAILABLE_BYTES OLLAMA_BUDGET_GPU_BYTES"
}

# Where Docker keeps its data on this machine: the disk an Ollama in a
# container fills. OLLAMA_MODELS when the project states it.
_ollama_ep_docker_models_dir() {
  local _oep_root=""
  if [[ -n "${OLLAMA_MODELS:-}" ]]; then
    printf '%s\n' "$OLLAMA_MODELS"
    return 0
  fi
  _oep_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null | head -n 1)" || _oep_root=""
  case "$_oep_root" in /*) ;; *) _oep_root="/var/lib/docker" ;; esac
  printf '%s\n' "$_oep_root"
}

# Usage: ollama_project_ensure_models <models_file> [env_file] [NAME...]
#
# The whole start check for a project, from its own configuration:
#   ollama_project_ensure_models ai-models.env .env || exit $?
#
# 1. Reads the project's .env (env_file; "" for none, and a file that is not
#    there yet is no .env) as data, never sourcing it: the model names, the
#    address, OLLAMA_MODE and the settings of this module. A value in the
#    environment that is not blank wins.
# 2. The models are those of ollama_models_required <models_file> [NAME...];
#    pass "" for the file to take the NAMEs from the environment and .env alone.
# 3. The address is the first of the variables in OLLAMA_URL_VARS that has a
#    value (default: OLLAMA_URL, OLLAMA_BASE_URL, OLLAMA_HOST), made a base URL
#    by ollama_endpoint_base_url; http://127.0.0.1:11434 when none has. On the
#    host, Docker's name for the host (host.docker.internal) is this machine.
# 4. OLLAMA_MODE says where that Ollama, or whatever answers for it, runs. A
#    project sets it in .env; it is not guessed when it is set:
#      local   an Ollama on this machine. Its models are in ollama_models_dir,
#              and this machine's disk and memory are what a pull is checked
#              against. An address that is not this machine is a mistake (9).
#      docker  an Ollama in a container on this machine. The address a
#              container uses for it (http://ollama:11434, a compose service)
#              does not resolve from a start script, so it is read as this
#              machine, at the port in OLLAMA_PORT or OLLAMA_HOST_PORT when
#              one is set and at the address's own port otherwise. Its models
#              are on Docker's disk (OLLAMA_MODELS, else Docker's data root).
#      remote  an API on another machine: an Ollama, or anything else the
#              project talks to (a hosted API in production). Nothing is
#              measured here and nothing is pulled unless OLLAMA_PULL_MISSING
#              is set on. If it answers as an Ollama, the models it lacks are
#              a refusal (5); if it does not, there is nothing to check and
#              the start goes on (0).
#    Not set (or "auto"): local when the address is this machine
#    (ollama_endpoint_is_local), otherwise as remote, except that nothing
#    answering stays a refusal (4).
# 5. A pull into another machine, asked for with OLLAMA_PULL_MISSING, needs
#    that machine's figures stated (OLLAMA_BUDGET_DISK_FREE_BYTES and
#    OLLAMA_BUDGET_MEM_TOTAL_BYTES) or OLLAMA_IGNORE_BUDGET: without them it
#    is a refusal (7), not a check against this machine. This machine's free
#    memory and GPU are never counted for it.
#
# Returns what ollama_endpoint_ensure_models returns, and 9 for the project's
# configuration: a models file that is not there, a NAME or an entry of
# OLLAMA_URL_VARS that is not a variable name, an address that is not one, an
# OLLAMA_MODE that is not one of the three, or one the address contradicts.
# Nothing it reads from .env is left in the caller's environment.
ollama_project_ensure_models() (
  # The caller's IFS must not split the lists below: a caller in "strict mode"
  # has it set to newline and tab, and the names came out as one word.
  local IFS=$' \t\n'
  local _oep_file="${1:-}" _oep_env="${2:-}" _oep_url="" _oep_name _oep_value _oep_models _oep_names
  local _oep_mode _oep_where _oep_dir _oep_host _oep_port="" _oep_present _oep_missing
  local _oep_unasked=0 _oep_status=0 _oep_ignore=0
  local _oep_vars="${OLLAMA_URL_VARS:-OLLAMA_URL OLLAMA_BASE_URL OLLAMA_HOST}"
  local -a _oep_list=()
  if [[ $# -ge 2 ]]; then shift 2; else shift $#; fi
  # Lists below are split into words; none may be read as a file pattern.
  set -f
  # No file and no names would check nothing and return 0: a start that
  # believes its models are there.
  if [[ -z "$_oep_file" && $# -eq 0 ]]; then
    print_error "No models file and no names: name the models file, or the variables that hold the models (ollama_project_ensure_models \"\" .env OLLAMA_MODEL)." >&2
    exit 9
  fi

  # OLLAMA_URL_VARS may itself be in the project's .env.
  if [[ -n "$_oep_env" ]]; then
    ollama_env_file_export "$_oep_env" OLLAMA_URL_VARS || exit 9
    _oep_vars="${OLLAMA_URL_VARS:-OLLAMA_URL OLLAMA_BASE_URL OLLAMA_HOST}"
  fi
  for _oep_name in $_oep_vars; do
    if ! _ollama_ep_is_name "$_oep_name"; then
      print_error "OLLAMA_URL_VARS names something that is not a variable: $(_ollama_ep_said "$_oep_name")" >&2
      exit 9
    fi
  done

  if [[ -n "$_oep_env" ]]; then
    if [[ $# -gt 0 ]]; then
      _oep_names="$*"
    else
      _oep_names="$(ollama_models_file_names "$_oep_file" | tr '\n' ' ')" || _oep_names=""
    fi
    # shellcheck disable=SC2046,SC2086  # lists of names, one per word
    ollama_env_file_export "$_oep_env" $(_ollama_ep_settings) $_oep_vars $_oep_names || exit 9
  fi

  _oep_models="$(ollama_models_required "$_oep_file" "$@")" || exit 9
  [[ -n "$_oep_models" ]] || exit 0
  # One model per line. Split on lines, not on words: "small:3b embed" as one
  # value is one reference that is not valid, not two models.
  while IFS= read -r _oep_value; do
    [[ -z "$_oep_value" ]] || _oep_list+=("$_oep_value")
  done <<<"$_oep_models"

  for _oep_name in $_oep_vars; do
    _oep_value="$(printf '%s' "${!_oep_name:-}" | tr -d ' \t\r\n')" || true
    [[ -n "$_oep_value" ]] || continue
    if ! _oep_url="$(ollama_endpoint_base_url "${!_oep_name}")"; then
      # The value is not shown. It could not be read as an address, so what
      # it is instead is not known: a password with a slash in it, or a key
      # that was meant for another variable.
      print_error "${_oep_name} is not the address of an Ollama. It is a host, host:port or an http(s) URL; a password in it must be percent-encoded." >&2
      exit 9
    fi
    break
  done
  [[ -n "$_oep_url" ]] || _oep_url="${_OLLAMA_EP_DEFAULT_URL:-http://127.0.0.1:11434}"

  # Trimmed at the ends only: "lo cal" is a typo, not local. The value is not
  # repeated in the message; it may be anything that was meant for another
  # variable.
  _oep_mode="$(printf '%s' "${OLLAMA_MODE:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr 'A-Z' 'a-z')" || true
  case "$_oep_mode" in
    ""|auto) _oep_mode="auto" ;;
    local|host) _oep_mode="local" ;;
    docker|container) _oep_mode="docker" ;;
    remote|api|external) _oep_mode="remote" ;;
    *)
      print_error "OLLAMA_MODE is not local (an Ollama on this machine), docker (one in a container here) or remote (an API on another machine)." >&2
      exit 9
      ;;
  esac

  # Written for a container to find the host. A start script is on the host
  # (unless this is a container itself, where the name is the right one).
  _oep_host="$(_ollama_ep_host "$_oep_url")"
  if ! _ollama_ep_in_container; then
    case "$_oep_host" in
      host.docker.internal|gateway.docker.internal)
        _oep_url="$(printf '%s' "$_oep_url" | sed -E 's#(://([^/@]*@)?)(\[[^]/]*\]|[^/:@]+)#\1127.0.0.1#')" || true
        ;;
    esac
  fi

  case "$_oep_mode" in
    docker)
      if ! ollama_endpoint_is_local "$_oep_url" && ! _ollama_ep_in_container; then
        # On the host, the name a container calls it by (one label: a compose
        # service) is this machine, at the port the project publishes. Any
        # other name or address is another machine, and docker is the wrong
        # word for it. Inside a container the name is the right one as it is.
        if [[ "$_oep_host" == *.* || "$_oep_host" == *:* || "$_oep_host" =~ ^[0-9]+$ ]]; then
          print_error "OLLAMA_MODE is docker, and $(_ollama_ep_shown_url "$_oep_url") is another machine. A container here is named by its compose service name, or by localhost at its published port; use remote for an Ollama elsewhere." >&2
          exit 9
        fi
        for _oep_name in OLLAMA_PORT OLLAMA_HOST_PORT; do
          _oep_value="$(printf '%s' "${!_oep_name:-}" | tr -d ' \t\r\n')" || true
          [[ -n "$_oep_value" ]] || continue
          # A typo here would send the pull to whatever listens on the
          # address's own port: on many machines, the native Ollama.
          if ! _oep_port="$(_ollama_ep_uint "$_oep_value")" || [[ "$_oep_port" -lt 1 || "$_oep_port" -gt 65535 ]]; then
            print_error "$_oep_name is not a port number (1 to 65535)." >&2
            exit 9
          fi
          break
        done
        _oep_url="$(printf '%s' "$_oep_url" | sed -E 's#(://([^/@]*@)?)(\[[^]/]*\]|[^/:@]+)#\1127.0.0.1#')" || true
        if [[ -n "$_oep_port" ]]; then
          _oep_url="$(printf '%s' "$_oep_url" | sed -E "s#(://([^/@]*@)?127\\.0\\.0\\.1)(:[0-9]+)?#\\1:${_oep_port}#")" || true
        fi
      fi
      _oep_where="here"
      _oep_dir="$(_ollama_ep_docker_models_dir)"
      ;;
    local)
      if ! ollama_endpoint_is_local "$_oep_url"; then
        print_error "OLLAMA_MODE is local, and $(_ollama_ep_shown_url "$_oep_url") is not this machine. Use docker for an Ollama in a container here, or remote for one elsewhere." >&2
        exit 9
      fi
      _oep_where="here"
      _oep_dir="$(ollama_models_dir)"
      ;;
    remote)
      _oep_where="elsewhere"
      ;;
    *)
      if ollama_endpoint_is_local "$_oep_url"; then
        _oep_where="here"
        _oep_dir="$(ollama_models_dir)"
      else
        _oep_where="elsewhere"
      fi
      ;;
  esac

  if [[ "$_oep_where" == "elsewhere" ]]; then
    # Not a directory on this machine. The disk is read only if a pull was
    # asked for, and then the stated figures are what counts.
    _oep_dir="/"
    if ! _oep_present="$(ollama_endpoint_models "$_oep_url")"; then
      if [[ "$_oep_mode" == "remote" ]]; then
        # A hosted API that is not an Ollama, or one that is not up: neither
        # is something a start script on this machine can check or mend.
        print_info "OLLAMA_MODE is remote and $(_ollama_ep_shown_url "$_oep_url") does not answer as an Ollama: its models are not checked from here." >&2
        exit 0
      fi
      # Stop here (4). Asked again it might answer, and the pull that followed
      # would go into another machine, measured against this one's disk.
      print_error "No Ollama answers at $(_ollama_ep_shown_url "$_oep_url")." >&2
      _oep_status=4
    else
      _oep_missing="$(ollama_models_missing "$_oep_models" "$_oep_present")"
      _oep_value="$(printf '%s' "${OLLAMA_PULL_MISSING:-}" | tr -d ' \t\r\n')" || true
      if [[ -z "$_oep_value" ]]; then
        _oep_unasked=1
        export OLLAMA_PULL_MISSING=0
      elif [[ -n "$_oep_missing" && "$(_ollama_ep_pull_mode 2>/dev/null)" != "off" ]]; then
        # A pull into another machine was asked for. Said once here, so a typo
        # in the setting that would waive the check is not swallowed.
        if _ollama_ep_on OLLAMA_IGNORE_BUDGET off; then _oep_ignore=1; fi
        if [[ "$_oep_ignore" -eq 0 ]]; then
          if ! _ollama_ep_uint "${OLLAMA_BUDGET_DISK_FREE_BYTES:-}" >/dev/null || ! _ollama_ep_uint "${OLLAMA_BUDGET_MEM_TOTAL_BYTES:-}" >/dev/null; then
            # Its disk and memory were not stated. What would be read is this
            # machine's: the wrong one.
            print_error "That Ollama is another machine and lacks: ${_oep_missing//$'\n'/ }. Its free disk and its memory are not known here: state them (OLLAMA_BUDGET_DISK_FREE_BYTES, OLLAMA_BUDGET_MEM_TOTAL_BYTES), or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked. Nothing was pulled." >&2
            exit 7
          fi
          # Nothing of this machine is counted for that one: not its GPU, and
          # not what is free in its memory right now.
          _ollama_ep_uint "${OLLAMA_BUDGET_GPU_BYTES:-}" >/dev/null || export OLLAMA_BUDGET_GPU_BYTES=0
          _ollama_ep_uint "${OLLAMA_BUDGET_MEM_AVAILABLE_BYTES:-}" >/dev/null || export OLLAMA_BUDGET_MEM_AVAILABLE_BYTES="$OLLAMA_BUDGET_MEM_TOTAL_BYTES"
        fi
      fi
    fi
  fi

  if [[ "$_oep_status" -eq 0 ]]; then
    ollama_endpoint_ensure_models "$_oep_url" "$_oep_dir" "${_oep_list[@]}" || _oep_status=$?
  fi
  if [[ "$_oep_status" -eq 4 && "$_oep_mode" == "auto" ]]; then
    # A name of one word that is not this machine is most often a compose
    # service: it resolves inside that network and nowhere else.
    _oep_host="$(_ollama_ep_host "$_oep_url")"
    if [[ "$_oep_host" != *.* && "$_oep_host" != *:* ]] && ! ollama_endpoint_is_local "$_oep_url"; then
      print_error "If '$(_ollama_ep_said "$_oep_host")' is a compose service, its name resolves only inside that network. Set OLLAMA_MODE=docker (with OLLAMA_PORT when the published port differs), or give the address published on this machine." >&2
    fi
  fi
  if [[ "$_oep_status" -eq 5 && "$_oep_unasked" -eq 1 ]]; then
    print_error "That Ollama is another machine, so nothing is pulled from here: the disk and memory read here are not its own. Pull the models there, or set OLLAMA_PULL_MISSING=1 with OLLAMA_IGNORE_BUDGET=1 to pull from here unchecked." >&2
  fi
  exit "$_oep_status"
)
