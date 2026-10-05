#!/usr/bin/env bash
# SCRIPT: ollama_endpoint_test.sh
# DESCRIPTION: Tests for lib/ollama_endpoint.sh -- the models file, what an Ollama has, and the disk and memory budget before a pull.
# USAGE: ./tests/ollama_endpoint_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ollama_endpoint_test.sh
# ----------------------------------------------------
#
# The Ollama and the registry are one small Python HTTP server on 127.0.0.1:
# /api/tags lists what a file says is installed, /api/pull records what it was
# asked for (and "installs" it), /v2/.../manifests/<tag> answers with layer
# sizes. Disk and memory are given through the OLLAMA_BUDGET_* overrides, so
# nothing here depends on the machine it runs on, and nothing is downloaded.
#
# The behaviours worth pinning are the ones that look right while being
# wrong: a pull that starts before the budget is known, a partial pull, a
# model "present" because a longer name contains it, a port read as a tag,
# and a web server that answers 200 taken for an Ollama.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[ollama_endpoint_test] $*"; }
error() { echo "[ollama_endpoint_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[ollama_endpoint_test]   ok  $*"; }
check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else error "$1: expected [$2], got [$3]"; fi
}
# said <description> <file> <text>...: every text is in the file.
said() {
  local what="$1" file="$2" text
  shift 2
  for text in "$@"; do
    if ! grep -qF -- "$text" "$file"; then
      error "$what: [$text] not in: $(cat "$file")"
      return 0
    fi
  done
  ok "$what"
}

tmp="$(mktemp -d)"
server_pid=""
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging ollama_endpoint

# 10^9 bytes, as the module counts a GB.
GB=1000000000

# --- a fake Ollama and registry ---------------------------------------------------
cat >"$tmp/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = sys.argv[2]
# Layer sizes in bytes, then (when more than one) the config's size.
SIZES = {
    "library/main:7b": [4000000000, 700000000, 1000],
    "library/small:3b": [1900000000],
    "library/embed:latest": [274000000],
    "library/huge:70b": [40000000000],
    "team/tool:1b": [500000000],
    "library/broken:1b": [100000000],
}

