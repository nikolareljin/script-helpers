#!/usr/bin/env bash
# SCRIPT: ollama_test.sh
# DESCRIPTION: Tests for lib/ollama.sh -- captured-stdout results and ollama_update_env.
# USAGE: ./tests/ollama_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ollama_test.sh
# ----------------------------------------------------
#
# ollama_prepare_models_index and ollama_runtime_type are called as
# `x="$(fn ...)"`: anything else they print on stdout becomes part of the
# result. ollama_update_env rewrites a .env that load_env later sources.
# Nothing here touches the network; the models "repository" is a local git
# repository in a temporary directory.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[ollama_test] $*"; }
error() { echo "[ollama_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[ollama_test]   ok  $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging os file json env python ollama

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

note "ollama_update_env"
f="$tmp/app.env"
printf 'SECRET_TOKEN=s3cr3t\nmodel=llama3\n' >"$f"; chmod 600 "$f"
ollama_update_env "$f" model qwen2
if grep -q '^model=qwen2$' "$f" && grep -q '^SECRET_TOKEN=s3cr3t$' "$f"; then ok "replaces the line, keeps the rest"; else error "replace wrong: $(cat "$f")"; fi
if [[ "$(file_mode "$f")" == "600" ]]; then ok "a 0600 file stays 0600"; else error "mode became $(file_mode "$f")"; fi
ollama_update_env "$f" size 8b
if [[ "$(tail -n 1 "$f")" == "size=8b" ]]; then ok "appends an absent key"; else error "append wrong: $(cat "$f")"; fi
ollama_update_env "$f" CAMERA_DEVICE 'x'
ollama_update_env "$f" CAMERA_DEVICE 'C:\new\dev'
if [[ "$(grep '^CAMERA_DEVICE=' "$f")" == 'CAMERA_DEVICE=C:\new\dev' ]]; then ok "backslashes are written literally"; else error "backslashes mangled: $(grep -A1 CAMERA_DEVICE "$f" | od -c | head -3)"; fi
ollama_update_env "$f" website 'http://h/x?a=b'
ollama_update_env "$f" website 'http://h/y?c=d'
if [[ "$(grep -c '^website=' "$f")" == "1" && "$(grep '^website=' "$f")" == 'website=http://h/y?c=d' ]]; then ok "a value with = replaces cleanly"; else error "= in value: $(grep website "$f")"; fi
before="$(cat "$f")"
rc=0; ollama_update_env "$f" model $'llama3\ntouch PWNED' >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" && "$(cat "$f")" == "$before" ]]; then ok "a newline in the value is refused, file unchanged"; else error "newline value: rc=$rc $(cat "$f")"; fi
rc=0; ollama_update_env "$f" model $'x\ry' >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" ]]; then ok "a carriage return is refused"; else error "CR value rc=$rc"; fi
printf 'aXb=1\n' >"$tmp/k.env"
ollama_update_env "$tmp/k.env" a.b 2
if grep -q '^aXb=1$' "$tmp/k.env" && grep -q '^a\.b=2$' "$tmp/k.env"; then ok "the key is matched literally"; else error "regex key: $(cat "$tmp/k.env")"; fi
if ls "$tmp"/app.env.* >/dev/null 2>&1; then error "temporary files left behind"; else ok "no temporary files left"; fi

note "ollama_runtime_type"
printf 'ollama_runtime=Dockr\n' >"$tmp/rt.env"
rt="$(ollama_runtime_type "$tmp/rt.env" 2>/dev/null)"
if [[ "$rt" == "local" ]]; then ok "an invalid runtime captures as exactly 'local'"; else error "captured runtime: $(printf '%q' "$rt")"; fi
printf 'ollama_runtime=DOCKER\n' >"$tmp/rt.env"
if [[ "$(ollama_runtime_type "$tmp/rt.env")" == "docker" ]]; then ok "a valid runtime is lower-cased"; else error "valid runtime wrong"; fi

note "ollama_prepare_models_index"
if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  note "SKIP: needs jq and git"
else
  src="$tmp/src"
  mkdir -p "$src/code"
  echo '[{"name":"llama3","sizes":["8b"]},{"name":"gemma","sizes":["2b"]}]' >"$src/code/ollama_models.json"
  git -C "$src" init -q
  git -C "$src" add -A
  git -C "$src" -c user.name=t -c user.email=t@example.org commit -q -m init
  rc=0; json_file="$(cd "$tmp" && ollama_prepare_models_index clone "$src" 2>/dev/null)" || rc=$?
  if [[ "$rc" == "0" && "$json_file" == "clone/code/ollama_models.json" ]]; then ok "stdout is exactly the path"; else error "captured rc=$rc $(printf '%q' "$json_file")"; fi
  if [[ "$(cd "$tmp" && ollama_list_models "$json_file" | head -n 1)" == "gemma" ]]; then ok "the index is sorted by name and usable"; else error "list after prepare: $(cd "$tmp" && ollama_list_models "$json_file" 2>&1)"; fi
  # Second run: an existing clone is pulled; git's chatter must not reach stdout.
  rc=0; json_file="$(cd "$tmp" && ollama_prepare_models_index clone "$src" 2>/dev/null)" || rc=$?
  if [[ "$rc" == "0" && "$json_file" == "clone/code/ollama_models.json" ]]; then ok "an update run also prints only the path"; else error "update run captured rc=$rc $(printf '%q' "$json_file")"; fi

  echo '{"models":[{"name":"b"},{"name":"a"}]}' >"$tmp/clone/code/ollama_models.json"
  rc=0; json_file="$(cd "$tmp" && ollama_prepare_models_index clone "$src" 2>/dev/null)" || rc=$?
  if [[ "$rc" == "0" && "$(jq -r '.models[0].name' "$tmp/clone/code/ollama_models.json")" == "a" ]]; then ok "the {models:[...]} shape is sorted, not an error"; else error "object shape rc=$rc: $(cat "$tmp/clone/code/ollama_models.json")"; fi

  # A corrupt index with no generator: the sort fails, and so must the call.
  printf '{not json' >"$tmp/clone/code/ollama_models.json"
  rc=0; json_file="$(cd "$tmp" && ollama_prepare_models_index clone "$src" 2>/dev/null)" || rc=$?
  if [[ "$rc" != "0" && -z "$json_file" ]]; then ok "a failed sort fails the call"; else error "corrupt index rc=$rc $(printf '%q' "$json_file")"; fi
  if [[ ! -e "$tmp/clone/code/ollama_models.json.tmp" ]]; then ok "no .tmp left after a failed sort"; else error ".tmp left behind"; fi
fi

if [[ $failures -eq 0 ]]; then
  note "all ollama tests passed"
  exit 0
fi
note "$failures failure(s)"
exit 1
