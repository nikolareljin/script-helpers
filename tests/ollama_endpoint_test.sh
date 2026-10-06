#!/usr/bin/env bash
# SCRIPT: ollama_endpoint_test.sh
# DESCRIPTION: Tests for lib/ollama_endpoint.sh -- the models file, what an Ollama has, and the disk and memory budget before a pull.
# USAGE: ./tests/ollama_endpoint_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ollama_endpoint_test.sh
# ----------------------------------------------------
#
# The Ollama and the registry are faked by one small Python HTTP server on
# 127.0.0.1:
#   /api/tags                  lists the models a state file says are installed
#   /api/pull                  records what was asked for, and "installs" it
#   /v2/.../manifests/<tag>    answers with layer sizes
# Disk and memory are set through the OLLAMA_BUDGET_* variables. So the result
# does not depend on this machine, and nothing is downloaded.
#
# The cases that matter most are the ones that look right and are wrong: a
# pull that starts before the room is checked, a pull of only some models, a
# model counted as present because a longer name contains it, a port read as
# a tag, and a web server that answers 200 taken for an Ollama.
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
# said <description> <file> <text>...: passes if every text is in the file.
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

# 1 GB is 10^9 bytes, as in the module.
GB=1000000000

# --- a fake Ollama and registry ---------------------------------------------------
cat >"$tmp/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = sys.argv[2]
# Layer sizes in bytes. If there is more than one number, the last is the
# config's size.
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
    "library/large:7b": [4700000000],
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
            # Python's server would treat //api/tags as /api/tags. A real server may
            # not, so the path is checked exactly as it was sent.
            return self.send(404, "{}")
        if self.path == "/api/tags":
            if mode == "web":
                return self.send(200, "<html>hello</html>", "text/html")
            names = [n for n in read("installed").splitlines() if n]
            if mode == "old":
                # An old Ollama: "name" only. Plus a nested "name" that is not a model.
                models = [{"name": n, "size": 1, "details": {"family": "x", "name": "not-a-model"}} for n in names]
            else:
                # A current Ollama: "name" then "model". "details" has its own "name".
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
                # A list of manifests, not a manifest: it has sizes but no layers.
                return self.send(200, json.dumps({"schemaVersion": 2, "manifests": [{"size": 1234}, {"size": 1250}]}))
            if key == "library/page:1b":
                return self.send(200, '<html>"size": 12</html>', "text/html")
            if key == "library/float:1b":
                return self.send(200, '{"layers":[{"size":4.7e9},{"size":100}]}')
            # The real registry answers for a name in any case (measured:
            # Qwen3:0.6B and qwen3:0.6b give the same manifest).
            if key == "library/notfound-page:1b":
                # Any web server's 404, not the registry's: nothing says the model is unknown.
                return self.send(404, '<html>Not Found "layers" "size": 999</html>', "text/html")
            if key == "library/noname:1b":
                # The other "unknown" the registry protocol has.
                return self.send(404, '{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}')
            if key == "library/down:1b":
                return self.send(503, '{"layers":[{"size":999}]}')
            sizes = SIZES.get(key.lower())
            if sizes is None:
                # What the real registry says for a model or a tag it does not have
                # (measured). The body has a "size" here: it must not be summed.
                return self.send(404, '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}],"layers":[{"size":999}]}')
            layers = sizes[:-1] if len(sizes) > 1 else sizes
            manifest = {"schemaVersion": 2, "layers": [{"mediaType": "x", "size": s} for s in layers]}
            if len(sizes) > 1:
                manifest["config"] = {"mediaType": "c", "size": sizes[-1]}
            # Indented, as a registry may answer: "size": 123, with a space.
            return self.send(200, json.dumps(manifest, indent=1))
        self.send(404, "{}")

    def do_POST(self):
        if "/echo-path/" in self.path:
            # A proxy's 404, with the request path in it, as Express writes it.
            return self.send(404, "<pre>Cannot POST %s</pre>" % self.path, "text/html")
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) or b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            note("pulled", "INVALID JSON " + repr(raw))
            return self.send(400, '{"error":"invalid json"}')
        if self.path == "/api/pull":
            # The model must come under both keys ("model" is the API's, "name" is
            # what an older Ollama reads), with the same value.
            name = body.get("model", "")
            note("pulled", name if name == body.get("name") else "KEYS DIFFER " + repr(raw))
            note("stream", str(body.get("stream")))
            if set(body) - {"model", "name", "stream"}:
                note("pulled", "EXTRA KEYS " + ",".join(sorted(body)))
            if name.startswith("http500"):
                return self.send(500, '{"error":"no space left on device"}')
            progress = '{"status":"pulling manifest"}\n{"status":"pulling abc","total":10,"completed":5}\n'
            if name.startswith("large"):
                # A large layer, streamed the way Ollama does it: no "completed" before
                # it starts, several lines within one 10% step, a small layer next to
                # it, a layer Ollama already has, and CRLF line ends with an empty last
                # line.
                big = '{"status":"pulling aa","digest":"sha256:aa","total":4700000000%s}\n'
                lines = [big % ""] + [big % (',"completed":%d' % c) for c in
                         (100, 480000000, 500000000, 900000000, 2400000000, 2500000000, 4700000000)]
                lines.insert(3, '{"status":"pulling bb","digest":"sha256:bb","total":1200,"completed":600}\n')
                lines.insert(5, '{"status":"pulling cc","digest":"sha256:cc","total":900000000,"completed":900000000}\r\n')
                note("installed", name)
                return self.send(200, '{"status":"pulling manifest"}\n' + "".join(lines) + '{"status":"success"}\r\n\r\n', "application/x-ndjson")
            if name.startswith("barely"):
                # A large layer seen once, at 5%, and then success.
                return self.send(200, '{"status":"pulling manifest"}\n{"status":"pulling ee","digest":"sha256:ee","total":2000000000,"completed":100000000}\n{"status":"success"}\n', "application/x-ndjson")
            if name.startswith("nofinal") or name.startswith("cutshort"):
                # As a real Ollama streams it: the last progress line is short of the
                # total, then it verifies and says success. "cutshort" never does.
                big = '{"status":"pulling dd","digest":"sha256:dd","total":2000000000,"completed":%d}\n'
                lines = "".join(big % c for c in (100, 700000000, 1900000000))
                end = '{"status":"verifying sha256 digest"}\n{"status":"success"}\n' if name.startswith("nofinal") else ""
                return self.send(200, '{"status":"pulling manifest"}\n' + lines + end, "application/x-ndjson")
            if name.startswith("spelled"):
                # The escape written out as text (\033...), as a careless server might.
                return self.send(200, progress + '{"error":"bad \\\\033[2J name"}\n', "application/x-ndjson")
            if name.startswith("escape"):
                return self.send(200, progress + '{"error":"bad \\u001b[2J\\u001b[31mred"}\n\x1b[2Jtail\x07\n', "application/x-ndjson")
            if name.startswith("midfail"):
                # An error in the middle, and a stream that still ends in success.
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
        # HTTPServer looks up this machine's host name here (socket.getfqdn). On
        # a macOS CI runner that took longer than the test waits. The name is not
        # used, so only bind and store the address.
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
# Wait up to 30 seconds: python can be slow to start on a busy runner.
# "Started" means it answers, not only that it wrote its port.
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
# A machine with room for everything. A test changes this when it needs to.
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
# A byte-order mark (some editors add one at the start of a file). With it,
# the first variable in the file was never found.
printf '\xef\xbb\xbfOLLAMA_MODEL=first:1b\r\nCLASSIFY_MODEL=second:1b\r\n' >"$tmp/bom.env"
check "a byte-order mark does not hide the first variable" "first:1b" "$(ollama_models_file_get "$tmp/bom.env" OLLAMA_MODEL)"
check "nor its name" "OLLAMA_MODEL CLASSIFY_MODEL" "$(ollama_models_file_names "$tmp/bom.env" | one_line)"
check "so every model in such a file is required" "first:1b second:1b" "$(unset OLLAMA_MODEL CLASSIFY_MODEL; ollama_models_required "$tmp/bom.env" | one_line)"
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
# A mistyped path must not mean "this project needs no models".
check "a file that is named and is not there is an error, with names" "1:" "$(ollama_models_required "$tmp/absent.env" OLLAMA_MODEL 2>"$tmp/err"; echo "$?:")"
said "and it says which file" "$tmp/err" "No models file" "absent.env"
check "and without names" "1:" "$(ollama_models_required "$tmp/absent.env" 2>/dev/null; echo "$?:")"
check "nor is the environment used in its place" "1:" "$(OLLAMA_MODEL=mine:1b ollama_models_required "$tmp/absent.env" OLLAMA_MODEL 2>/dev/null; echo "$?:")"
check "no file named: the environment alone" "0:mine:1b" "$(m="$(OLLAMA_MODEL=mine:1b ollama_models_required "" OLLAMA_MODEL)"; echo "$?:$m")"
check "no file named and nothing set needs nothing" "0:" "$(ollama_models_required "" OLLAMA_MODEL; echo "$?:")"
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
check "a model the registry says it does not have is 3, and prints no size" "3:" "$(ollama_registry_size_bytes nosuch:1b; echo "$?:")"
check "the registry's other word for it, NAME_UNKNOWN, is 3 as well" "3:" "$(ollama_registry_size_bytes noname:1b; echo "$?:")"
check "a 404 that is not the registry's is no answer, not an unknown model" "1:" "$(ollama_registry_size_bytes notfound-page:1b; echo "$?:")"
check "an error status with a manifest in its body is not a size" "1:" "$(ollama_registry_size_bytes down:1b; echo "$?:")"
rm -f "$tmp/state/asked"
check "a model on another registry host is not asked for" "2" "$(ollama_registry_size_bytes hf.co/org/model:Q4 >/dev/null; echo $?)"
check "a host with a port neither" "2" "$(ollama_registry_size_bytes localhost:5000/a:1b >/dev/null; echo $?)"
check "(nothing was requested for either)" "" "$(cat "$tmp/state/asked" 2>/dev/null)"
check "the default registry's own host is the default registry" "4700001000" "$(ollama_registry_size_bytes registry.ollama.ai/library/main:7b)"
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
# Where a local Ollama keeps its models. The Linux service runs as its own
# user: on a machine set up by the installer, $HOME/.ollama/models is not it.
mkdir -p "$tmp/service/models"
check "the models directory is OLLAMA_MODELS when that is set" "/srv/m" "$(OLLAMA_MODELS=/srv/m _OLLAMA_EP_SERVICE_MODELS="$tmp/service/models" ollama_models_dir)"
check "else the Linux service's, when there is one" "$tmp/service/models" "$(unset OLLAMA_MODELS; HOME="$tmp/home" _OLLAMA_EP_SERVICE_MODELS="$tmp/service/models" ollama_models_dir)"
check "else the user's own, which need not exist yet" "$tmp/home/.ollama/models" "$(unset OLLAMA_MODELS; HOME="$tmp/home" _OLLAMA_EP_SERVICE_MODELS="$tmp/no-service" ollama_models_dir)"
mkdir -p "$tmp/closed-service"
check "the service's home is enough when its models directory cannot be seen" "$tmp/closed-service/.ollama/models" "$(unset OLLAMA_MODELS; HOME="$tmp/home" _OLLAMA_EP_SERVICE_MODELS="$tmp/closed-service/.ollama/models" ollama_models_dir)"
check "an empty OLLAMA_MODELS is not a directory" "$tmp/service/models" "$(OLLAMA_MODELS="" _OLLAMA_EP_SERVICE_MODELS="$tmp/service/models" ollama_models_dir)"
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
# df output for a filesystem whose name has a space: the columns shift.
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
# The same setting in other spellings. Only the exact value 1 used to count.
check "so do true and YES" "0:0" "$(OLLAMA_IGNORE_BUDGET=true budget $((5 * GB)) $((40 * GB)) /models):$(OLLAMA_IGNORE_BUDGET=YES budget $((5 * GB)) $((40 * GB)) /models)"
check "0, no and a typo do not: the checks apply" "3:3:3" "$(OLLAMA_IGNORE_BUDGET=0 budget $((5 * GB)) $((40 * GB)) /models):$(OLLAMA_IGNORE_BUDGET=no budget $((5 * GB)) $((40 * GB)) /models):$(OLLAMA_IGNORE_BUDGET=ture budget $((5 * GB)) $((40 * GB)) /models)"
roomy
check "a size that is not a number is refused, not read as zero" "4" "$(budget abc 1000 /models)"
said "and it says what it was given" "$tmp/err" "abc" "whole number"
check "the same for the model's size" "4" "$(budget 1000 abc /models)"
check "and for one too long to count" "4" "$(budget 99999999999999999999 0 /models)"
check "and for a negative or a fraction" "4:4" "$(budget -5 0 /models):$(budget 1.5 0 /models)"
check "ignoring the budget does not make a non-number a number" "4" "$(OLLAMA_IGNORE_BUDGET=1 budget abc abc /models)"
check "nothing given is zero: nothing to check" "0" "$(budget '' '' /models)"
check "a size with a leading zero is decimal" "0" "$(budget 08 09 /models)"
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
check "the list of what is missing ends with its last model, not with a space" "1:0" "$(grep -c 'Missing: small:3b embed:latest' "$tmp/err"):$(grep -c 'embed:latest ' "$tmp/err")"
roomy; reset
export OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GB))
check "the largest needed model does not fit memory" "2" "$(ensure small:3b huge:70b)"
check "nothing pulled then either" "" "$(pulled)"
reset huge:70b
check "the largest counts even when it is already there" "2" "$(ensure small:3b huge:70b)"
roomy; reset
check "pulling is off" "5" "$(OLLAMA_PULL_MISSING=0 ensure small:3b embed)"
check "and nothing was pulled" "" "$(pulled)"
said "it lists what is missing as a sentence does" "$tmp/err" "lacks: small:3b embed:latest. Pulling is off"
# "Off" in the usual spellings. Only the exact value 0 used to count, so
# OLLAMA_PULL_MISSING=false went on to pull.
for spelling in false no OFF never; do
  check "OLLAMA_PULL_MISSING=$spelling is off too, and nothing is pulled" "5:" "$(OLLAMA_PULL_MISSING=$spelling ensure small:3b):$(pulled)"
