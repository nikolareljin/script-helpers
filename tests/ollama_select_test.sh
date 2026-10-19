#!/usr/bin/env bash
# SCRIPT: ollama_select_test.sh
# DESCRIPTION: Tests for choosing a model by type of work and tier of host (ai_model_resolve, scripts/ollama_models.sh select).
# USAGE: ./tests/ollama_select_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ollama_select_test.sh
# ----------------------------------------------------
#
# A fake Ollama and registry on 127.0.0.1 (Python): /api/tags lists what a
# state file says is installed, /api/pull "installs" and records, manifests
# answer with sizes, and any DELETE is recorded, so a removal would show.
# Memory and disk are stated through OLLAMA_BUDGET_*, and the tiers file is a
# copy made here, so nothing depends on this machine.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[ollama_select_test] $*"; }
error() { echo "[ollama_select_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[ollama_select_test]   ok  $*"; }
check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else error "$1: expected [$2], got [$3]"; fi
}
said() { # said <description> <file> <text>...
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
  note "SKIP: python3 is needed for the fake Ollama"
  exit 0
fi

tmp="$(mktemp -d)"
server_pid=""
# Invoked only by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging ollama_endpoint

GB=1000000000

cat >"$tmp/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = sys.argv[2]
SIZES = {"library/tier-s:1b": 1000000000, "library/tier-m:4b": 3000000000,
         "library/tier-l:9b": 6000000000, "library/tier-x:20b": 13000000000,
         "library/envmodel:7b": 4000000000, "library/newer:4b": 3000000000}

def read(name):
    path = os.path.join(STATE, name)
    return open(path).read() if os.path.exists(path) else ""

def note(name, line):
    with open(os.path.join(STATE, name), "a", newline="\n") as f:
        f.write(line + "\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def send(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == "/api/tags":
            names = [n for n in read("installed").splitlines() if n]
            return self.send(200, json.dumps({"models": [{"name": n, "model": n} for n in names]}))
        if self.path.startswith("/v2/") and "/manifests/" in self.path:
            name, tag = self.path[len("/v2/"):].split("/manifests/")
            size = SIZES.get(name + ":" + tag)
            if size is None:
                return self.send(404, '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}')
            return self.send(200, json.dumps({"layers": [{"size": size}]}))
        self.send(404, "{}")
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/pull":
            note("pulled", body.get("model", ""))
            note("installed", body.get("model", ""))
            return self.send(200, '{"status":"success"}\n')
        note("other", "POST " + self.path)
        self.send(404, "{}")
    def do_DELETE(self):
        note("removed", self.path)
        self.send(200, "{}")

class Server(HTTPServer):
    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[0], self.server_address[1]

server = Server(("127.0.0.1", 0), H)
with open(sys.argv[1], "w", newline="\n") as port:
    port.write(str(server.server_address[1]))
server.serve_forever()
PY
mkdir -p "$tmp/state"
python3 "$tmp/server.py" "$tmp/port" "$tmp/state" &
server_pid=$!
for _ in $(seq 1 150); do
  if [[ -s "$tmp/port" ]] && curl -fsS --max-time 1 "http://127.0.0.1:$(cat "$tmp/port")/api/tags" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
[[ -s "$tmp/port" ]] || { error "the fake server did not start"; exit 1; }
URL="http://127.0.0.1:$(cat "$tmp/port")"
export OLLAMA_REGISTRY_URL="$URL"

# A tiers file of this test's own: the shipped one changes when it is regenerated.
cat >"$tmp/tiers.txt" <<'EOF'
# GENERATED DATA (test copy)
threshold small_below_ram_gb 11
threshold large_ram_gb 30
threshold large_vram_gb 11
threshold xlarge_vram_gb 23
type general tier-s:1b tier-m:4b tier-l:9b tier-x:20b
type embed   tier-s:1b tier-s:1b tier-s:1b tier-s:1b
EOF
export OLLAMA_MODEL_TIERS_FILE="$tmp/tiers.txt"

one_line() { tr -d '\r' | tr '\n' ' ' | sed 's/ $//'; }
pulled() { if [[ -f "$tmp/state/pulled" ]]; then one_line <"$tmp/state/pulled"; fi; }
installed() { one_line <"$tmp/state/installed"; }
reset() { # reset [installed model...]
  rm -f "$tmp/state/installed" "$tmp/state/pulled" "$tmp/state/removed"
  : >"$tmp/state/installed"
  local m
  for m in "$@"; do echo "$m" >>"$tmp/state/installed"; done
}
# A standard-tier machine with room, nobody at a terminal, not CI.
machine() {
  export OLLAMA_BUDGET_DISK_FREE_BYTES=$((200 * GB)) OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((16 * 1073741824))
  export OLLAMA_BUDGET_MEM_AVAILABLE_BYTES=$((12 * GB)) OLLAMA_BUDGET_GPU_BYTES=0 OLLAMA_BUDGET_GPU_LARGEST_BYTES=0
  unset AI_MODEL_TIER OLLAMA_PULL_MISSING OLLAMA_IGNORE_BUDGET CI GITHUB_ACTIONS OLLAMA_MODEL
}
_ollama_ep_can_ask() { return 1; }
terminal()    { _ollama_ep_can_ask() { return 0; }; }
no_terminal() { _ollama_ep_can_ask() { return 1; }; }
GiB=1073741824

# --- the data file and the tier ----------------------------------------------
machine
check "the shipped tiers file names every documented type" "general reasoning classify extract vision embed code" \
  "$(OLLAMA_MODEL_TIERS_FILE='' ollama_model_tier_types | grep -x -E 'general|reasoning|classify|extract|vision|embed|code' | one_line)"
check "and it says it is generated" "1" "$(head -n 1 config/ollama_model_tiers.txt | grep -c '^# GENERATED DATA')"
check "every shipped type has a valid model for all four tiers" "" \
  "$(for t in $(OLLAMA_MODEL_TIERS_FILE='' ollama_model_tier_types); do for r in small standard large xlarge; do OLLAMA_MODEL_TIERS_FILE='' ollama_tier_model "$t" "$r" >/dev/null 2>&1 || echo "$t/$r"; done; done)"
check "16 GiB, no GPU: standard" "standard" "$(ollama_host_tier)"
check "8 GiB, no GPU: small" "small" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GiB)) ollama_host_tier)"
check "8 GiB with a 12 GB card: large, not small" "large" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GiB)) OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ollama_host_tier)"
check "32 GiB memory: large" "large" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((32 * GiB)) ollama_host_tier)"
check "a 24 GB card: xlarge" "xlarge" "$(OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((24 * GiB)) ollama_host_tier)"
check "AI_MODEL_TIER names it, any case" "xlarge" "$(AI_MODEL_TIER=' XLarge' ollama_host_tier)"
check "a bad AI_MODEL_TIER is refused (3)" "3:" "$(AI_MODEL_TIER=huge ollama_host_tier 2>"$tmp/err"; echo "$?:")"
said "naming the variable and the value" "$tmp/err" "AI_MODEL_TIER" "huge"
check "the tier's model for a type" "tier-l:9b" "$(ollama_tier_model general large)"
check "a type in any case" "tier-l:9b" "$(ollama_tier_model General large)"
printf 'A=1\r\nOLD_CHOICE=x\r\n' >"$tmp/crlf.env"
_ollama_ep_env_set "$tmp/crlf.env" OLD_CHOICE y
check "storing an answer leaves the other lines' Windows line ends alone" "A=1" "$(grep $'\r$' "$tmp/crlf.env" | tr -d '\r')"
check "an unknown type is refused (2), naming the known ones" "2" "$(ollama_tier_model chat 2>"$tmp/err"; echo $?)"
said "the known types are named" "$tmp/err" "general embed"