def read(name, default=""):
    path = os.path.join(STATE, name)
    return open(path).read() if os.path.exists(path) else default

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/tags":
            if read("mode").strip() == "web":
                return self.send(200, "<html>hello</html>", "text/html")
            names = [n for n in read("installed").splitlines() if n]
            # "details" carries a "name" of its own that is not a model.
            models = [{"name": n, "model": n, "size": 1, "details": {"family": "x"}} for n in names]
            return self.send(200, json.dumps({"models": models}))
        if self.path.startswith("/v2/") and "/manifests/" in self.path:
            with open(os.path.join(STATE, "asked"), "a") as log:
                log.write(self.path + "\n")
            name, tag = self.path[len("/v2/"):].split("/manifests/")
            sizes = SIZES.get(name + ":" + tag)
            if sizes is None:
                return self.send(404, '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}')
            layers = sizes[:-1] if len(sizes) > 1 else sizes
            manifest = {"schemaVersion": 2, "layers": [{"mediaType": "x", "size": s} for s in layers]}
            if len(sizes) > 1:
                manifest["config"] = {"mediaType": "c", "size": sizes[-1]}
            # Indented, as a registry may answer: "size": 123 with a space.
            return self.send(200, json.dumps(manifest, indent=1))
        self.send(404, "{}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/pull":
            name = body.get("name", "")
            with open(os.path.join(STATE, "pulled"), "a") as log:
                log.write(name + "\n")
            if name.startswith("broken"):
                return self.send(200, json.dumps({"error": "pull model manifest: file does not exist"}))
            with open(os.path.join(STATE, "installed"), "a") as log:
                log.write(name + "\n")
            return self.send(200, json.dumps({"status": "success"}))
        self.send(404, "{}")

server = HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as port:
    port.write(str(server.server_address[1]))
server.serve_forever()
PY
mkdir -p "$tmp/state"
python3 "$tmp/server.py" "$tmp/port" "$tmp/state" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
[[ -s "$tmp/port" ]] || { error "the fake server did not start"; exit 1; }
URL="http://127.0.0.1:$(cat "$tmp/port")"
export OLLAMA_REGISTRY_URL="$URL"

reset() { # reset [installed model...]
  rm -f "$tmp/state/installed" "$tmp/state/pulled" "$tmp/state/asked" "$tmp/state/mode"
  : >"$tmp/state/installed"
  local m
  for m in "$@"; do echo "$m" >>"$tmp/state/installed"; done
}
one_line() { tr '\n' ' ' | sed 's/ $//'; }
pulled() { if [[ -f "$tmp/state/pulled" ]]; then one_line <"$tmp/state/pulled"; fi; }
# A machine with room for everything, unless a test says otherwise.
roomy() {
  export OLLAMA_BUDGET_DISK_FREE_BYTES=$((200 * GB)) OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((32 * GB))
  export OLLAMA_BUDGET_MEM_AVAILABLE_BYTES=$((20 * GB)) OLLAMA_BUDGET_GPU_BYTES=0
  unset OLLAMA_IGNORE_BUDGET OLLAMA_PULL_MISSING OLLAMA_DISK_RESERVE_GB OLLAMA_MEM_HEADROOM_PERCENT
}
roomy

# --- the models file --------------------------------------------------------------
note "the models file"
printf '# by purpose\n\nOLLAMA_MODEL=main:7b\n  CLASSIFY_MODEL = small:3b  \r\nOLLAMA_MODEL_LARGE=huge:70b\nOLLAMA_MODEL_LARGE_VRAM_GB=48\nOLLAMA_EMBED_MODEL=embed\nOLLAMA_MODEL_OLD=x\nOLLAMA_MODEL=main:7b\nnot a line\n' >"$tmp/models.env"
check "a value is read" "main:7b" "$(ollama_models_file_get "$tmp/models.env" OLLAMA_MODEL)"
check "spaces and a carriage return are not part of it" "small:3b" "$(ollama_models_file_get "$tmp/models.env" CLASSIFY_MODEL)"
check "a name is not matched by a longer one" "x" "$(ollama_models_file_get "$tmp/models.env" OLLAMA_MODEL_OLD)"
check "a name the file lacks is nothing" "" "$(ollama_models_file_get "$tmp/models.env" NO_SUCH)"
check "a missing file is nothing, not an error" "0:" "$(ollama_models_file_get "$tmp/absent.env" X; echo "$?:")"
check "names, each once, in order" "OLLAMA_MODEL CLASSIFY_MODEL OLLAMA_MODEL_LARGE OLLAMA_MODEL_LARGE_VRAM_GB OLLAMA_EMBED_MODEL OLLAMA_MODEL_OLD" "$(ollama_models_file_names "$tmp/models.env" | one_line)"
printf 'OLLAMA_MODEL=first:1b\nOLLAMA_MODEL=second:1b\n' >"$tmp/twice.env"
check "the last line for a name wins" "second:1b" "$(ollama_models_file_get "$tmp/twice.env" OLLAMA_MODEL)"

note "tags"
check "no tag gets :latest" "embed:latest" "$(ollama_model_tagged embed)"
check "a tag is kept" "main:7b" "$(ollama_model_tagged main:7b)"
check "a registry port is not a tag" "registry.example:5000/team/model:latest" "$(ollama_model_tagged registry.example:5000/team/model)"
check "a port and a tag" "registry.example:5000/team/model:q4" "$(ollama_model_tagged registry.example:5000/team/model:q4)"
check "nothing in, nothing out" "" "$(ollama_model_tagged "")"

note "what a start needs"
unset OLLAMA_MODEL CLASSIFY_MODEL OLLAMA_EMBED_MODEL OLLAMA_MODEL_OLD
check "the named ones, tagged" "main:7b small:3b embed:latest" "$(ollama_models_required "$tmp/models.env" OLLAMA_MODEL CLASSIFY_MODEL OLLAMA_EMBED_MODEL | one_line)"
check "with no names: all but the large tier" "main:7b small:3b embed:latest x:latest" "$(ollama_models_required "$tmp/models.env" | one_line)"
check "the environment wins, trimmed" "mine:1b small:3b" "$(OLLAMA_MODEL='  mine:1b ' ollama_models_required "$tmp/models.env" OLLAMA_MODEL CLASSIFY_MODEL | one_line)"
check "a blank variable is not a model" "main:7b" "$(OLLAMA_MODEL='   ' ollama_models_required "$tmp/models.env" OLLAMA_MODEL)"
check "two names for one model list it once" "main:7b" "$(CLASSIFY_MODEL=main:7b ollama_models_required "$tmp/models.env" OLLAMA_MODEL CLASSIFY_MODEL | one_line)"
check "a name nothing sets is skipped" "main:7b" "$(ollama_models_required "$tmp/models.env" NO_SUCH OLLAMA_MODEL | one_line)"
check "a missing file with nothing in the environment needs nothing" "" "$(ollama_models_required "$tmp/absent.env" OLLAMA_MODEL)"

# --- what an endpoint has ---------------------------------------------------------
note "what an Ollama has"
reset main:7b embed:latest
check "its models, as it names them" "main:7b embed:latest" "$(ollama_endpoint_models "$URL" | one_line)"
check "a trailing slash is tolerated" "main:7b embed:latest" "$(ollama_endpoint_models "$URL/" | one_line)"
reset
check "an Ollama with no models answers, with nothing" "0:" "$(ollama_endpoint_models "$URL"; echo "$?:")"
echo web >"$tmp/state/mode"
check "a web server that answers 200 is not an Ollama" "1" "$(ollama_endpoint_models "$URL" >/dev/null; echo $?)"
check "nothing listening is not an Ollama" "1" "$(ollama_endpoint_models "http://127.0.0.1:1" 1 >/dev/null; echo $?)"

note "what is missing"
check "the ones not there" "small:3b" "$(ollama_models_missing "$(printf 'main:7b\nsmall:3b\nembed:latest')" "$(printf 'main:7b\nembed:latest\nother:1b')")"
check "a longer name does not count" "main:7b" "$(ollama_models_missing "main:7b" "$(printf 'main:7b-instruct\nxmain:7b\nmain:7bb')")"
check "a dot is a dot" "qwen2.5:7b" "$(ollama_models_missing "qwen2.5:7b" "qwen2x5:7b")"
check "nothing needed, nothing missing" "" "$(ollama_models_missing "" "main:7b")"

# --- sizes ------------------------------------------------------------------------
note "how big a model is"
reset
check "every layer and the config, summed" "4700001000" "$(ollama_registry_size_bytes main:7b)"
check "a model with no tag is asked for as latest" "274000000" "$(ollama_registry_size_bytes embed)"
check "that request went to library/ with the tag" "/v2/library/embed/manifests/latest" "$(tail -n 1 "$tmp/state/asked")"
check "a namespaced model keeps its namespace" "500000000" "$(ollama_registry_size_bytes team/tool:1b)"
check "a model the registry lacks" "1" "$(ollama_registry_size_bytes nosuch:1b >/dev/null; echo $?)"
check "a model on another registry host is not asked for" "2" "$(ollama_registry_size_bytes hf.co/org/model:Q4 >/dev/null; echo $?)"
check "a registry that does not answer" "1" "$(OLLAMA_REGISTRY_URL=http://127.0.0.1:1 OLLAMA_REGISTRY_TIMEOUT=1 ollama_registry_size_bytes main:7b >/dev/null; echo $?)"

note "what the machine has"
check "the disk override is used as given" "123" "$(OLLAMA_BUDGET_DISK_FREE_BYTES=123 ollama_disk_free_bytes /)"
real_free="$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; ollama_disk_free_bytes "$tmp/not/there/yet")"
if [[ "$real_free" =~ ^[0-9]+$ && "$real_free" -gt 0 ]]; then ok "free space is read for a path that does not exist yet"; else error "free space for a missing path: [$real_free]"; fi
real_total="$(unset OLLAMA_BUDGET_MEM_TOTAL_BYTES; ollama_mem_total_bytes)"
if [[ "$real_total" =~ ^[0-9]+$ && "$real_total" -gt $((256 * 1048576)) ]]; then ok "this machine's memory is read ($((real_total / GB)) GB)"; else error "memory total: [$real_total]"; fi
real_available="$(unset OLLAMA_BUDGET_MEM_AVAILABLE_BYTES; ollama_mem_available_bytes)"
if [[ -z "$real_available" ]] || [[ "$real_available" =~ ^[0-9]+$ && "$real_available" -le "$real_total" ]]; then ok "available memory is a number no larger than the total, or unknown"; else error "available memory: [$real_available] of [$real_total]"; fi
mkdir -p "$tmp/empty-path"
check "no GPU tool means no GPU memory" "0" "$(unset OLLAMA_BUDGET_GPU_BYTES; PATH="$tmp/empty-path" ollama_gpu_mem_bytes)"
printf '#!/bin/sh\necho 8192\necho 24576\n' >"$tmp/empty-path/nvidia-smi"; chmod +x "$tmp/empty-path/nvidia-smi"
check "the largest GPU is the one that counts" "$((24576 * 1048576))" "$(unset OLLAMA_BUDGET_GPU_BYTES; PATH="$tmp/empty-path:$PATH" ollama_gpu_mem_bytes)"

# --- the budget -------------------------------------------------------------------
note "the budget"
budget() { ollama_budget_check "$@" 2>"$tmp/err"; echo $?; }
roomy
check "it fits" "0" "$(budget $((5 * GB)) $((5 * GB)) /models)"
check "and says nothing" "" "$(cat "$tmp/err")"
export OLLAMA_BUDGET_DISK_FREE_BYTES=$((14 * GB))
check "a download that leaves less than the reserve" "1" "$(budget $((5 * GB)) $((1 * GB)) /models)"
said "the refusal gives the download, what is free, where, and the setting" "$tmp/err" "5.0 GB" "14.0 GB" "/models" "OLLAMA_DISK_RESERVE_GB"
check "exactly at the reserve is enough" "0" "$(budget $((4 * GB)) $((1 * GB)) /models)"
check "one byte under is not" "1" "$(budget $((4 * GB + 1)) $((1 * GB)) /models)"
check "a smaller reserve lets it through" "0" "$(OLLAMA_DISK_RESERVE_GB=2 budget $((5 * GB)) $((1 * GB)) /models)"
check "nothing to download is not a disk question" "0" "$(OLLAMA_BUDGET_DISK_FREE_BYTES=0 budget 0 $((1 * GB)) /models)"
roomy
export OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GB))
check "a model larger than the machine" "2" "$(budget 0 $((40 * GB)) /models)"
said "the refusal gives what it needs (with headroom) and what there is" "$tmp/err" "48.0 GB" "8.0 GB"
check "headroom counts: 7 GB plus 20 percent does not fit 8 GB" "2" "$(budget 0 $((7 * GB)) /models)"
check "and fits without headroom" "0" "$(OLLAMA_MEM_HEADROOM_PERCENT=0 budget 0 $((7 * GB)) /models)"
check "a GPU that can hold it is enough" "0" "$(OLLAMA_BUDGET_GPU_BYTES=$((48 * GB)) budget 0 $((30 * GB)) /models)"
roomy
export OLLAMA_BUDGET_MEM_AVAILABLE_BYTES=$((2 * GB))
check "fits the machine but not what is free now: a warning, not a refusal" "0" "$(budget 0 $((5 * GB)) /models)"
said "and it says so" "$tmp/err" "available right now"
roomy
export OLLAMA_BUDGET_DISK_FREE_BYTES=$((1 * GB)) OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((4 * GB))
check "neither fits" "3" "$(budget $((5 * GB)) $((40 * GB)) /models)"
check "OLLAMA_IGNORE_BUDGET=1 lets it through" "0" "$(OLLAMA_IGNORE_BUDGET=1 budget $((5 * GB)) $((40 * GB)) /models)"
check "and still says both" "2" "$(grep -c "Not enough" "$tmp/err")"
roomy
check "garbage for a size is zero, not a crash" "0" "$(budget abc '' /models)"