done
for spelling in 1 true Yes; do
  reset
  check "OLLAMA_PULL_MISSING=$spelling is on" "0:small:3b" "$(OLLAMA_PULL_MISSING=$spelling ensure small:3b):$(pulled)"
done
# A typo is not "on": it is reported, and nothing is pulled.
reset
check "a value that is neither is read as off" "5:" "$(OLLAMA_PULL_MISSING=flase ensure small:3b):$(pulled)"
said "and it is reported" "$tmp/err" "OLLAMA_PULL_MISSING is neither on" "flase"
# Back to an Ollama with nothing installed, for the cases that follow.
roomy; reset
check "a model the registry does not have stops the pull" "7" "$(ensure small:3b nosuch:1b)"
check "nothing pulled, not even the one that exists" "" "$(pulled)"
said "it says the name is wrong, not that the size is unknown" "$tmp/err" "The registry has no model named nosuch:1b," "check the name"
check "and it does not send anyone to pull it by hand" "0" "$(grep -c -e 'by hand' -e 'OLLAMA_IGNORE_BUDGET' "$tmp/err")"
reset
check "ignoring the budget pulls a model the registry does not have too: Ollama may know better" "0:small:3b nosuch:1b" "$(OLLAMA_IGNORE_BUDGET=1 ensure small:3b nosuch:1b):$(pulled)"
reset
check "a registry that only fails to answer is still \"could not be learned\"" "7" "$(ensure small:3b down:1b)"
said "with the way through named" "$tmp/err" "could not be learned" "OLLAMA_IGNORE_BUDGET"
reset
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
# With no directory given, the only argument left is the URL: not a model.
check "a URL alone is no models, not a model named by the URL" "0::" "$(ollama_endpoint_ensure_models "$URL" 2>"$tmp/err"; echo "$?:$(pulled):$(cat "$tmp/err")")"
# Case does not matter to Ollama: "Main:7B" is its "main:7b".
reset main:7b
check "letter case does not make a model missing" "0::" "$(ensure Main:7B):$(pulled):$(cat "$tmp/state/asked" 2>/dev/null)"
check "nor in the list of what is missing" "small:3b" "$(ollama_models_missing "$(printf 'MAIN:7b\nsmall:3b\n')" "main:7b" | one_line)"
check "a longer name is still another model, in any case" "MAIN:7b" "$(ollama_models_missing "MAIN:7b" "main:7b-instruct" | one_line)"
# One model named twice in different case is one model. Counted twice, its
# size would be charged twice against the disk.
reset
check "one model in two cases is pulled once" "0:Small:3b" "$(ensure Small:3b small:3B):$(pulled)"
printf 'A_MODEL=Main:7b\nB_MODEL=main:7B\n' >"$tmp/case.env"
check "and listed once by the models file" "Main:7b" "$(ollama_models_required "$tmp/case.env" | one_line)"