# --- same, or no env model ---------------------------------------------------
machine; reset tier-m:4b
check "no env model: the tier's pick, nothing pulled" "0:tier-m:4b:" "$(m="$(ai_model_resolve general "$URL" "" OLLAMA_MODEL 2>/dev/null)"; echo "$?:$m:$(pulled)")"
check "the model is the only line on stdout" "tier-m:4b" "$(ai_model_resolve general "$URL" "" OLLAMA_MODEL 2>/dev/null | one_line)"
check "an env model equal to the pick, written otherwise, is the pick" "tier-m:4b" "$(OLLAMA_MODEL='Tier-M:4B' ai_model_resolve general "$URL" "" OLLAMA_MODEL 2>/dev/null)"
check "a stated tier changes the pick" "tier-s:1b" "$(reset tier-s:1b; AI_MODEL_TIER=small ai_model_resolve general "$URL" 2>/dev/null)"
check "a measured large host gets the large pick" "tier-l:9b" "$(reset tier-l:9b; OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((32 * GiB)) ai_model_resolve general "$URL" 2>/dev/null)"

# --- pulling on demand ---------------------------------------------------------
machine; reset
check "missing, OLLAMA_PULL_MISSING=0: never pulled (5)" "5:" "$(OLLAMA_PULL_MISSING=0 ai_model_resolve general "$URL" 2>/dev/null; echo "$?:$(pulled)")"
reset
check "missing, OLLAMA_PULL_MISSING=1: pulled without asking" "0:tier-m:4b:tier-m:4b" "$(m="$(OLLAMA_PULL_MISSING=1 ai_model_resolve general "$URL" 2>/dev/null)"; echo "$?:$m:$(pulled)")"
reset
check "missing, unset, no terminal: asked for, so nothing is pulled (5)" "5:" "$(ai_model_resolve general "$URL" 2>/dev/null; echo "$?:$(pulled)")"
reset
check "missing, does not fit the disk: nothing pulled (1)" "1:" "$(OLLAMA_PULL_MISSING=1 OLLAMA_BUDGET_DISK_FREE_BYTES=$((5 * GB)) ai_model_resolve general "$URL" 2>/dev/null; echo "$?:$(pulled)")"
reset
check "missing, does not fit memory: nothing pulled (2)" "2:" "$(reset; OLLAMA_PULL_MISSING=1 AI_MODEL_TIER=xlarge OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GB)) ai_model_resolve general "$URL" 2>/dev/null; echo "$?:$(pulled)")"
check "no Ollama at the address (4)" "4" "$(ai_model_resolve general http://127.0.0.1:1 2>/dev/null; echo $?)"

