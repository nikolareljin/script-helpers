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

if ! command -v python3 >/dev/null 2>&1; then
  note "SKIP: python3 is needed for the fake Ollama and registry"
  exit 0
fi

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
    "library/main:7b-instruct": [5000000000],
    "library/small:3b": [1900000000],
    "library/embed:latest": [274000000],
    "library/huge:70b": [40000000000],
    "library/twenty:20b": [20000000000],
    "team/tool:1b": [500000000],
    "library/broken:1b": [100000000],
    "library/http500:1b": [100000000],
    "library/nested:1b": [100000000],
}

def read(name, default=""):
    path = os.path.join(STATE, name)
    return open(path).read() if os.path.exists(path) else default

def note(name, line):
    with open(os.path.join(STATE, name), "a") as log:
        log.write(line + "\n")

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
        mode = read("mode").strip()
        if self.requestline.split()[1].startswith("//"):
            # Python's server collapses //api/tags and would quietly serve it.
            # A real one may not, so the request as sent is what is judged.
            return self.send(404, "{}")
        if self.path == "/api/tags":
            if mode == "web":
                return self.send(200, "<html>hello</html>", "text/html")
            names = [n for n in read("installed").splitlines() if n]
            if mode == "old":
                # An Ollama that lists "name" alone, and a nested "name" that is not a model.
                models = [{"name": n, "size": 1, "details": {"family": "x", "name": "not-a-model"}} for n in names]
            else:
                # As Ollama answers: "name" then "model"; "details" has a "name" of its own.
                models = [{"name": n, "model": n, "size": 1, "details": {"name": "not-a-model", "family": "x"}} for n in names]
            if mode == "big":
                models += [{"name": "filler-%d:latest" % i, "model": "filler-%d:latest" % i, "size": 1,
                            "details": {"family": "x" * 150}} for i in range(1500)]
            indent = 2 if mode in ("pretty", "big") else None
            return self.send(200, json.dumps({"models": models}, indent=indent))
        if self.path.startswith("/v2/") and "/manifests/" in self.path:
            note("asked", self.path)
            name, tag = self.path[len("/v2/"):].split("/manifests/")
            key = name + ":" + tag
            if key == "library/index:1b":
                # A list of manifests, not a manifest: it has sizes and no layers.
                return self.send(200, json.dumps({"schemaVersion": 2, "manifests": [{"size": 1234}, {"size": 1250}]}))
            if key == "library/page:1b":
                return self.send(200, '<html>"size": 12</html>', "text/html")
            if key == "library/float:1b":
                return self.send(200, '{"layers":[{"size":4.7e9},{"size":100}]}')
            sizes = SIZES.get(key)
            if sizes is None:
                # A refusal whose body would add up if it were read.
                return self.send(404, '{"errors":[{"code":"MANIFEST_UNKNOWN"}],"layers":[{"size":999}]}')
            layers = sizes[:-1] if len(sizes) > 1 else sizes
            manifest = {"schemaVersion": 2, "layers": [{"mediaType": "x", "size": s} for s in layers]}
            if len(sizes) > 1:
                manifest["config"] = {"mediaType": "c", "size": sizes[-1]}
            # Indented, as a registry may answer: "size": 123 with a space.
            return self.send(200, json.dumps(manifest, indent=1))
        self.send(404, "{}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) or b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            note("pulled", "INVALID JSON " + repr(raw))
            return self.send(400, '{"error":"invalid json"}')
        if self.path == "/api/pull":
            name = body.get("name", "")
            note("pulled", name)
            note("stream", str(body.get("stream")))
            if set(body) - {"name", "stream"}:
                note("pulled", "EXTRA KEYS " + ",".join(sorted(body)))
            if name.startswith("http500"):
                return self.send(500, '{"error":"no space left on device"}')
            progress = '{"status":"pulling manifest"}\n{"status":"pulling abc","total":10,"completed":5}\n'
            if name.startswith("escape"):
                return self.send(200, progress + '{"error":"bad \\u001b[2J\\u001b[31mred"}\n\x1b[2Jtail\x07\n', "application/x-ndjson")
            if name.startswith("midfail"):
                # An error part way, and a stream that still ends in success.
                return self.send(200, progress + '{"error":"digest mismatch"}\n{"status":"success"}\n', "application/x-ndjson")
            if name.startswith("broken"):
                return self.send(200, progress + '{"error":"pull model manifest: file does not exist"}\n', "application/x-ndjson")
            if name.startswith("nested"):
                return self.send(200, progress + '{"status":"pulling","detail":{"status":"success"}}\n', "application/x-ndjson")
            note("installed", name)
            return self.send(200, progress + '{"status":"success"}\n', "application/x-ndjson")
        self.send(404, "{}")

class Server(HTTPServer):
    def server_bind(self):
        # HTTPServer looks up this machine's own name here (socket.getfqdn),
        # which on a macOS CI runner took longer than the test waits. The
        # name is never used, so bind and say where.
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[0], self.server_address[1]

server = Server(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as port:
    port.write(str(server.server_address[1]))
server.serve_forever()
PY
mkdir -p "$tmp/state"
python3 "$tmp/server.py" "$tmp/port" "$tmp/state" &
server_pid=$!
# Up to 30 seconds: a cold python on a loaded runner. Answering, not only
# having written its port, is what "started" means.
for _ in $(seq 1 150); do
  if [[ -s "$tmp/port" ]] && curl -fsS --max-time 1 "http://127.0.0.1:$(cat "$tmp/port")/api/tags" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
[[ -s "$tmp/port" ]] || { error "the fake server did not start"; exit 1; }
URL="http://127.0.0.1:$(cat "$tmp/port")"
curl -fsS --max-time 2 "$URL/api/tags" >/dev/null 2>&1 || { error "the fake server does not answer at $URL"; exit 1; }
export OLLAMA_REGISTRY_URL="$URL"

reset() { # reset [installed model...]
  rm -f "$tmp/state/installed" "$tmp/state/pulled" "$tmp/state/asked" "$tmp/state/mode" "$tmp/state/stream"
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

cat >"$tmp/env.env" <<'ENV'
export CHAT_MODEL=chat:1b
QUOTED="quoted:1b"
SINGLE='single:1b'  # why
NOTED=noted:1b # the embedder
lower_model=low:1b
X_LARGE_MODEL=kept:1b
Y_LARGE=dropped:9b
Y_LARGE_VRAM_GB=12
Y_SMALL=dropped:1b
Y_XLARGE=dropped:20b
Y_XLARGE_VRAM_GB=16
AI_TIER_SMALL_RAM_GB=12
AI_TIER_LARGE_RAM_GB=32
SMALLEST=tiny:1b
VERYSMALL=wee:1b
HASH=odd#name:1b
ENV
check "export before a name is read" "chat:1b" "$(ollama_models_file_get "$tmp/env.env" CHAT_MODEL)"
check "double quotes are not part of the value" "quoted:1b" "$(ollama_models_file_get "$tmp/env.env" QUOTED)"
check "single quotes neither, with a comment after" "single:1b" "$(ollama_models_file_get "$tmp/env.env" SINGLE)"
check "a trailing comment is not part of the value" "noted:1b" "$(ollama_models_file_get "$tmp/env.env" NOTED)"
check "a hash with no space before it is part of the value" "odd#name:1b" "$(ollama_models_file_get "$tmp/env.env" HASH)"
check "every assigned name is listed, whatever its case" "CHAT_MODEL QUOTED SINGLE NOTED lower_model X_LARGE_MODEL Y_LARGE Y_LARGE_VRAM_GB Y_SMALL Y_XLARGE Y_XLARGE_VRAM_GB AI_TIER_SMALL_RAM_GB AI_TIER_LARGE_RAM_GB SMALLEST VERYSMALL HASH" "$(ollama_models_file_names "$tmp/env.env" | one_line)"
check "a name that is not a variable name is refused" "2:" "$(ollama_models_file_get "$tmp/env.env" 'CHAT.MODEL'; echo "$?:")"
check "so a dot cannot stand for any character" "2:" "$(printf 'OLLAMAXMODEL=wrong:1b\n' >"$tmp/dot.env"; ollama_models_file_get "$tmp/dot.env" 'OLLAMA.MODEL'; echo "$?:")"
( cd "$tmp" && ollama_models_file_get "$tmp/env.env" "X/w $tmp/written/s/x" >/dev/null 2>&1; true )
check "and a name cannot carry a sed command" "no" "$([[ -e "$tmp/written" ]] && echo yes || echo no)"

note "tags"
check "no tag gets :latest" "embed:latest" "$(ollama_model_tagged embed)"
check "a tag is kept" "main:7b" "$(ollama_model_tagged main:7b)"
check "a registry port is not a tag" "registry.example:5000/team/model:latest" "$(ollama_model_tagged registry.example:5000/team/model)"
check "a port and a tag" "registry.example:5000/team/model:q4" "$(ollama_model_tagged registry.example:5000/team/model:q4)"
check "nothing in, nothing out" "" "$(ollama_model_tagged "")"
check "the default namespace is left out, as Ollama lists it" "main:7b" "$(ollama_model_tagged library/main:7b)"
check "and the default registry's host" "main:7b" "$(ollama_model_tagged registry.ollama.ai/library/main:7b)"

note "what a start needs"
unset OLLAMA_MODEL CLASSIFY_MODEL OLLAMA_EMBED_MODEL OLLAMA_MODEL_OLD
check "the named ones, tagged" "main:7b small:3b embed:latest" "$(ollama_models_required "$tmp/models.env" OLLAMA_MODEL CLASSIFY_MODEL OLLAMA_EMBED_MODEL | one_line)"
check "with no names: all but the large tier" "main:7b small:3b embed:latest x:latest" "$(ollama_models_required "$tmp/models.env" | one_line)"
check "the environment wins, trimmed" "mine:1b small:3b" "$(OLLAMA_MODEL='  mine:1b ' ollama_models_required "$tmp/models.env" OLLAMA_MODEL CLASSIFY_MODEL | one_line)"
check "a blank variable is not a model" "main:7b" "$(OLLAMA_MODEL='   ' ollama_models_required "$tmp/models.env" OLLAMA_MODEL)"
check "two names for one model list it once" "main:7b" "$(CLASSIFY_MODEL=main:7b ollama_models_required "$tmp/models.env" OLLAMA_MODEL CLASSIFY_MODEL | one_line)"
check "a name nothing sets is skipped" "main:7b" "$(ollama_models_required "$tmp/models.env" NO_SUCH OLLAMA_MODEL | one_line)"
check "a missing file with nothing in the environment needs nothing" "" "$(ollama_models_required "$tmp/absent.env" OLLAMA_MODEL)"
check "a tier's alternative is a name's ending (_SMALL, _LARGE, _XLARGE and their floors), not any name with the word in it" "chat:1b quoted:1b single:1b noted:1b low:1b kept:1b tiny:1b wee:1b odd#name:1b" "$(ollama_models_required "$tmp/env.env" | one_line)"
check "a bad name refuses the whole list, not the rest of it" "2:" "$(ollama_models_required "$tmp/models.env" OLLAMA_MODEL MY-MODEL CLASSIFY_MODEL 2>/dev/null; echo "$?:")"
# The name is meant literally: it must reach the function unexpanded.
# shellcheck disable=SC2016
( cd "$tmp" && ollama_models_required "$tmp/models.env" 'x[$(touch ran)]' >/dev/null 2>&1; true )
check "and a name cannot run a command" "no" "$([[ -e "$tmp/ran" ]] && echo yes || echo no)"
check "no arguments at all is nothing, not a crash" "0:" "$(ollama_models_required; echo "$?:")"

# --- what an endpoint has ---------------------------------------------------------
note "what an Ollama has"
reset main:7b embed:latest
check "its models, as it names them" "main:7b embed:latest" "$(ollama_endpoint_models "$URL" | one_line)"
check "a trailing slash is tolerated" "main:7b embed:latest" "$(ollama_endpoint_models "$URL/" | one_line)"
check "(the fake does not serve a doubled slash, so that was the module)" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$URL//api/tags")"
reset
check "an Ollama with no models answers, with nothing" "0:" "$(ollama_endpoint_models "$URL"; echo "$?:")"
echo web >"$tmp/state/mode"
check "a web server that answers 200 is not an Ollama" "1" "$(ollama_endpoint_models "$URL" >/dev/null; echo $?)"
check "nothing listening is not an Ollama" "1" "$(ollama_endpoint_models "http://127.0.0.1:1" 1 >/dev/null; echo $?)"

reset main:7b embed:latest
check "a nested name is not a model" "main:7b embed:latest" "$(ollama_endpoint_models "$URL" | one_line)"
echo pretty >"$tmp/state/mode"
check "an answer spread over lines is read the same" "main:7b embed:latest" "$(ollama_endpoint_models "$URL" | one_line)"
echo old >"$tmp/state/mode"
check "an Ollama that lists name alone is read too" "main:7b embed:latest" "$(ollama_endpoint_models "$URL" | one_line)"
check "no URL is not an Ollama, and not a crash" "1" "$(ollama_endpoint_models >/dev/null 2>&1; echo $?)"

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
rm -f "$tmp/state/asked"
check "a model on another registry host is not asked for" "2" "$(ollama_registry_size_bytes hf.co/org/model:Q4 >/dev/null; echo $?)"
check "a host with a port neither" "2" "$(ollama_registry_size_bytes localhost:5000/a:1b >/dev/null; echo $?)"
check "(nothing was requested for either)" "" "$(cat "$tmp/state/asked" 2>/dev/null)"
check "the default registry's own host is the default registry" "4700001000" "$(ollama_registry_size_bytes registry.ollama.ai/library/main:7b)"
check "a 404 is not read, whatever its body adds up to" "1:" "$(ollama_registry_size_bytes nosuch:1b; echo "$?:")"
check "a list of manifests is not a model's manifest" "1:" "$(ollama_registry_size_bytes index:1b; echo "$?:")"
check "a web page that says size is not one either" "1:" "$(ollama_registry_size_bytes page:1b; echo "$?:")"
check "a size that is not a whole number is not counted" "100" "$(ollama_registry_size_bytes float:1b)"
check "what is not a model reference is not asked for" "1" "$(ollama_registry_size_bytes 'a/b?x=1#:t' >/dev/null 2>&1; echo $?)"
check "nor a path that climbs" "1" "$(ollama_registry_size_bytes '../../api/tags' >/dev/null 2>&1; echo $?)"
rm -f "$tmp/state/asked"
check "nor one that climbs from the middle" "1" "$(ollama_registry_size_bytes 'team/../main:7b' >/dev/null 2>&1; echo $?)"
check "nor one with an empty segment" "1" "$(ollama_registry_size_bytes 'team//main:7b' >/dev/null 2>&1; echo $?)"
check "a host and a model, two segments, is still another registry" "2" "$(ollama_registry_size_bytes 'hf.co/model:Q4' >/dev/null 2>&1; echo $?)"
check "as is localhost" "2" "$(ollama_registry_size_bytes 'localhost/model:Q4' >/dev/null 2>&1; echo $?)"
check "(none of the four was requested)" "" "$(cat "$tmp/state/asked" 2>/dev/null)"
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
printf '#!/bin/sh\necho 24576\necho 8192\n' >"$tmp/empty-path/nvidia-smi"; chmod +x "$tmp/empty-path/nvidia-smi"
check "GPUs count together: Ollama spreads a model over them" "$(((24576 + 8192) * 1048576))" "$(unset OLLAMA_BUDGET_GPU_BYTES; PATH="$tmp/empty-path:$PATH" ollama_gpu_mem_bytes)"
printf '#!/bin/sh\necho "NVIDIA-SMI has failed because it could not communicate with the NVIDIA driver." >&2\nexit 9\n' >"$tmp/empty-path/nvidia-smi"
check "a driver that cannot be reached is no GPU" "0" "$(unset OLLAMA_BUDGET_GPU_BYTES; PATH="$tmp/empty-path:$PATH" ollama_gpu_mem_bytes)"
rm -f "$tmp/empty-path/nvidia-smi"
# df as it prints a filesystem whose name has a space: the columns move.
mkdir -p "$tmp/fake-df"
fake_df() { printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "%s"\n' "$1" >"$tmp/fake-df/df"; chmod +x "$tmp/fake-df/df"; }
df_free() { ( unset OLLAMA_BUDGET_DISK_FREE_BYTES; PATH="$tmp/fake-df:$PATH" ollama_disk_free_bytes / ); }
fake_df "/dev/disk1s1 1000000 900000 100000 90% /"
check "df, plainly" "$((100000 * 1024))" "$(df_free)"
fake_df "//user@nas/Model Store 1000000 900000 100000 90% /Volumes/Model Store"
check "df, a filesystem name with a space: available, not used" "$((100000 * 1024))" "$(df_free)"
fake_df "map auto_home 500 400 100 80% /System/Volumes/Data/home"
check "df, macOS auto_home" "$((100 * 1024))" "$(df_free)"
printf '#!/bin/sh\nexit 1\n' >"$tmp/fake-df/df"
check "df failing is nothing, and success" "0:" "$(df_free; echo "$?:")"
check "a stated figure with a leading zero is decimal" "8" "$(OLLAMA_BUDGET_DISK_FREE_BYTES=08 ollama_disk_free_bytes /)"

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
check "memory and GPU hold it together: 16 and 12 take a 20 GB model" "0" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((16 * GB)) OLLAMA_BUDGET_GPU_BYTES=$((12 * GB)) budget 0 $((20 * GB)) /models)"
check "and not a 24 GB one (28.8 with headroom, against 28)" "2" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((16 * GB)) OLLAMA_BUDGET_GPU_BYTES=$((12 * GB)) budget 0 $((24 * GB)) /models)"
check "exactly the machine's memory fits" "0" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((12 * GB)) budget 0 $((10 * GB)) /models)"
check "one step over does not" "2" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((12 * GB - 1)) budget 0 $((10 * GB)) /models)"
check "memory unknown, GPU large enough: it fits" "0" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=0 OLLAMA_BUDGET_GPU_BYTES=$((48 * GB)) budget 0 $((30 * GB)) /models)"
check "and nothing is said" "" "$(cat "$tmp/err")"
check "memory unknown, GPU too small: said and skipped" "0" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=0 OLLAMA_BUDGET_GPU_BYTES=$((8 * GB)) budget 0 $((30 * GB)) /models)"
said "it says the memory could not be read" "$tmp/err" "could not be read"
roomy
export OLLAMA_BUDGET_MEM_AVAILABLE_BYTES=$((2 * GB))
check "fits the machine but not what is free now: a warning, not a refusal" "0" "$(budget 0 $((5 * GB)) /models)"
said "and it says so" "$tmp/err" "available right now"
check "what the GPU holds is not asked of the memory that is free" "" "$(OLLAMA_BUDGET_GPU_BYTES=$((4 * GB)) ollama_budget_check 0 $((5 * GB)) /models 2>&1)"
roomy
export OLLAMA_BUDGET_DISK_FREE_BYTES=$((1 * GB)) OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((4 * GB))
check "neither fits" "3" "$(budget $((5 * GB)) $((40 * GB)) /models)"
check "OLLAMA_IGNORE_BUDGET=1 lets it through" "0" "$(OLLAMA_IGNORE_BUDGET=1 budget $((5 * GB)) $((40 * GB)) /models)"
check "and still says both" "2" "$(grep -c "Not enough" "$tmp/err")"
check "as warnings, not as errors" "2:0" "$(grep -c 'Warning' "$tmp/err"):$(grep -c 'Error' "$tmp/err")"
roomy
check "garbage for a size is zero, not a crash" "0" "$(budget abc '' /models)"
esc_dir="$(printf '/mo\033[2Jdels')"
check "a path with a control character still gets its refusal" "1" "$(OLLAMA_BUDGET_DISK_FREE_BYTES=$((1 * GB)) budget $((5 * GB)) 0 "$esc_dir")"
check "and is shown without it" "0:1" "$(grep -c "$(printf '\033')\[2J" "$tmp/err"):$(grep -c 'at /mo\[2Jdels' "$tmp/err")"
export OLLAMA_BUDGET_DISK_FREE_BYTES=$((14 * GB))
check "a reserve written 08 is eight, not an error" "0" "$(OLLAMA_DISK_RESERVE_GB=08 budget $((5 * GB)) 0 /models)"
check "(and said nothing about octal)" "" "$(cat "$tmp/err")"
check "a reserve written 010 is ten, not eight" "1" "$(OLLAMA_DISK_RESERVE_GB=010 budget $((5 * GB)) 0 /models)"
check "a headroom written 08 is eight percent" "0" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((11 * GB)) OLLAMA_MEM_HEADROOM_PERCENT=08 budget 0 $((10 * GB)) /models)"
check "a figure too long to count is not a figure" "1" "$(OLLAMA_BUDGET_DISK_FREE_BYTES=99999999999999999999 PATH="$tmp/fake-df:$PATH" budget $((5 * GB)) 0 /models >/dev/null; grep -c "could not be read" "$tmp/err")"
check "a headroom beyond any machine is the default" "0" "$(OLLAMA_MEM_HEADROOM_PERCENT=999999999999 budget 0 $((5 * GB)) /models)"
roomy
fake_df "/dev/disk1s1 1000000 900000 100000 90% /"

