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
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

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
# The file is sourced by load_env. A value that would run something there, be
# split in two, or leave a quote open is refused, and the file stays as it was.
before="$(cat "$f")"
# Each character on its own as well: a value with two of them says nothing
# about the second.
for bad in "y;touch $tmp/PWNED" "7b \$(touch $tmp/PWNED)" "x\`touch $tmp/PWNED\`" "a|b" "a&b" "a>$tmp/PWNED" "a<b" "a(b)" 'two words' "tab$(printf '\t')here" "it's" 'say "x"' '$HOME' \
           'a;b' 'a`b' 'a(b' 'a)b' 'a"b' "a'b" 'a$b' 'a b' 'C:\models\' '\'; do
  rc=0; ollama_update_env "$f" model "$bad" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "1" && "$(cat "$f")" == "$before" ]]; then ok "refused, file unchanged: $(printf '%q' "$bad")"; else error "written or changed (rc=$rc) for $(printf '%q' "$bad"): $(cat "$f")"; fi
done
( load_env "$f" ) >/dev/null 2>&1
if [[ -e "$tmp/PWNED" ]]; then error "a refused value ran when the file was loaded"; else ok "loading the file afterwards runs nothing"; fi
# A backslash at the end of a value joins the next line to it when the file is
# loaded, and a comment line after it then runs.
printf 'model=old\n# touch %s\nsize=7b\n' "$tmp/RAN" >"$tmp/join.env"
rc=0; ollama_update_env "$tmp/join.env" model 'C:\models\' >/dev/null 2>&1 || rc=$?
( load_env "$tmp/join.env" ) >/dev/null 2>&1
if [[ "$rc" == "1" && ! -e "$tmp/RAN" && "$(head -n 1 "$tmp/join.env")" == "model=old" ]]; then ok "a value that ends in a backslash is refused, and the comment after it does not run"; else error "trailing backslash: rc=$rc ran=$([[ -e "$tmp/RAN" ]] && echo yes || echo no) $(head -n 1 "$tmp/join.env")"; fi
for bad_key in 'model;touch' '1abc' 'a-b' '-x' 'a b' '.a' 'a=b'; do
  rc=0; ollama_update_env "$f" "$bad_key" x >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "1" && "$(cat "$f")" == "$before" ]]; then ok "a key that is not a name is refused: $bad_key"; else error "bad key $bad_key rc=$rc: $(cat "$f")"; fi
done
# Every refusal says why on stderr. stdout stays empty: a function that is
# captured (ollama_runtime_sync_env_url) calls this one.
out="$(ollama_update_env "$f" model 'two words' 2>/dev/null; ollama_update_env "$f" 'a-b' x 2>/dev/null; ollama_update_env "$f" '' x 2>/dev/null; ollama_update_env "$f" model $'a\nb' 2>/dev/null)"
said="$(ollama_update_env "$f" model 'two words' 2>&1 >/dev/null; ollama_update_env "$f" 'a-b' x 2>&1 >/dev/null; ollama_update_env "$f" '' x 2>&1 >/dev/null; ollama_update_env "$f" model $'a\nb' 2>&1 >/dev/null)"
if [[ -z "$out" && "$(printf '%s\n' "$said" | grep -c 'Error')" == "4" ]]; then ok "each of the four refusals says so on stderr, and nothing on stdout"; else error "refusals: stdout $(printf '%q' "$out"), stderr lines $(printf '%s\n' "$said" | grep -c 'Error')"; fi
ollama_update_env "$f" model 'hf.co/Org/Model-GGUF:Q4_K_M'
ollama_update_env "$f" ollama_url 'http://user@[::1]:11434/base%20x,y+z=1'
if grep -q '^model=hf.co/Org/Model-GGUF:Q4_K_M$' "$f" && grep -qF 'ollama_url=http://user@[::1]:11434/base%20x,y+z=1' "$f"; then ok "a model reference and a URL are written as given"; else error "plain values: $(cat "$f")"; fi
printf 'aXb=1\n' >"$tmp/k.env"
ollama_update_env "$tmp/k.env" a.b 2
if grep -q '^aXb=1$' "$tmp/k.env" && grep -q '^a\.b=2$' "$tmp/k.env"; then ok "the key is matched literally"; else error "regex key: $(cat "$tmp/k.env")"; fi
if ls "$tmp"/app.env.* >/dev/null 2>&1; then error "temporary files left behind"; else ok "no temporary files left"; fi
# A symlinked .env (dotfile-managed): mv replaced the link with a regular file,
# and the mode copied off the link itself (0777) went onto that file.
mkdir -p "$tmp/dots" "$tmp/proj"
printf 'SECRET_TOKEN=s3cr3t\nmodel=llama3\n' >"$tmp/dots/real.env"; chmod 600 "$tmp/dots/real.env"
ln -s "$tmp/dots/real.env" "$tmp/proj/.env"
ollama_update_env "$tmp/proj/.env" model qwen2
if [[ -L "$tmp/proj/.env" ]]; then ok "a symlinked .env is still a symlink"; else error "the symlink was replaced by a file with mode $(file_mode "$tmp/proj/.env")"; fi
if grep -q '^model=qwen2$' "$tmp/dots/real.env"; then ok "the update reached the link's target"; else error "target not updated: $(cat "$tmp/dots/real.env")"; fi
if [[ "$(file_mode "$tmp/dots/real.env")" == "600" ]]; then ok "the target of a symlinked 0600 .env stays 0600"; else error "target mode became $(file_mode "$tmp/dots/real.env")"; fi
if ls "$tmp"/proj/.env.* >/dev/null 2>&1; then error "temporary files left next to the link"; else ok "no temporary files left next to the link"; fi

note "ollama_runtime_sync_env_url"
# Called as url="$(ollama_runtime_sync_env_url file)". An address that
# ollama_update_env will not write is still the address: stdout is the URL and
# nothing else, the reason is on stderr, and the file is left as it was.
# The dollars are literal: the file is read, not sourced.
# shellcheck disable=SC2016
printf 'ollama_host=https://user:pa$$w0rd@ollama.example.com\n' >"$tmp/sync.env"
rc=0; url="$(unset ollama_host ollama_url ollama_port ollama_scheme; ollama_runtime_sync_env_url "$tmp/sync.env" 2>"$tmp/sync.err")" || rc=$?
# shellcheck disable=SC2016
if [[ "$rc" == "0" && "$url" == 'https://user:pa$$w0rd@ollama.example.com:11434' ]]; then ok "an address that cannot be saved is still returned, and only it"; else error "captured rc=$rc $(printf '%q' "$url")"; fi
if grep -q 'was not saved' "$tmp/sync.err" && ! grep -q '^ollama_url=' "$tmp/sync.env"; then ok "it says on stderr that the address was not saved, and the file has no ollama_url"; else error "stderr: $(cat "$tmp/sync.err") file: $(cat "$tmp/sync.env")"; fi
printf 'ollama_host=ollama.example.com\n' >"$tmp/sync.env"
url="$(unset ollama_host ollama_url ollama_port ollama_scheme; ollama_runtime_sync_env_url "$tmp/sync.env" 2>"$tmp/sync.err")"
if [[ "$url" == "$(grep '^ollama_url=' "$tmp/sync.env" | cut -d= -f2-)" && -n "$url" && ! -s "$tmp/sync.err" ]]; then ok "a plain address is returned and saved, with nothing on stderr"; else error "plain address: $(printf '%q' "$url") file: $(cat "$tmp/sync.env") stderr: $(cat "$tmp/sync.err")"; fi

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