note "one pull"
reset
check "a pull that ends in success" "0" "$(ollama_endpoint_pull "$URL" small:3b 2>"$tmp/err"; echo $?)"
check "is asked for as a stream, so progress keeps the line alive" "True" "$(tail -n 1 "$tmp/state/stream")"
check "under both of the API's keys, and nothing else" "small:3b" "$(pulled)"
check "a small download says nothing while it runs" "" "$(cat "$tmp/err")"
reset
check "a large one ends in success too" "0" "$(ollama_endpoint_pull "$URL" large:7b >"$tmp/out" 2>"$tmp/err"; echo $?)"
check "and says each tenth of a large layer once: not 0%, not a small layer, not one already held" \
  "  large:7b: 10% of 4.7 GB|  large:7b: 50% of 4.7 GB|  large:7b: 100% of 4.7 GB|" "$(tr '\n' '|' <"$tmp/err")"
check "on stderr: stdout stays empty" "" "$(cat "$tmp/out")"
# The caller's log must be appended to, not overwritten from the start.
# A real Ollama never says completed == total for a layer: the progress used
# to stop at 90% and the pull then simply ended.
check "a pull whose last progress line is short of the total" "0" "$(ollama_endpoint_pull "$URL" nofinal:7b >/dev/null 2>"$tmp/err"; echo $?)"
check "is still said to reach 100%, once" "  nofinal:7b: 30% of 2.0 GB|  nofinal:7b: 90% of 2.0 GB|  nofinal:7b: 100% of 2.0 GB|" "$(grep '% of' "$tmp/err" | tr '\n' '|')"
check "a pull that stops short of success is a failure" "1" "$(ollama_endpoint_pull "$URL" cutshort:7b >/dev/null 2>"$tmp/err"; echo $?)"
check "and is not said to reach 100%" "0" "$(grep -c '100% of' "$tmp/err")"
check "a layer that never reached 10% is still said to be done" "0:  barely:7b: 100% of 2.0 GB|" "$(ollama_endpoint_pull "$URL" barely:7b >/dev/null 2>"$tmp/err"; echo "$?:$(grep '% of' "$tmp/err" | tr '\n' '|')")"
echo "earlier line" >"$tmp/err"
ollama_endpoint_pull "$URL" large:7b >/dev/null 2>>"$tmp/err"
check "progress is added to a log the caller already wrote to" "earlier line|  large:7b: 10% of 4.7 GB|" "$(head -n 2 "$tmp/err" | tr '\n' '|')"
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
# curl does not print credentials today. If it ever names the whole URL in
# an error, they must still not reach a message.
mkdir -p "$tmp/loud-curl"
# "$@" and $last below belong to the stand-in, not to this script.
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor a in "$@"; do last="$a"; done\necho "curl: (6) Could not resolve host in $last" >&2\nexit 6\n' >"$tmp/loud-curl/curl"; chmod +x "$tmp/loud-curl/curl"
PATH="$tmp/loud-curl:$PATH" ollama_endpoint_pull "http://user:s3cret@nowhere.example:11434" small:3b >"$tmp/out" 2>"$tmp/err"
if grep -q "s3cret" "$tmp/out" "$tmp/err"; then error "an error text that names the URL printed the password: $(cat "$tmp/err")"; else ok "an error text that names the URL does not print the password"; fi
said "and the rest of that text is kept" "$tmp/err" "Could not resolve host in http://nowhere.example:11434/api/pull"
# A long error line. The text is cut to 300 characters. The cut used to come
# first, went through the middle of "user:secret@", and left half the
# password in the message.
# The stand-in prints another URL with credentials, then padding, then the
# URL it was given, so that the cut lands inside that last one.
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor a in "$@"; do last="$a"; done\nprintf "curl: (7) via http://other:pw2pw2@elsewhere.example/x %%0220d no route to %%s\\n" 0 "$last" >&2\nexit 7\n' >"$tmp/loud-curl/curl"
# No scheme here, so only replacing the whole URL removes its credentials.
PATH="$tmp/loud-curl:$PATH" ollama_endpoint_pull "user:s3cretpassword@nowhere.example:11434" small:3b >"$tmp/out" 2>"$tmp/err"
if grep -q -E "s3cret|user:" "$tmp/out" "$tmp/err"; then error "a long error text kept part of the password: $(cut -c240-420 "$tmp/err")"; else ok "a long error text keeps no part of the password"; fi
# Credentials in someone else's URL in the text are removed too.
if grep -q -E "pw2|other:" "$tmp/out" "$tmp/err"; then error "another URL in the text kept its password: $(cut -c1-120 "$tmp/err")"; else ok "nor the password of another URL in the text"; fi
said "and that URL's host is still named" "$tmp/err" "http://elsewhere.example/x"
ollama_endpoint_pull "$URL" spelled:1b >"$tmp/out" 2>"$tmp/err"
check "a spelled-out escape in what Ollama said does not become one" "0:1" "$(grep -c "$(printf '\033')\[2J" "$tmp/err"):$(grep -cF '\033[2J name' "$tmp/err")"
ollama_endpoint_pull "$URL" escape:1b >"$tmp/out" 2>"$tmp/err"
check "an escape sequence in what Ollama said does not reach the terminal" "0" "$(grep -c "$(printf '\033')\[2J" "$tmp/err")"
reset
check "what is not a model reference is not sent" "1:" "$(ollama_endpoint_pull "$URL" 'x", "insecure": true, "y": "z' 2>/dev/null; echo "$?:$(pulled)")"
check "nor a name with a quote" "1:" "$(ollama_endpoint_pull "$URL" 'a"b' 2>/dev/null; echo "$?:$(pulled)")"
check "nor a name that climbs" "1:" "$(ollama_endpoint_pull "$URL" 'team/../main:7b' 2>/dev/null; echo "$?:$(pulled)")"
# A reference with an empty part. Ollama calls these an invalid model name.
# They used to get as far as the registry and fail with a message about size.
for bad in 'main:' 'main/' 'a::b' 'team/:7b'; do
  check "a reference with an empty part is refused before anything is asked: $bad" "8::" "$(: >"$tmp/state/asked"; ollama_endpoint_ensure_models "$URL" /models "$bad" >/dev/null 2>&1; echo "$?:$(pulled):$(cat "$tmp/state/asked" 2>/dev/null)")"
done
check "a registry host with a port is still a model reference" "0" "$(_ollama_ep_is_model 'registry.example:5000/team/model:1b'; echo $?)"
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
# The logging helpers print with `echo -e`. The text \033 in a URL, a path
# or an answer would become a real escape character.
spelled='http://host.example/\033[2J\x1b[31m\e[0m'
check "a spelled-out escape in a URL has its backslashes doubled" 'http://host.example/\\033[2J\\x1b[31m\\e[0m' "$(_ollama_ep_shown "$spelled")"
ollama_endpoint_ensure_models "$spelled" /models small:3b >"$tmp/out" 2>"$tmp/err"
check "so the message carries no escape sequence" "0" "$(grep -c "$(printf '\033')\[2J" "$tmp/err")"
said "and names the address by its host: a path is not shown at all" "$tmp/err" 'No Ollama answers at http://host.example.'
# In a host, where it is shown, a spelled-out escape still has its backslashes doubled.
check "a spelled-out escape in what is shown of a URL has its backslashes doubled" 'http://host\\033[2J.example' "$(_ollama_ep_shown_url 'http://host\033[2J.example/path')"
check "the same for what the other end said" 'bad \\033[2J' "$(_ollama_ep_said 'bad \033[2J')"
check "what is shown of an address: scheme, host and port; no credentials, path, query or fragment, with or without a scheme" \
  "http://h:1|http://h:1|h:1|h|https://[::1]:5|" \
  "$(for a in 'http://u:p@h:1/x/y?q=1#f' 'http://h:1?q' 'h:1/path?q#f' 'h/path' 'https://u@[::1]:5/v1'; do _ollama_ep_shown_url "$a"; echo; done | tr '\n' '|')"
OLLAMA_BUDGET_DISK_FREE_BYTES=$((1 * GB)) ollama_budget_check $((5 * GB)) 0 '/mo\033[2Jdels' >"$tmp/out" 2>"$tmp/err"
check "and for a path" "0:1" "$(grep -c "$(printf '\033')\[2J" "$tmp/err"):$(grep -cF 'at /mo\033[2Jdels' "$tmp/err")"
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
# A digest (model@sha256:...) is refused too. Split at its last colon it
# pointed at the wrong repository and manifest, so it could not be sized.
# And it never equals a name Ollama lists, so every start would pull it.
reset
check "a reference by digest is refused, before anything is asked" "8::" "$(ollama_endpoint_ensure_models "$URL" /models "team/model@sha256:abc123" >/dev/null 2>&1; echo "$?:$(pulled):$(cat "$tmp/state/asked" 2>/dev/null)")"
check "its size is not asked for under a wrong name" "1:" "$(ollama_registry_size_bytes "team/model@sha256:abc123" 2>/dev/null; echo "$?:$(cat "$tmp/state/asked" 2>/dev/null)")"
check "nor is it pulled on its own" "1:" "$(ollama_endpoint_pull "$URL" "model@sha256:abc123" 2>/dev/null; echo "$?:$(pulled)")"
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

note "what counts as a name and a model, in any locale"
accented="$(printf 'mod\303\250le')"
check "a letter with an accent is not part of a model reference" "no no no" "$(for locale in C en_US.UTF-8 C.UTF-8; do (LC_ALL=$locale; if _ollama_ep_is_model "$accented" 2>/dev/null; then echo yes; else echo no; fi); done | tr '\n' ' ' | sed 's/ $//')"
check "nor of a variable name" "no no no" "$(for locale in C en_US.UTF-8 C.UTF-8; do (LC_ALL=$locale; if _ollama_ep_is_name "$(printf 'N\303\211M')" 2>/dev/null; then echo yes; else echo no; fi); done | tr '\n' ' ' | sed 's/ $//')"
# A NAME is read through ${!NAME}. A function's own variable of the same name
# used to be read in its place.
check "a model variable may be called name, value or file" "small:3b embed:latest main:7b" "$(name=small:3b value=embed file=main:7b; ollama_models_required "" name value file | one_line)"
check "and so may the names an env file is asked for" "from-file:a b:c" "$(printf 'name=from-file\nvalue=a b\nfile=c\n' >"$tmp/shadow.env"; unset name value file; ollama_env_file_export "$tmp/shadow.env" name value file; echo "${name-unset}:${value-unset}:${file-unset}")"

# --- a project's own configuration ---------------------------------------------
# Not inside a container, wherever this file runs (the bash 3.2 gate runs it
# in one): the cases that are about being in one say so.
export _OLLAMA_EP_DOCKERENV="$tmp/no-dockerenv"
note "the address a project configures"
base() { ollama_endpoint_base_url "$1"; echo ":$?"; }
check "a URL stays as it is" "http://localhost:11434 :0" "$(base http://localhost:11434 | one_line)"
check "a bare host gets http and Ollama's port" "http://localhost:11434 :0" "$(base localhost | one_line)"
check "host:port keeps its port" "http://127.0.0.1:11435 :0" "$(base 127.0.0.1:11435 | one_line)"
check "the API path a project stored with it is not part of the base" "http://ollama:11434 :0" "$(base http://ollama:11434/api/generate | one_line)"
check "nor /api alone, /v1, a query or a trailing slash" "http://h:1|http://h:1|http://h:1|http://h:1|" "$(for a in http://h:1/api http://h:1/v1/chat/completions 'http://h:1/api/tags?x=1#y' http://h:1/; do ollama_endpoint_base_url "$a"; done | tr '\n' '|')"
check "a path a proxy serves it under is kept" "https://ai.example/ollama :0" "$(base https://ai.example/ollama/v1/ | one_line)"
check "a path that only starts like the API's is kept too" "http://h:1/apiary :0" "$(base http://h:1/apiary | one_line)"
check "a URL without a port gets none: 80 or 443 is meant" "https://ai.example :0" "$(base https://ai.example | one_line)"
check "the scheme may be in any case" "http://Host:1 :0" "$(base HTTP://Host:1/ | one_line)"
check "credentials stay, for a proxy that wants them" "http://u:p@h:9 :0" "$(base http://u:p@h:9/v1 | one_line)"
check "an IPv6 address gets the port after its brackets" "http://[::1]:11434|http://[::1]:5|http://[::1]:11434|" "$(for a in '[::1]' '[::1]:5' 'http://[::1]:11434/api'; do ollama_endpoint_base_url "$a"; done | tr '\n' '|')"
check "spaces around it are not part of it" "http://h:11434 :0" "$(base '  h  ' | one_line)"
check "another scheme is not an Ollama's address" ":1" "$(base ftp://h)"
check "nor is text with a space in it" ":1" "$(base 'a b')"
check "nor nothing" ":1" "$(base '')"
check "nor a scheme with no host" ":1" "$(base http:///api)"
check "a port alone is that port of this machine, as Ollama reads it" "http://127.0.0.1:11434|http://127.0.0.1:11434|http://u:p@127.0.0.1:5|" "$(for a in :11434 http://:11434 u:p@:5; do ollama_endpoint_base_url "$a"; done | tr '\n' '|')"
check "a host with a colon and no port gets Ollama's port" "http://h:11434 :0" "$(base h: | one_line)"
check "an IPv6 address without brackets gets them, and the port" "http://[::1]:11434 :0" "$(base ::1 | one_line)"
check "a port that is not a number is not an address" ":1|:1|:1|" "$(for a in h:abc http://h:12x 'http://[::1]:x'; do base "$a"; done | tr '\n' '|')"
check "nor is a port outside 1 to 65535" ":1|:1|:1|" "$(for a in http://h:0 http://h:65536 'http://h:123456'; do base "$a"; done | tr '\n' '|')"
check "an IPv6 literal holds hex digits, colons and dots: 'localhost:11434:' is not one" ":1|:1|http://[fe80::1%eth0]:11434 :0|" "$(for a in 'localhost:11434:' 'http://[localhost:11434:]:5' '[fe80::1%eth0]'; do printf '%s|' "$(base "$a" | one_line)"; done)"
check "an API path is removed however deep it was written" "http://h:1|http://h:1|http://h:1/ollama|" "$(for a in http://h:1/api/v1 http://h:1/api/v1/chat/completions/ http://h:1/ollama/v1/models; do ollama_endpoint_base_url "$a"; done | tr '\n' '|')"
check "a URL that lost its slashes is not a host called http" ":1|:1|:1|" "$(for a in http: http:/h HTTPS:h; do base "$a"; done | tr '\n' '|')"
check "user and password before a bare host stay, and it gets the port" "http://user:pass@host:11434 :0" "$(base user:pass@host | one_line)"
check "a query or a fragment goes, with or without an API path" "http://h:1|http://h:1|http://h:1/p|" "$(for a in 'http://h:1?x=1' 'http://h:1#f' 'http://h:1/p?x=1#f'; do ollama_endpoint_base_url "$a"; done | tr '\n' '|')"
check "a proxy path that only contains /api or /v1 is kept whole" "https://gw.example/api/ollama|https://gw.example/v1/ollama|http://h:1/ollama|http://h:1/a/v1beta|" "$(for a in https://gw.example/api/ollama https://gw.example/v1/ollama/ http://h:1/ollama/api/chat/ http://h:1/a/v1beta; do ollama_endpoint_base_url "$a"; done | tr '\n' '|')"
# A password with "/", "#" or "?" in it has to be percent-encoded. Read by
# halves, the part after it was printed in the message about the address.
check "a password with a slash, a hash or a question mark in it is not an address" ":1|:1|:1|" "$(for a in 'http://user:s3/cret@127.0.0.1:1' 'http://user:s3#cret@127.0.0.1:1' 'http://user:s3?cret@127.0.0.1:1'; do base "$a"; done | tr '\n' '|')"
check "also when what precedes the slash could pass for a port" ":1|:1|" "$(for a in 'http://user:123/456@127.0.0.1:1' 'user:123/456@host'; do base "$a"; done | tr '\n' '|')"
check "nor is a host with a character no host has" ":1|:1|:1|:1|" "$(for a in 'http://h$x:1' 'h`x`' 'http://h"x' "$(printf 'h\001x')"; do base "$a"; done | tr '\n' '|')"

note "whether an address is this machine"
is_local() { if ollama_endpoint_is_local "$1"; then echo local; else echo other; fi; }
for address in http://localhost:1 http://LOCALHOST.:1/x http://app.localhost http://127.0.0.2:1 'http://[::1]:1' \
               'http://[::ffff:127.0.0.1]:1' 'http://[::ffff:7f00:1]:1' http://0.0.0.0:11434 \
               http://host.docker.internal:11434 http://u:p@localhost:1 "http://$(hostname):1"; do
  check "this machine: ${address/$(hostname)/<its own name>}" "local" "$(is_local "$address")"
done
for address in http://192.0.2.10:11434 http://ollama:11434 http://127.example.com:1 http://1270.0.0.1 \
               http://localhost.example.com http://gpu-box:11434 ''; do
  check "not this machine: ${address:-(nothing)}" "other" "$(is_local "$address")"
done
# The short form of a fully qualified own name is this machine too, whatever
# this machine's name happens to be: a stand-in hostname says so.
mkdir -p "$tmp/fake-hostname"
printf '#!/bin/sh\necho Box-Seven.example.lan\n' >"$tmp/fake-hostname/hostname"; chmod +x "$tmp/fake-hostname/hostname"
check "this machine's own name, long or short, in any case" "local local other" "$(PATH="$tmp/fake-hostname:$PATH" bash -c 'source "$0/helpers.sh"; shlib_import logging ollama_endpoint; for a in http://box-seven.example.lan:1 http://BOX-SEVEN:1 http://box-seven.other.lan:1; do if ollama_endpoint_is_local "$a"; then echo local; else echo other; fi; done' "$PWD" | one_line)"
this_host="$(hostname)"
for address in http://remote.example/@localhost 'http://remote.example?x=@localhost' http://localhost@remote.example \
               'http://[::ffff:808:808]:1' 'http://[::ffff:8.8.8.8]:1' http://x127.0.0.1 http://127.0.0.1.example.com \
               "http://${this_host}x:1" "http://${this_host}.elsewhere.example:1" "http://x${this_host}:1"; do
  check "not this machine, though it looks like it: ${address//$this_host/<its own name>}" "other" "$(is_local "$address")"
done
check "every address and the gateway name are this machine too" "local local" "$(is_local 'http://[::]:1') $(is_local http://gateway.docker.internal:11434)"
# Inside a container Docker's names for the host are the host: another
# machine, with a disk this shell cannot see.
: >"$tmp/dockerenv"
check "a Kubernetes pod is a container too: the host is not this machine there" "other" "$( (unset _OLLAMA_EP_DOCKERENV; KUBERNETES_SERVICE_HOST=192.0.2.1 is_local http://host.docker.internal:1) )"
check "inside a container, the host is not this machine" "other other local" "$( (_OLLAMA_EP_DOCKERENV="$tmp/dockerenv"; is_local http://host.docker.internal:11434; is_local http://gateway.docker.internal:1; is_local http://localhost:1) | one_line)"
# One of the machine's own addresses, when a tool here lists any.
own_address="$( { ip -o addr 2>/dev/null | awk '{ print $4 }'; ifconfig 2>/dev/null | awk '$1 == "inet" { print $2 }'; } | sed -E 's#/.*$##; s#^addr:##' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -n 1)"
if [[ -n "$own_address" ]]; then
  check "one of this machine's own addresses is this machine" "local" "$(is_local "http://$own_address:11434")"
  check "a part of one, or one with a digit more, is not" "other other" "$(is_local "http://${own_address%?}:1") $(is_local "http://${own_address}9:1" 2>/dev/null)"
else
  ok "(no address of its own to try here)"
fi

note "a project's .env, read as data"
mkdir -p "$tmp/proj"
cat >"$tmp/proj/.env" <<'ENVFILE'
# what a project keeps beside its start script
SMTP_PASS=a$HOME`touch /tmp/should-never-exist-ollama-ep`b
QUOTED="two words"
OLLAMA_PULL_MISSING=0
FROM_FILE=file
BLANK_IN_ENV=file
EMPTY=
ENVFILE
check "a value is exported as written, not evaluated" 'a$HOME`touch /tmp/should-never-exist-ollama-ep`b' "$(unset SMTP_PASS; ollama_env_file_export "$tmp/proj/.env" SMTP_PASS; printf '%s' "$SMTP_PASS")"
check "and nothing in it was run" "no" "$(if [[ -e /tmp/should-never-exist-ollama-ep ]]; then echo yes; else echo no; fi)"
check "quotes are not part of a value" "two words" "$(unset QUOTED; ollama_env_file_export "$tmp/proj/.env" QUOTED; printf '%s' "$QUOTED")"
check "the environment wins over the file" "env" "$(FROM_FILE="env"; ollama_env_file_export "$tmp/proj/.env" FROM_FILE; printf '%s' "$FROM_FILE")"
check "a blank in the environment does not" "file" "$(BLANK_IN_ENV='  '; ollama_env_file_export "$tmp/proj/.env" BLANK_IN_ENV; printf '%s' "$BLANK_IN_ENV")"
check "a name the file leaves empty, or lacks, stays unset" "unset:unset" "$(unset EMPTY NOT_THERE; ollama_env_file_export "$tmp/proj/.env" EMPTY NOT_THERE; echo "${EMPTY-unset}:${NOT_THERE-unset}")"
check "it is exported, for the programs the caller starts" "file" "$(unset FROM_FILE; ollama_env_file_export "$tmp/proj/.env" FROM_FILE; bash -c 'printf "%s" "${FROM_FILE-}"')"
check "a file that is not there exports nothing and is no error" "0:unset" "$(unset FROM_FILE; ollama_env_file_export "$tmp/proj/none.env" FROM_FILE; echo "$?:${FROM_FILE-unset}")"
check "a name that is not one is refused, and nothing is exported" "2:unset" "$(unset FROM_FILE; ollama_env_file_export "$tmp/proj/.env" FROM_FILE 'BAD NAME' 2>/dev/null; echo "$?:${FROM_FILE-unset}")"

note "a project's start check, in one call"
cat >"$tmp/proj/ai-models.env" <<'MODELS'
OLLAMA_MODEL=main:7b
CLASSIFY_MODEL=small:3b
OLLAMA_EMBED_MODEL=embed
OLLAMA_MODEL_LARGE=huge:70b
MODELS
project() { ollama_project_ensure_models "$@" >"$tmp/out" 2>"$tmp/err"; echo $?; }
# Nothing here may reach the default address: a developer's own Ollama may be
# listening there, and a regression in what is under test would send it a
# pull. The default is moved to a port nothing listens on.
export _OLLAMA_EP_DEFAULT_URL="http://127.0.0.1:1"
unset OLLAMA_URL OLLAMA_BASE_URL OLLAMA_HOST OLLAMA_URL_VARS OLLAMA_MODEL CLASSIFY_MODEL OLLAMA_EMBED_MODEL OLLAMA_MODELS
unset OLLAMA_MODE OLLAMA_PORT OLLAMA_HOST_PORT
roomy; reset main:7b
printf 'OLLAMA_URL=%s\n' "$URL" >"$tmp/proj/.env"
check "the address comes from the project's .env, and what is missing is pulled" "0:small:3b embed:latest" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
check "nothing read from .env is left in the caller's environment" "unset" "${OLLAMA_URL-unset}"
reset main:7b small:3b embed:latest
check "everything there: nothing to do" "0:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b embed:latest
printf 'OLLAMA_URL=%s\nCLASSIFY_MODEL=team/tool:1b\n' "$URL" >"$tmp/proj/.env"
check "a model named in .env is the one checked, not the file's" "0:team/tool:1b" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b embed:latest
check "and the environment wins over .env" "0:small:3b" "$(CLASSIFY_MODEL=small:3b project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
printf 'OLLAMA_URL=%s\nOLLAMA_PULL_MISSING=0\n' "$URL" >"$tmp/proj/.env"
check "a setting in .env counts: pulling is off" "5:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
check "and the environment wins there too" "0:small:3b embed:latest" "$(OLLAMA_PULL_MISSING=1 project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
printf 'OLLAMA_URL=%s\nOLLAMA_BUDGET_DISK_FREE_BYTES=1000\n' "$URL" >"$tmp/proj/.env"
check "the machine's figures can be stated in .env" "1:" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
roomy; reset main:7b small:3b
printf 'MYAPP_OLLAMA_URL=%s/api/generate\n' "$URL" >"$tmp/proj/.env"
check "a project's own name for the address, with the API path in it" "0:embed:latest" "$(OLLAMA_URL_VARS=MYAPP_OLLAMA_URL project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b small:3b
printf 'OLLAMA_URL_VARS=MYAPP_URL\nMYAPP_URL=%s\n' "$URL" >"$tmp/proj/.env"
check "OLLAMA_URL_VARS may itself be in .env" "0:embed:latest" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b small:3b
: >"$tmp/proj/secret-file-name.txt"
check "a pattern in OLLAMA_URL_VARS is a name that is not one, not the files it matches" "9:1:0" "$( (cd "$tmp/proj" && OLLAMA_URL_VARS='OLLAMA_URL *' project "$tmp/proj/ai-models.env" "$tmp/proj/.env") ):$(grep -c 'not a variable: \*' "$tmp/err"):$(grep -c 'secret-file-name' "$tmp/err")"
reset main:7b small:3b
printf 'OLLAMA_URL=%s\nOLLAMA_PULL_MISSING=0\n' "$URL" >"$tmp/proj/.env"
check "a setting the caller holds read-only and blank cannot be read from .env: 9, and nothing is pulled" "9:" "$( (readonly OLLAMA_PULL_MISSING=''; project "$tmp/proj/ai-models.env" "$tmp/proj/.env") ):$(pulled)"
said "and it says which one" "$tmp/err" "OLLAMA_PULL_MISSING is set in" "read-only"
reset main:7b small:3b
printf 'OLLAMA_HOST=%s\n' "${URL#http://}" >"$tmp/proj/.env"
check "OLLAMA_HOST as host:port" "0:embed:latest" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b small:3b
printf 'OLLAMA_BASE_URL=http://192.0.2.1:9\nOLLAMA_URL=%s\n' "$URL" >"$tmp/proj/.env"
check "the first variable of the list that has a value is the address" "0:embed:latest" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b small:3b
check "with no .env the environment alone is read" "0:embed:latest" "$(OLLAMA_BASE_URL="$URL" project "$tmp/proj/ai-models.env"):$(pulled)"
reset main:7b small:3b
printf 'OLLAMA_URL=http://host.docker.internal:%s\n' "${URL##*:}" >"$tmp/proj/.env"
check "Docker's name for the host is this machine, to a script on the host" "0:embed:latest" "$(_OLLAMA_EP_DOCKERENV="$tmp/no-such-file" project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset
printf 'OLLAMA_URL=ftp://somewhere\n' >"$tmp/proj/.env"
check "an address that is not one is refused before anything is asked" "9::" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled):$(cat "$tmp/state/asked" 2>/dev/null)"
said "and it names the variable" "$tmp/err" "OLLAMA_URL is not the address of an Ollama"
# A compose service name does not resolve from a start script. The name is one
# no resolver has (RFC 6761 keeps .invalid for that; a bare word behaves the same).
printf 'OLLAMA_URL=http://no-such-service-xq:11434\n' >"$tmp/proj/.env"
check "a service name that does not resolve here is no Ollama" "4:" "$(OLLAMA_REGISTRY_TIMEOUT=2 project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
said "and it says what such a name usually is, and what to give" "$tmp/err" "no-such-service-xq" "compose service" "published on this machine"
printf 'OLLAMA_URL=http://127.0.0.1:9\n' >"$tmp/proj/.env"
check "an address on this machine where nothing listens gets no such hint" "4:0" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 'compose service' "$tmp/err")"
printf 'OLLAMA_URL=http://nothing.invalid:11434\n' >"$tmp/proj/.env"
check "nor does a full host name" "4:0" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 'compose service' "$tmp/err")"
printf 'OLLAMA_URL=http://localhost:9\n' >"$tmp/proj/.env"
check "nor localhost, one word that is this machine" "4:0" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 'compose service' "$tmp/err")"
printf 'OLLAMA_URL=http://[2001:db8::10]:9\n' >"$tmp/proj/.env"
check "nor an IPv6 address of another machine" "4:0" "$(OLLAMA_REGISTRY_TIMEOUT=2 project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 'compose service' "$tmp/err")"
printf 'OLLAMA_URL=%s\n' "$URL" >"$tmp/proj/.env"
check "a models file that is not there is the project's mistake (9), not a full disk (1) and not no models" "9:" "$(project "$tmp/proj/absent.env" "$tmp/proj/.env"):$(pulled)"
check "a bad name is the project's mistake too" "9:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env" 'BAD NAME'):$(pulled)"
reset
check "only the names asked for are checked" "0:small:3b" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env" CLASSIFY_MODEL):$(pulled)"
reset
printf 'OLLAMA_URL=%s\nOLLAMA_MODEL=small:3b\n' "$URL" >"$tmp/proj/.env"
check "a project with no models file names its models in .env" "0:small:3b" "$(project "" "$tmp/proj/.env" OLLAMA_MODEL):$(pulled)"
printf 'OLLAMA_URL=%s\n' "$URL" >"$tmp/proj/.env"
check "no models named anywhere is nothing to do" "0:" "$(reset; project "" "$tmp/proj/.env" OLLAMA_MODEL):$(pulled)"
reset main:7b
check "a strict caller survives a refusal and gets its code" "5:after" "$( (set -euo pipefail; rc=0; OLLAMA_PULL_MISSING=0 ollama_project_ensure_models "$tmp/proj/ai-models.env" "$tmp/proj/.env" >/dev/null 2>&1 || rc=$?; echo "$rc:after") )"
# With no address anywhere, the default is used.
reset
check "no address anywhere is the default address" "4:" "$(project "$tmp/proj/ai-models.env" ""):$(pulled)"
said "(which these tests moved to a closed port)" "$tmp/err" "No Ollama answers at http://127.0.0.1:1."
printf 'OLLAMA_URL=%s\n' "$URL" >"$tmp/proj/.env"
# A caller in "strict mode" sets IFS to newline and tab. The lists of names
# then came out as one word: the address was not found and the default used.
reset main:7b
check "a caller's IFS of newline and tab does not change what is read" "0:small:3b embed:latest" "$( (IFS=$'\n\t'; project "$tmp/proj/ai-models.env" "$tmp/proj/.env") ):$(pulled)"
reset main:7b
check "nor does one of a comma" "0:small:3b embed:latest" "$( (IFS=,; OLLAMA_URL="$URL" project "$tmp/proj/ai-models.env") ):$(pulled)"
# A project's own names may be the function's own.
reset main:7b small:3b
check "an address variable may be called url, name or value" "0:embed:latest" "$(url="$URL"; export url; OLLAMA_URL_VARS=url project "$tmp/proj/ai-models.env"):$(pulled)"
reset main:7b small:3b
check "the first address variable may be blank: the next one counts" "0:embed:latest" "$(OLLAMA_URL='  ' OLLAMA_BASE_URL="$URL" project "$tmp/proj/ai-models.env"):$(pulled)"
check "a name in OLLAMA_URL_VARS that is not one is the project's mistake, with or without a .env" "9:9" "$(OLLAMA_URL_VARS='OLLAMA_URL 1BAD' project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(OLLAMA_URL_VARS='1BAD' project "$tmp/proj/ai-models.env")"
reset main:7b small:3b
check "a .env that is not there yet is no .env" "0:embed:latest" "$(OLLAMA_URL="$URL" project "$tmp/proj/ai-models.env" "$tmp/proj/not-yet.env"):$(pulled)"
# One value is one model. Split on spaces, "small:3b embed" was two.
reset
printf 'OLLAMA_URL=%s\nOLLAMA_MODEL="small:3b embed"\n' "$URL" >"$tmp/proj/.env"
check "a model value with a space in it is not two models" "8:" "$(project "" "$tmp/proj/.env" OLLAMA_MODEL):$(pulled)"
# A password in an address that cannot be read is not printed.
printf 'OLLAMA_URL=http://user:s3/cret@127.0.0.1:1\n' >"$tmp/proj/.env"
check "an address with a slash in its password is refused" "9:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
check "and no part of the password is printed" "0" "$(grep -c -e 's3' -e 'cret' "$tmp/out" "$tmp/err" | awk -F: '{ n += $2 } END { print n + 0 }')"
# Nor is anything else that is not an address: it may be a key put into the
# wrong variable.
printf 'OLLAMA_URL=sk-live-0123456789abcdef with a space\n' >"$tmp/proj/.env"
check "a value that is not an address is named by its variable, never shown" "9:0:1" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 'sk-live' "$tmp/out" "$tmp/err" | awk -F: '{ n += $2 } END { print n + 0 }'):$(grep -c 'OLLAMA_URL is not the address of an Ollama' "$tmp/err")"
# A proxy may serve an Ollama under a path that holds a key. A URL is named in
# a message by its scheme, host and port, and the path is removed from what
# the other end said too: a proxy's 404 echoes the request path.
check "a pull refused by a proxy that echoes the path: the path is not printed with it" "1:0:1" "$(ollama_endpoint_pull "$URL/t0ken-in-the-path/echo-path" small:3b >/dev/null 2>"$tmp/err"; echo "$?:$(grep -c 't0ken' "$tmp/err"):$(grep -c 'Cannot POST /api/pull' "$tmp/err")")"
printf 'OLLAMA_URL=http://127.0.0.1:1/t0ken-in-the-path/ollama\nOLLAMA_MODE=remote\n' >"$tmp/proj/.env"
check "a path is not part of how an address is named" "0:0:1" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 't0ken' "$tmp/err"):$(grep -c 'http://127.0.0.1:1 does not answer' "$tmp/err")"
printf 'OLLAMA_URL=http://127.0.0.1:1/t0ken-in-the-path/ollama\n' >"$tmp/proj/.env"
check "nor when nothing answers there, or a pull fails" "4:0|1:0" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 't0ken' "$tmp/err")|$(ollama_endpoint_pull "http://127.0.0.1:1/t0ken-in-the-path" small:3b >/dev/null 2>"$tmp/err"; echo "$?:$(grep -c 't0ken' "$tmp/err")")"
printf 'OLLAMA_URL=http://user:s3cret@127.0.0.1:1\n' >"$tmp/proj/.env"
check "a well-formed one is used, and not printed either" "4:0" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 's3cret' "$tmp/err")"