note "a caller that runs strict"
strict() { # strict <script>: run it in a new bash with -euo pipefail, the module loaded
  PATH="$tmp/fake-df:$tmp/empty-path:$PATH" bash -euo pipefail -c "source ./helpers.sh; shlib_import logging ollama_endpoint; $1" 2>"$tmp/err"
}
printf '#!/bin/sh\nexit 1\n' >"$tmp/fake-df/df"
printf '#!/bin/sh\nexit 9\n' >"$tmp/empty-path/nvidia-smi"; chmod +x "$tmp/empty-path/nvidia-smi"
check "a failing df and a failing nvidia-smi are said and skipped, not fatal" "rc=0 after" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES OLLAMA_BUDGET_GPU_BYTES; strict 'ollama_budget_check 5000000000 1000000000 /m; echo "rc=$? after"')"
said "the skipped disk check is said" "$tmp/err" "could not be read"
# Single quotes on purpose: the inner shell expands these.
# shellcheck disable=SC2016
check "asking for the GPU alone, with a driver that fails, does not end a strict caller" "g=0 after" "$(unset OLLAMA_BUDGET_GPU_BYTES; strict 'g="$(ollama_gpu_mem_bytes)"; echo "g=$g after"')"
# shellcheck disable=SC2016
check "nor does asking for free disk with a df that fails" "f= after" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; strict 'f="$(ollama_disk_free_bytes /)"; echo "f=$f after"')"
rm -f "$tmp/empty-path/nvidia-smi"
fake_df "/dev/disk1s1 1000000 900000 100000 90% /"
# Single quotes on purpose: the inner shell expands these.
# shellcheck disable=SC2016
check "no arguments do not end a strict caller" "models=1 get=2 ensure=0 after" "$(strict 'a=0; ollama_endpoint_models || a=$?; b=0; ollama_models_file_get || b=$?; ollama_models_file_names; ollama_model_tagged; c=0; ollama_endpoint_ensure_models || c=$?; ollama_models_missing; echo "models=$a get=$b ensure=$c after"')"
check "a refused name returns its code to a strict caller" "2 after" "$(strict "r=0; ollama_models_file_get '$tmp/env.env' 'A/B' || r=\$?; echo \"\$r after\"")"
reset main:7b; echo big >"$tmp/state/mode"
check "a long answer spread over lines is still an Ollama's, under pipefail" "1501" "$(strict "ollama_endpoint_models '$URL' | wc -l | tr -d ' '")"
check "and a model in a long list is found" "" "$(strict "ollama_models_missing 'filler-0:latest' \"\$(ollama_endpoint_models '$URL')\"")"
rm -f "$tmp/state/mode"

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