# --- they differ, on a terminal: ask once, remember -----------------------------
machine; reset tier-m:4b envmodel:7b
env_file="$tmp/proj.env"
printf 'OLLAMA_MODEL=envmodel:7b\nOTHER=1\n' >"$env_file"
check "asked; answer 1: the env model" "envmodel:7b" "$(terminal; ai_model_resolve general "$URL" "$env_file" OLLAMA_MODEL <<<"1" 2>"$tmp/err")"
said "the question names both models and the tier" "$tmp/err" "envmodel:7b" "tier-m:4b" "standard"
check "the answer and the model it was asked about are stored" "envmodel:7b tier-m:4b 1" \
  "$(ollama_models_file_get "$env_file" OLLAMA_MODEL_CHOICE) $(ollama_models_file_get "$env_file" OLLAMA_MODEL_CHOICE_FOR) $(ollama_models_file_get "$env_file" OTHER)"
check "asked again: not asked, the stored answer is used" "envmodel:7b:0" \
  "$(terminal; ai_model_resolve general "$URL" "$env_file" OLLAMA_MODEL </dev/null 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "and with no terminal, the same" "envmodel:7b" "$(no_terminal; ai_model_resolve general "$URL" "$env_file" OLLAMA_MODEL 2>/dev/null)"
check "the approved model changes: asked again; answer 2 takes it" "tier-l:9b:1" \
  "$(terminal; reset tier-m:4b envmodel:7b tier-l:9b; AI_MODEL_TIER=large ai_model_resolve general "$URL" "$env_file" OLLAMA_MODEL <<<"2" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "and the new answer replaced the old lines, not added to them" "tier-l:9b tier-l:9b 1 1" \
  "$(ollama_models_file_get "$env_file" OLLAMA_MODEL_CHOICE) $(ollama_models_file_get "$env_file" OLLAMA_MODEL_CHOICE_FOR) $(grep -c '^OLLAMA_MODEL_CHOICE=' "$env_file") $(grep -c '^OLLAMA_MODEL_CHOICE_FOR=' "$env_file")"