note "where the Ollama runs: OLLAMA_MODE"
printf 'OLLAMA_URL=%s\n' "$URL" >"$tmp/proj/.env"
reset main:7b
check "a mode that is not one of the three is the project's mistake" "9:" "$(OLLAMA_MODE=cloud project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
said "and the three are named, not the value: it may have been meant for another variable" "$tmp/err" "OLLAMA_MODE is not" "local" "docker" "remote"
check "and the value is not repeated" "0" "$(grep -c cloud "$tmp/err")"
check "a mode with a space inside is not one of the three (the ends only are trimmed)" "9:" "$(OLLAMA_MODE='lo cal' project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
check "local: an Ollama on this machine, checked and pulled into" "0:small:3b embed:latest" "$(OLLAMA_MODE=local project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
check "the mode may be written in any case, and host means local" "0:small:3b embed:latest" "$(OLLAMA_MODE=' Host ' project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
printf 'OLLAMA_URL=%s\nOLLAMA_MODE=local\nOLLAMA_BUDGET_DISK_FREE_BYTES=1000\n' "$URL" >"$tmp/proj/.env"
check "it is read from .env, and the disk it measures is the local Ollama's" "1:" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; _OLLAMA_EP_SERVICE_MODELS="$tmp/service/models" project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
said "(the service's directory)" "$tmp/err" "is free at $tmp/service/models"
printf 'OLLAMA_URL=http://192.0.2.10:11434\nOLLAMA_MODE=local\n' >"$tmp/proj/.env"
reset
check "local with an address that is another machine is a contradiction, and nothing is asked" "9:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(cat "$tmp/state/asked" 2>/dev/null)"
said "it says which mode would fit" "$tmp/err" "OLLAMA_MODE is local" "192.0.2.10" "docker" "remote"
# docker: the address in .env is the one a container uses. A start script is
# on the host, where a compose service's name does not resolve.
mkdir -p "$tmp/fake-docker"
printf '#!/bin/sh\n[ "$1" = info ] && echo /srv/docker-root\n' >"$tmp/fake-docker/docker"; chmod +x "$tmp/fake-docker/docker"
reset main:7b
printf 'OLLAMA_URL=http://ollama:%s\nOLLAMA_MODE=docker\n' "${URL##*:}" >"$tmp/proj/.env"
check "docker: a compose service's name is this machine, at the same port" "0:small:3b embed:latest" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
printf 'OLLAMA_URL=http://ollama:11434/api/generate\nOLLAMA_MODE=docker\nOLLAMA_PORT=%s\n' "${URL##*:}" >"$tmp/proj/.env"
check "or at the port the project publishes it on (OLLAMA_PORT)" "0:small:3b embed:latest" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
printf 'OLLAMA_URL=http://user:pw@ollama:11434\nOLLAMA_MODE=docker\nOLLAMA_HOST_PORT=%s\n' "${URL##*:}" >"$tmp/proj/.env"
check "(OLLAMA_HOST_PORT too, with credentials kept)" "0:small:3b embed:latest" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
printf 'OLLAMA_URL=%s\nOLLAMA_MODE=docker\nOLLAMA_PORT=9\n' "$URL" >"$tmp/proj/.env"
check "an address that is this machine already is used as it is" "0:small:3b embed:latest" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
# Inside a container the service's name is the right one: a backend container
# that said docker must not be sent to its own loopback.
reset main:7b
printf 'OLLAMA_URL=http://no-such-service-xq:%s\nOLLAMA_MODE=docker\n' "${URL##*:}" >"$tmp/proj/.env"
: >"$tmp/dockerenv"
check "docker inside a container: the name is used as written, not this machine" "4:" "$(_OLLAMA_EP_DOCKERENV="$tmp/dockerenv" OLLAMA_REGISTRY_TIMEOUT=2 project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
check "(nothing asked of what listens on this machine)" "" "$(cat "$tmp/state/asked" 2>/dev/null)"
# Another machine is not a container here, whatever the mode says.
reset main:7b
for address in http://192.0.2.10:11434 http://gpu-box.example:11434 "http://[2001:db8::10]:11434" http://2130706433:11434; do
  printf 'OLLAMA_URL=%s\nOLLAMA_MODE=docker\n' "$address" >"$tmp/proj/.env"
  check "docker with another machine's address is a contradiction: $address" "9:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