note "one pull"
reset
check "a pull that ends in success" "0" "$(ollama_endpoint_pull "$URL" small:3b 2>"$tmp/err"; echo $?)"
check "is asked for as a stream, so progress keeps the line alive" "True" "$(tail -n 1 "$tmp/state/stream")"
check "a slash and a tag survive" "hf.co/org/model:Q4" "$(ollama_endpoint_pull "$URL" hf.co/org/model:Q4 2>/dev/null; tail -n 1 "$tmp/state/pulled")"
check "an error in the stream is a failure, whatever the status" "1" "$(ollama_endpoint_pull "$URL" broken:1b 2>"$tmp/err"; echo $?)"
said "and what Ollama said is passed on" "$tmp/err" "file does not exist"
check "HTTP 500 is a failure" "1" "$(ollama_endpoint_pull "$URL" http500:1b 2>"$tmp/err"; echo $?)"
said "with its reason" "$tmp/err" "no space left on device"
check "success inside another object is not success" "1" "$(ollama_endpoint_pull "$URL" nested:1b 2>/dev/null; echo $?)"
check "an error part way is a failure even when the stream ends in success" "1" "$(ollama_endpoint_pull "$URL" midfail:1b 2>/dev/null; echo $?)"
ollama_endpoint_pull "http://user:s3cret@${URL#http://}" broken:1b >"$tmp/out" 2>"$tmp/err"
if grep -q "s3cret" "$tmp/out" "$tmp/err"; then error "a refused pull printed the password: $(cat "$tmp/err")"; else ok "a refused pull does not print the password"; fi
said "and still names the host" "$tmp/err" "${URL#http://}"
# curl does not print credentials today. One that named the whole URL in its
# error must not get them into a message either.
mkdir -p "$tmp/loud-curl"
# The stand-in's own "$@" and $last, not this script's.
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor a in "$@"; do last="$a"; done\necho "curl: (6) Could not resolve host in $last" >&2\nexit 6\n' >"$tmp/loud-curl/curl"; chmod +x "$tmp/loud-curl/curl"
PATH="$tmp/loud-curl:$PATH" ollama_endpoint_pull "http://user:s3cret@nowhere.example:11434" small:3b >"$tmp/out" 2>"$tmp/err"
if grep -q "s3cret" "$tmp/out" "$tmp/err"; then error "an error text that names the URL printed the password: $(cat "$tmp/err")"; else ok "an error text that names the URL does not print the password"; fi
said "and the rest of that text is kept" "$tmp/err" "Could not resolve host in http://nowhere.example:11434/api/pull"
ollama_endpoint_pull "$URL" escape:1b >"$tmp/out" 2>"$tmp/err"
check "an escape sequence in what Ollama said does not reach the terminal" "0" "$(grep -c "$(printf '\033')\[2J" "$tmp/err")"
reset
check "what is not a model reference is not sent" "1:" "$(ollama_endpoint_pull "$URL" 'x", "insecure": true, "y": "z' 2>/dev/null; echo "$?:$(pulled)")"
check "nor a name with a quote" "1:" "$(ollama_endpoint_pull "$URL" 'a"b' 2>/dev/null; echo "$?:$(pulled)")"
check "nor a name that climbs" "1:" "$(ollama_endpoint_pull "$URL" 'team/../main:7b' 2>/dev/null; echo "$?:$(pulled)")"
check "nothing listening is a failure" "1" "$(ollama_endpoint_pull "http://127.0.0.1:1" small:3b 2>/dev/null; echo $?)"

note "the corners of making sure"
roomy; reset
check "a model given twice, and under two spellings" "0" "$(ensure small:3b small:3b library/small:3b)"
check "is pulled once" "small:3b" "$(pulled)"
reset main:7b
export OLLAMA_BUDGET_DISK_FREE_BYTES=$((16 * GB))
check "a longer name missing does not make the shorter one missing: 5 GB to pull, not 9.7" "0" "$(ensure main:7b main:7b-instruct)"
check "and only it is pulled" "main:7b-instruct" "$(pulled)"
roomy; reset
check "an argument that is not a model reference stops everything" "8" "$(ensure small:3b 'bad name')"
check "before anything is asked" ":" "$(pulled):$(cat "$tmp/state/asked" 2>/dev/null)"
reset hf.co/org/giant:Q8
check "a present model of unknown size does not stop the rest" "0" "$(ensure small:3b hf.co/org/giant:Q8)"
said "but it is said that memory was not checked for it" "$tmp/err" "hf.co/org/giant:Q8" "memory was not checked"
reset
printf '#!/bin/sh\nexit 1\n' >"$tmp/fake-df/df"
check "free disk unknown is the same lack as size unknown: nothing is pulled" "7:" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; PATH="$tmp/fake-df:$PATH" ollama_endpoint_ensure_models "$URL" /models small:3b >/dev/null 2>"$tmp/err"; echo "$?:$(pulled)")"
said "and it names both ways through" "$tmp/err" "OLLAMA_BUDGET_DISK_FREE_BYTES" "OLLAMA_IGNORE_BUDGET"
( unset OLLAMA_BUDGET_DISK_FREE_BYTES; PATH="$tmp/fake-df:$PATH" ollama_endpoint_ensure_models "$URL" "$esc_dir" small:3b >/dev/null 2>"$tmp/err"; true )
check "that refusal shows the path without a control character too" "0:1" "$(grep -c "$(printf '\033')\[2J" "$tmp/err"):$(grep -c 'at /mo\[2Jdels' "$tmp/err")"
( unset OLLAMA_BUDGET_DISK_FREE_BYTES; PATH="$tmp/fake-df:$PATH" ollama_budget_check 5000000000 0 "$esc_dir" >/dev/null 2>"$tmp/err"; true )
check "as does the note that the disk could not be read" "0:1" "$(grep -c "$(printf '\033')\[2J" "$tmp/err"):$(grep -c 'at /mo\[2Jdels' "$tmp/err")"
check "unless the budget is ignored" "0:small:3b" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; PATH="$tmp/fake-df:$PATH" OLLAMA_IGNORE_BUDGET=1 ollama_endpoint_ensure_models "$URL" /models small:3b >/dev/null 2>&1; echo "$?:$(pulled)")"
fake_df "/dev/disk1s1 1000000 900000 100000 90% /"
roomy; reset
ollama_endpoint_ensure_models "$URL" /models small:3b >"$tmp/out" 2>"$tmp/err"
check "every message goes to stderr; stdout is the caller's" "" "$(cat "$tmp/out")"
said "the pull is announced there" "$tmp/err" "Pulling small:3b"
reset
check "a pull that fails says why" "6" "$(ensure http500:1b)"
said "in the words Ollama used" "$tmp/err" "no space left on device"

note "what is said about an endpoint"
check "a URL is shown without its user and password" "http://host.example:11434/x" "$(_ollama_ep_shown "http://user:s3cret@host.example:11434/x")"
check "a URL without them is shown as it is" "$URL" "$(_ollama_ep_shown "$URL")"
check "an at sign in the path is not a password" "http://host.example/a@b" "$(_ollama_ep_shown "http://host.example/a@b")"
check "a password with an at sign in it goes whole, as curl reads it" "http://host.example:11434" "$(_ollama_ep_shown "http://user:p@ss@w0rd@host.example:11434")"
check "a query is left out: a token travels there" "http://host.example:11434/v1" "$(_ollama_ep_shown "http://host.example:11434/v1?key=s3cret&x=1#frag")"
check "and with it an at sign that was never a password" "http://host.example" "$(_ollama_ep_shown "http://host.example?a=b@c")"
check "credentials without a scheme go too" "host.example:11434" "$(_ollama_ep_shown "user:s3cret@host.example:11434")"
check "a control character in a URL is not shown" "http://host.example/x" "$(_ollama_ep_shown "$(printf 'http://host.example/\033x')")"
bad_model="$(printf 'bad\033[2Jname')"
bad_rc=0
ollama_endpoint_ensure_models "$URL" /models "$bad_model" >"$tmp/out" 2>"$tmp/err" || bad_rc=$?
check "a refused argument is refused" "8" "$bad_rc"
check "and is not printed back with its escape sequence" "0" "$(grep -c "$(printf '\033')\[2J" "$tmp/err")"
said "but is still named" "$tmp/err" "Not a model reference: bad[2Jname"
reset
cred_rc=0
ollama_endpoint_ensure_models "$URL" /models "user:s3cret@registry.example/model:1b" >"$tmp/out" 2>"$tmp/err" || cred_rc=$?
check "a model reference that carries credentials is refused" "8:" "$cred_rc:$(pulled)"
if grep -q "s3cret" "$tmp/out" "$tmp/err"; then error "the refusal printed the password: $(cat "$tmp/err")"; else ok "and the refusal does not print them"; fi
said "while naming the rest" "$tmp/err" "registry.example/model:1b"
check "nor is it pulled on its own" "1:" "$(ollama_endpoint_pull "$URL" "user:s3cret@registry.example/model:1b" 2>"$tmp/err"; echo "$?:$(pulled)")"
check "(that refusal is clean too)" "0" "$(grep -c s3cret "$tmp/err")"
check "a digest after the name is still a model reference" "0" "$(_ollama_ep_is_model "team/model@sha256:abc123"; echo $?)"
check "and so is one with no namespace" "0" "$(_ollama_ep_is_model "model@sha256:abc123"; echo $?)"
ollama_endpoint_pull "$URL" "$bad_model" >"$tmp/out" 2>"$tmp/err"
check "nor by a single pull" "0" "$(grep -c "$(printf '\033')\[2J" "$tmp/err")"
ollama_models_required "$tmp/models.env" "$(printf 'A\033[2JB')" >"$tmp/out" 2>"$tmp/err"
check "nor a refused name" "0" "$(grep -c "$(printf '\033')\[2J" "$tmp/err")"
ollama_endpoint_ensure_models "$URL/?key=s3cret" /models small:3b >"$tmp/out" 2>"$tmp/err"
if grep -q "s3cret" "$tmp/out" "$tmp/err"; then error "a token in the query reached a message: $(cat "$tmp/err")"; else ok "a token in the query does not reach a message"; fi
check "what the other end said is shown as one printable line" "last [31mline" "$(_ollama_ep_said "$(printf 'first\nlast \033[31mline\a\r\n')")"
long_said="$(_ollama_ep_said "$(printf 'x%.0s' $(seq 1 500))")"
check "and cut short" "300" "${#long_said}"
ollama_endpoint_pull "http://user:s3cret@127.0.0.1:1" small:3b >"$tmp/out" 2>"$tmp/err"
if grep -q "s3cret" "$tmp/out" "$tmp/err"; then error "a failed connection printed the password: $(cat "$tmp/err")"; else ok "a failed connection does not print the password"; fi
SECRET_URL="http://user:s3cret@${URL#http://}"
reset
ollama_endpoint_ensure_models "$SECRET_URL" /models small:3b >"$tmp/out" 2>"$tmp/err"
check "the pull went through with the credentials in the URL" "small:3b" "$(pulled)"
reset
OLLAMA_PULL_MISSING=0 ollama_endpoint_ensure_models "$SECRET_URL" /models small:3b >>"$tmp/out" 2>>"$tmp/err"
echo web >"$tmp/state/mode"
ollama_endpoint_ensure_models "$SECRET_URL" /models small:3b >>"$tmp/out" 2>>"$tmp/err"
if grep -q "s3cret" "$tmp/out" "$tmp/err"; then error "a password reached a message: $(cat "$tmp/out" "$tmp/err")"; else ok "no message carries the password (pulling, refusing, unreachable)"; fi
said "and each still names the host" "$tmp/err" "${URL#http://}"

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