check "an empty answer is the approved model" "tier-m:4b" "$(terminal; rm -f "$tmp/e2"; ai_model_resolve general "$URL" "$tmp/e2" "" envmodel:7b <<<"" 2>/dev/null)"
check "a new .env is created for the owner only, with the type's key" "600 tier-m:4b" \
  "$( (stat -c %a "$tmp/e2" 2>/dev/null || stat -f %Lp "$tmp/e2") | tr -d '\n') $(ollama_models_file_get "$tmp/e2" AI_MODEL_GENERAL_CHOICE)"
reset envmodel:7b tier-m:4b
check "in CI a terminal is not asked: the no-terminal order applies" "tier-m:4b:0" \
  "$(terminal; CI=true ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
reset tier-m:4b
check "answer 1 on a terminal pulls the env model without a second question" "envmodel:7b:envmodel:7b" \
  "$(terminal; ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" 2>/dev/null):$(pulled)"
reset tier-m:4b
check "unless OLLAMA_PULL_MISSING=0: nothing pulled (5)" "5:" \
  "$(terminal; OLLAMA_PULL_MISSING=0 ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" >/dev/null 2>&1; echo "$?:$(pulled)")"

# --- they differ, no terminal ------------------------------------------------------
machine; no_terminal
reset tier-m:4b envmodel:7b
check "no terminal, both installed: the tier's pick" "tier-m:4b" "$(ai_model_resolve general "$URL" "" "" envmodel:7b 2>/dev/null)"
reset envmodel:7b
check "no terminal, only the env model installed: the env model" "envmodel:7b" "$(ai_model_resolve general "$URL" "" "" envmodel:7b 2>/dev/null)"
reset
check "no terminal, neither: stop (12), nothing pulled" "12:" "$(OLLAMA_PULL_MISSING=1 ai_model_resolve general "$URL" "" "" envmodel:7b 2>"$tmp/err"; echo "$?:$(pulled)")"
said "naming both" "$tmp/err" "envmodel:7b" "tier-m:4b"
reset
check "the env model comes from the env file when the environment has none" "12" "$(printf 'OLLAMA_MODEL=envmodel:7b\n' >"$tmp/e3"; ai_model_resolve general "$URL" "$tmp/e3" OLLAMA_MODEL 2>"$tmp/err"; echo $?)"
said "and that file's model is the one named" "$tmp/err" "envmodel:7b"

# --- bad input ---------------------------------------------------------------------
machine
check "bad AI_MODEL_TIER: 11, naming the variable and value" "11" "$(AI_MODEL_TIER=medium ai_model_resolve general "$URL" 2>"$tmp/err"; echo $?)"
said "the message" "$tmp/err" "AI_MODEL_TIER" "medium"
check "unknown type: 10" "10" "$(ai_model_resolve chat "$URL" 2>/dev/null; echo $?)"
# shellcheck disable=SC2016  # the command must stay unexpanded
check "a NAME that is not a variable name: 10" "10" "$(ai_model_resolve general "$URL" "" 'x[$(id)]' 2>/dev/null; echo $?)"
check "an env model that is not a model reference: 10" "10" "$(ai_model_resolve general "$URL" "" "" 'bad model' 2>/dev/null; echo $?)"
check "no data file: 10" "10" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/none" ai_model_resolve general "$URL" 2>/dev/null; echo $?)"

# --- nothing removed -----------------------------------------------------------------
check "no model was ever removed" "" "$(cat "$tmp/state/removed" 2>/dev/null)"

# --- the script ----------------------------------------------------------------------
machine; reset tier-m:4b envmodel:7b
script="$root_dir/scripts/ollama_models.sh"
check "--help exits 0, from any directory" "0" "$( (cd "$tmp" && bash "$script" --help >/dev/null 2>&1); echo $?)"
check "select prints the model alone on stdout" "tier-m:4b" "$( (cd "$tmp" && bash "$script" select general "$URL" "" "" envmodel:7b 2>/dev/null </dev/null) )"
check "select with no address: 10" "10" "$(bash "$script" select general 2>/dev/null; echo $?)"
check "select with a bad tier: 11" "11" "$(AI_MODEL_TIER=x bash "$script" select general "$URL" 2>/dev/null </dev/null; echo $?)"
check "class names the tier" "tier=large" "$(AI_MODEL_TIER=large bash "$script" class | grep '^tier=')"
check "no model was removed by the script either" "tier-m:4b envmodel:7b" "$(installed)"

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "all passed"