done
said "it says what a container here is named by" "$tmp/err" "OLLAMA_MODE is docker" "compose service name" "remote"
check "(the address is shown without its brackets broken, and nothing is asked)" "1:" "$(grep -c '2130706433' "$tmp/err"):$(cat "$tmp/state/asked" 2>/dev/null)"
# A published port that is not one is a mistake, not "use the address's port":
# that port is often the native Ollama's.
reset main:7b
for port in 1l435 99999 0 ' ' -1; do
  printf 'OLLAMA_URL=http://ollama:%s\nOLLAMA_MODE=docker\nOLLAMA_PORT=%s\n' "${URL##*:}" "$port" >"$tmp/proj/.env"
  expected="9:"
  [[ "$port" == ' ' ]] && expected="0:small:3b embed:latest"  # blank: not set
  check "OLLAMA_PORT='$port'" "$expected" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
  reset main:7b
done
said "and the setting is named" "$tmp/err" "OLLAMA_PORT is not a port number (1 to 65535)"
printf 'OLLAMA_URL=http://ollama:%s\nOLLAMA_MODE=docker\nOLLAMA_HOST_PORT=70000\n' "${URL##*:}" >"$tmp/proj/.env"
check "OLLAMA_HOST_PORT too" "9:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
printf 'OLLAMA_URL=%s\nOLLAMA_MODE=docker\n' "$URL" >"$tmp/proj/.env"
check "its models are on Docker's disk: that is the one measured" "1:" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; OLLAMA_DISK_RESERVE_GB=99999 PATH="$tmp/fake-docker:$PATH" project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
said "(Docker's data root)" "$tmp/err" "is free at /srv/docker-root"
check "or the directory the project states" "1:1" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; OLLAMA_MODELS=/srv/stated OLLAMA_DISK_RESERVE_GB=99999 PATH="$tmp/fake-docker:$PATH" project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 'is free at /srv/stated' "$tmp/err")"
# remote: an API on another machine. Nothing is measured, and nothing is
# pulled unless asked. The stand-in is on this machine; the mode says it is
# not, and the mode is what counts.
reset main:7b small:3b embed:latest
printf 'OLLAMA_URL=%s\nOLLAMA_MODE=remote\n' "$URL" >"$tmp/proj/.env"
check "remote: an Ollama that has every model is fine" "0:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
check "one that lacks a model is a refusal, with nothing pulled and no size asked" "5::" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled):$(cat "$tmp/state/asked" 2>/dev/null)"
said "it names what is missing" "$tmp/err" "small:3b embed:latest." "another machine"
check "a blank OLLAMA_PULL_MISSING is not asking" "5:" "$(OLLAMA_PULL_MISSING='  ' project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
check "asked for, with that machine's figures stated, it is pulled there" "0:small:3b embed:latest" "$(OLLAMA_PULL_MISSING=1 project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
# A hosted API in production is not an Ollama. There is nothing to check, and
# the start must not stop for it.
reset; echo web >"$tmp/state/mode"
check "what does not answer as an Ollama is nothing to check: the start goes on" "0:" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
said "and that is said" "$tmp/err" "OLLAMA_MODE is remote" "does not answer as an Ollama"
reset
printf 'OLLAMA_URL=http://user:s3cret@127.0.0.1:1/v1\nOLLAMA_MODE=remote\n' >"$tmp/proj/.env"
check "nor is one that is not up, and its password is not in the message" "0:0" "$(project "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 's3cret' "$tmp/err")"
printf 'OLLAMA_URL=%s\n' "$URL" >"$tmp/proj/.env"