# --- ensure -----------------------------------------------------------------------
note "making sure an Ollama has its models"
ensure() { ollama_endpoint_ensure_models "$URL" /models "$@" >"$tmp/out" 2>"$tmp/err"; echo $?; }
roomy; reset main:7b small:3b embed:latest
check "everything is there: nothing to do" "0" "$(ensure main:7b small:3b embed)"
check "and nothing was pulled or even sized" ":" "$(pulled):$(cat "$tmp/state/asked" 2>/dev/null)"
reset main:7b
check "two are missing and fit" "0" "$(ensure main:7b small:3b embed)"
check "exactly those were pulled, in order" "small:3b embed:latest" "$(pulled)"
reset main:7b
export OLLAMA_BUDGET_DISK_FREE_BYTES=$((11 * GB))
check "the download does not fit the disk" "1" "$(ensure main:7b small:3b embed)"
check "so nothing was pulled, not even the one that would fit alone" "" "$(pulled)"
said "it says nothing was pulled and what is missing" "$tmp/err" "Nothing was pulled" "small:3b"
roomy; reset
export OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GB))
check "the largest needed model does not fit memory" "2" "$(ensure small:3b huge:70b)"
check "nothing pulled then either" "" "$(pulled)"
reset huge:70b
check "the largest counts even when it is already there" "2" "$(ensure small:3b huge:70b)"
roomy; reset
check "pulling is off" "5" "$(OLLAMA_PULL_MISSING=0 ensure small:3b)"
check "and nothing was pulled" "" "$(pulled)"
check "a model whose size cannot be learned stops the pull" "7" "$(ensure small:3b hf.co/org/model:Q4)"
check "nothing pulled" "" "$(pulled)"
said "it names the way through" "$tmp/err" "OLLAMA_IGNORE_BUDGET"
check "unless the budget is ignored" "0" "$(OLLAMA_IGNORE_BUDGET=1 ensure small:3b hf.co/org/model:Q4)"
check "then both are pulled" "small:3b hf.co/org/model:Q4" "$(pulled)"
reset hf.co/org/model:Q4
check "a size unknown for a model that is already there does not matter" "0" "$(ensure small:3b hf.co/org/model:Q4)"
check "only the missing one was pulled" "small:3b" "$(pulled)"
reset
check "a pull that fails is a failure" "6" "$(ensure small:3b broken:1b embed)"
check "and stops there" "small:3b broken:1b" "$(pulled)"
reset; echo web >"$tmp/state/mode"
check "what answers is not an Ollama" "4" "$(ensure small:3b)"
check "nothing asked of it" "" "$(pulled)"
reset
check "no models asked for is success" "0" "$(ensure)"

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