# An Ollama on another machine. The stand-in is on this one, so the answer to
# "is it this machine" is given here; the rule is tested above.
remote() { ( ollama_endpoint_is_local() { return 1; }; ollama_project_ensure_models "$@" >"$tmp/out" 2>"$tmp/err"; echo $? ); }
roomy; reset main:7b small:3b embed:latest
check "another machine that has every model is fine" "0:" "$(remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b
check "one that lacks a model is a refusal, and nothing is pulled into it" "5::" "$(remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled):$(cat "$tmp/state/asked" 2>/dev/null)"
said "it says why, and the way through" "$tmp/err" "small:3b" "another machine" "OLLAMA_PULL_MISSING=1"
check "asked for, the pull happens there" "0:small:3b embed:latest" "$(OLLAMA_PULL_MISSING=1 remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
# Asked for without that machine's figures: this machine's would be read.
reset main:7b
check "a pull into another machine whose disk and memory are not stated is refused" "7:" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; OLLAMA_PULL_MISSING=1 remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
said "it names what is missing and what to state" "$tmp/err" "small:3b embed:latest." "OLLAMA_BUDGET_DISK_FREE_BYTES" "OLLAMA_IGNORE_BUDGET=1"
check "memory not stated is the same refusal" "7:" "$(unset OLLAMA_BUDGET_MEM_TOTAL_BYTES; OLLAMA_PULL_MISSING=1 remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
check "unless the check is ignored" "0:small:3b embed:latest" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; OLLAMA_PULL_MISSING=1 OLLAMA_IGNORE_BUDGET=1 remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
reset main:7b small:3b embed:latest
check "or nothing is missing there" "0:" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; OLLAMA_PULL_MISSING=1 remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(pulled)"
# Memory on another machine: this machine's GPU and free memory are not its.
mkdir -p "$tmp/fake-gpu"
printf '#!/bin/sh\necho 24000\n' >"$tmp/fake-gpu/nvidia-smi"; chmod +x "$tmp/fake-gpu/nvidia-smi"
printf 'OLLAMA_URL=%s\nOLLAMA_MODEL=twenty:20b\n' "$URL" >"$tmp/proj/gpu.env"
reset
check "a GPU on this machine does not make room on that one" "2:" "$(unset OLLAMA_BUDGET_GPU_BYTES OLLAMA_BUDGET_MEM_AVAILABLE_BYTES; export OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GB)); PATH="$tmp/fake-gpu:$PATH" OLLAMA_PULL_MISSING=1 remote "" "$tmp/proj/gpu.env" OLLAMA_MODEL):$(pulled)"
check "one stated for that machine does" "0:twenty:20b" "$(unset OLLAMA_BUDGET_MEM_AVAILABLE_BYTES; export OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GB)) OLLAMA_BUDGET_GPU_BYTES=$((24 * GB)); OLLAMA_PULL_MISSING=1 remote "" "$tmp/proj/gpu.env" OLLAMA_MODEL):$(pulled)"
# Nor is what is free in this machine's memory right now. What the check is
# handed for that machine is what was stated for it, and nothing read here.
reset
check "the check for that machine is handed its stated memory, and no GPU and no free memory of this one" "avail=64000000000 gpu=0" "$(unset OLLAMA_BUDGET_GPU_BYTES OLLAMA_BUDGET_MEM_AVAILABLE_BYTES; export OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((64 * GB)) OLLAMA_PULL_MISSING=1; ( ollama_endpoint_is_local() { return 1; }; ollama_endpoint_ensure_models() { echo "avail=${OLLAMA_BUDGET_MEM_AVAILABLE_BYTES:-unset} gpu=${OLLAMA_BUDGET_GPU_BYTES:-unset}"; }; ollama_project_ensure_models "" "$tmp/proj/gpu.env" OLLAMA_MODEL 2>/dev/null ))"
roomy; reset main:7b
check "a typo in the setting that would waive the check is reported, not swallowed" "7:1" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; OLLAMA_PULL_MISSING=1 OLLAMA_IGNORE_BUDGET=ture remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 'OLLAMA_IGNORE_BUDGET is neither on' "$tmp/err")"
reset main:7b
printf 'OLLAMA_URL=http://127.0.0.1:9\n' >"$tmp/proj/closed.env"
check "asked to pull into one that does not answer: no Ollama (4), not an unknown budget (7)" "4:" "$(unset OLLAMA_BUDGET_DISK_FREE_BYTES; OLLAMA_PULL_MISSING=1 remote "$tmp/proj/ai-models.env" "$tmp/proj/closed.env"):$(pulled)"
# Inside a container the host's Ollama is another machine: its disk is not
# the container's.
reset main:7b
printf 'OLLAMA_URL=http://host.docker.internal:%s\n' "${URL##*:}" >"$tmp/proj/in-container.env"
check "inside a container, Docker's name for the host is not mapped to the container itself" "4:" "$(_OLLAMA_EP_DOCKERENV="$tmp/dockerenv" OLLAMA_REGISTRY_TIMEOUT=2 project "$tmp/proj/ai-models.env" "$tmp/proj/in-container.env"):$(pulled)"
reset main:7b
check "pulling switched off by the project is not that message's case" "5:0" "$(OLLAMA_PULL_MISSING=0 remote "$tmp/proj/ai-models.env" "$tmp/proj/.env"):$(grep -c 'another machine' "$tmp/err")"
roomy; reset

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
