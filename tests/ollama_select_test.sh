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
            note("tags", "GET")
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
listings() { if [[ -f "$tmp/state/tags" ]]; then grep -c . <"$tmp/state/tags"; else echo 0; fi; }
pulled() { if [[ -f "$tmp/state/pulled" ]]; then one_line <"$tmp/state/pulled"; fi; }
installed() { one_line <"$tmp/state/installed"; }
reset() { # reset [installed model...]
  rm -f "$tmp/state/installed" "$tmp/state/pulled" "$tmp/state/removed" "$tmp/state/tags"
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
# Replaced per case below; the library calls it.
# shellcheck disable=SC2317
_ollama_ep_can_ask() { return 1; }
# shellcheck disable=SC2317
terminal()    { _ollama_ep_can_ask() { return 0; }; }
no_terminal() { _ollama_ep_can_ask() { return 1; }; }
# The Ollama is on another machine; this one has 32 GiB (a large host).
# shellcheck disable=SC2317
remote() {
  ollama_endpoint_is_local() { return 1; }
  # As the real one: a stated figure wins over this machine's.
  ollama_mem_total_bytes() { echo "${OLLAMA_BUDGET_MEM_TOTAL_BYTES:-$((32 * 1073741824))}"; }
  unset OLLAMA_BUDGET_MEM_TOTAL_BYTES
}
GiB=1073741824
# Stubs for one case each, called inside $(...).
# shellcheck disable=SC2317
memory_unreadable() { ollama_mem_total_bytes() { return 1; }; }
# shellcheck disable=SC2317
local_gpu_24() { _ollama_ep_gpu_list() { echo $((24 * GiB)); }; }
# shellcheck disable=SC2317
disk_known_at_root_only() { ollama_disk_free_bytes() { [[ "$1" != / ]] || echo $((200 * GB)); }; }

# --- the data file and the tier ----------------------------------------------
machine
check "the shipped tiers file names every documented type" "general reasoning classify extract vision embed code" \
  "$(OLLAMA_MODEL_TIERS_FILE='' ollama_model_tier_types | grep -x -E 'general|reasoning|classify|extract|vision|embed|code' | one_line)"
check "the consumer example in docs/local-models.md uses the vendored path" "0 1" \
  "$(grep -c '"$(scripts/ollama_models.sh select' docs/local-models.md) $(grep -c 'scripts/script-helpers/scripts/ollama_models.sh select' docs/local-models.md)"
check "and it says it is generated" "1" "$(head -n 1 config/ollama_model_tiers.txt | grep -c '^# GENERATED DATA')"
check "every shipped type has a valid model for all four tiers" "" \
  "$(for t in $(OLLAMA_MODEL_TIERS_FILE='' ollama_model_tier_types); do for r in small standard large xlarge; do OLLAMA_MODEL_TIERS_FILE='' ollama_tier_model "$t" "$r" >/dev/null 2>&1 || echo "$t/$r"; done; done)"
check "16 GiB, no GPU: standard" "standard" "$(ollama_host_tier)"
check "8 GiB, no GPU: small" "small" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GiB)) ollama_host_tier)"
check "8 GiB with a 12 GB card: large, not small" "large" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GiB)) OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ollama_host_tier)"
check "32 GiB memory: large" "large" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((32 * GiB)) ollama_host_tier)"
check "memory at the large floor (30 GiB): large" "large" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((30 * GiB)) ollama_host_tier)"
check "one GiB under it (29): standard" "standard" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((30 * GiB - 1)) ollama_host_tier)"
check "memory at the small floor (11 GiB): standard" "standard" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((11 * GiB)) ollama_host_tier)"
check "just under it: small" "small" "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((11 * GiB - 1)) ollama_host_tier)"
check "a card at the xlarge floor (23 GiB): xlarge; under it: large" "xlarge large" \
  "$(OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((23 * GiB)) ollama_host_tier) $(OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((23 * GiB - 1)) ollama_host_tier)"
check "a 24 GB card: xlarge" "xlarge" "$(OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((24 * GiB)) ollama_host_tier)"
check "AI_MODEL_TIER names it, any case" "xlarge" "$(AI_MODEL_TIER=' XLarge' ollama_host_tier)"
check "a bad AI_MODEL_TIER is refused (3)" "3:" "$(AI_MODEL_TIER=huge ollama_host_tier 2>"$tmp/err"; echo "$?:")"
said "naming the variable and the value" "$tmp/err" "AI_MODEL_TIER" "huge"
check "no data file and no AI_MODEL_TIER: 2, not a guessed tier" "2:" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/none" ollama_host_tier 2>/dev/null; echo "$?:")"
check "no data file, AI_MODEL_TIER set: that tier" "large" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/none" AI_MODEL_TIER=large ollama_host_tier)"
printf 'threshold large_ram_gb 30GB\ntype general tier-s:1b tier-m:4b tier-l:9b tier-x:20b\n' >"$tmp/badthr.txt"
check "a threshold that is not a whole number is refused (2), not read as missing" "2:" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/badthr.txt" OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((32 * GiB)) ollama_host_tier 2>"$tmp/err"; echo "$?:")"
said "naming the key and the value" "$tmp/err" "large_ram_gb" "30GB"
check "so select stops (10) instead of picking a lower tier" "10" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/badthr.txt" ai_model_resolve general "$URL" 2>/dev/null; echo "$?")"
check "the tier's model for a type" "tier-l:9b" "$(ollama_tier_model general large)"
check "a type in any case" "tier-l:9b" "$(ollama_tier_model General large)"
printf 'A=1\r\nOLD_CHOICE=x\r\n' >"$tmp/crlf.env"
_ollama_ep_env_set "$tmp/crlf.env" OLD_CHOICE y
check "storing in a file with Windows line ends keeps them on every line" "A=1 OLD_CHOICE=y NEW=z" \
  "$(_ollama_ep_env_set "$tmp/crlf.env" NEW z; grep $'\r$' "$tmp/crlf.env" | one_line)"
check "and no line lacks one" "0" "$(grep -c -v $'\r$' "$tmp/crlf.env")"
printf '\xef\xbb\xbfK_CHOICE=a\n# keep me\nB="x y" # c' >"$tmp/bom.env"
_ollama_ep_env_set "$tmp/bom.env" K_CHOICE b K_CHOICE_FOR c
check "a key on a first line with a byte-order mark is replaced, not added twice" "b 1 1" \
  "$(ollama_models_file_get "$tmp/bom.env" K_CHOICE) $(grep -c 'K_CHOICE=' "$tmp/bom.env") $(head -c 3 "$tmp/bom.env" | od -An -tx1 | tr -d ' \n' | grep -c '^efbbbf$')"
check "comments, quoted values and a last line with no newline are kept" "x y|1|c" \
  "$(ollama_models_file_get "$tmp/bom.env" B)|$(grep -c '^# keep me$' "$tmp/bom.env")|$(ollama_models_file_get "$tmp/bom.env" K_CHOICE_FOR)"
printf 'K_CHOICE=a\nexport K_CHOICE=b\nK_CHOICE = c\n' >"$tmp/dup.env"
for _ in 1 2 3; do _ollama_ep_env_set "$tmp/dup.env" K_CHOICE d; done
check "duplicate lines collapse to one, however often it runs" "K_CHOICE=d" "$(one_line <"$tmp/dup.env")"
printf 'export K_CHOICE=a\nexport K_CHOICE=b\n' >"$tmp/exp.env"
_ollama_ep_env_set "$tmp/exp.env" K_CHOICE d
check "an export line stays an export line" "export K_CHOICE=d" "$(one_line <"$tmp/exp.env")"
lost=0
for _ in 1 2 3 4 5 6 7 8; do
  printf 'KEEP=1\n' >"$tmp/race.env"
  _ollama_ep_env_set "$tmp/race.env" A_CHOICE a A_CHOICE_FOR b & p1=$!
  _ollama_ep_env_set "$tmp/race.env" B_CHOICE c B_CHOICE_FOR d & p2=$!
  wait "$p1" "$p2"
  [[ "$(grep -c -E '^(KEEP|A_CHOICE|A_CHOICE_FOR|B_CHOICE|B_CHOICE_FOR)=' "$tmp/race.env")" == 5 ]] || lost=$((lost + 1))
done
check "two runs storing at once both keep their answers" "0" "$lost"
check "and leave no lock behind" "" "$(find "$tmp" -maxdepth 1 -name '.race.env.lock*')"
ln -sf loop-b.env "$tmp/loop-a.env"; ln -sf loop-a.env "$tmp/loop-b.env"
check "a symlink loop is refused (1), not followed forever" "1" "$(_ollama_ep_env_set "$tmp/loop-a.env" A 1; echo $?)"
printf 'A=1\n' >"$tmp/mode.env"; chmod 640 "$tmp/mode.env"
_ollama_ep_env_set "$tmp/mode.env" A 2
check "an existing file keeps its mode" "640" "$( (stat -c %a "$tmp/mode.env" 2>/dev/null || stat -f %Lp "$tmp/mode.env") | tr -d '\n')"
mkdir -p "$tmp/real"; printf 'A=1\n' >"$tmp/real/target.env"; ln -sf real/target.env "$tmp/link.env"
_ollama_ep_env_set "$tmp/link.env" A 2
check "a symlinked .env stays a symlink; its target is written" "link A=2" \
  "$([[ -L "$tmp/link.env" ]] && echo link) $(one_line <"$tmp/real/target.env")"
check "no temporary file is left next to it" "" "$(find "$tmp/real" -name '.target.env.*')"
check "a bad name is refused (1), the file untouched" "1:A=2" "$(_ollama_ep_env_set "$tmp/mode.env" 'A-B' 3; echo "$?:$(one_line <"$tmp/mode.env")")"
check "an unknown type is refused (2), naming the known ones" "2" "$(ollama_tier_model chat 2>"$tmp/err"; echo $?)"
said "the known types are named" "$tmp/err" "general embed"

# --- same, or no env model ---------------------------------------------------
machine; reset tier-m:4b
check "no env model: the tier's pick, nothing pulled" "0:tier-m:4b:" "$(m="$(ai_model_resolve general "$URL" "" OLLAMA_MODEL 2>/dev/null)"; echo "$?:$m:$(pulled)")"
check "an address with a trailing slash is the same address" "tier-m:4b" "$(ai_model_resolve general "$URL/" "" OLLAMA_MODEL 2>/dev/null)"
check "a project model that is not a model reference: 10, named" "10" "$(ai_model_resolve general "$URL" "" "" 'bad model' 2>"$tmp/err"; echo $?)"
said "the bad model is named" "$tmp/err" "Not a model reference"
check "the model is the only line on stdout" "tier-m:4b" "$(ai_model_resolve general "$URL" "" OLLAMA_MODEL 2>/dev/null | one_line)"
check "an env model equal to the pick, written otherwise, is the pick" "tier-m:4b" "$(OLLAMA_MODEL='Tier-M:4B' ai_model_resolve general "$URL" "" OLLAMA_MODEL 2>/dev/null)"
check "a stated tier changes the pick" "tier-s:1b" "$(reset tier-s:1b; AI_MODEL_TIER=small ai_model_resolve general "$URL" 2>/dev/null)"
check "a measured large host gets the large pick" "tier-l:9b" "$(reset tier-l:9b; OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((32 * GiB)) ai_model_resolve general "$URL" 2>/dev/null)"

# An Ollama on another machine: its tier is not this one's (a 32 GiB host here).
check "a remote Ollama with no stated figures: standard, not this host's large" "tier-m:4b" \
  "$(reset tier-m:4b tier-l:9b; remote; ai_model_resolve general "$URL" 2>/dev/null)"
check "a remote Ollama with stated memory: measured from it, not from this host" "tier-l:9b tier-s:1b" \
  "$(reset tier-s:1b tier-m:4b tier-l:9b; remote; OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((32 * GiB)) ai_model_resolve general "$URL" 2>/dev/null) $(remote; OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GiB)) ai_model_resolve general "$URL" 2>/dev/null)"
check "a remote Ollama with AI_MODEL_TIER: that tier" "tier-s:1b" \
  "$(reset tier-s:1b; remote; AI_MODEL_TIER=small ai_model_resolve general "$URL" 2>/dev/null)"

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
check "the project's model changes: asked again" "newer:4b:1" \
  "$(terminal; reset tier-m:4b envmodel:7b newer:4b tier-l:9b; printf 'OLLAMA_MODEL=newer:4b\nOLLAMA_MODEL_CHOICE=envmodel:7b\nOLLAMA_MODEL_CHOICE_FOR=tier-m:4b\n' >"$tmp/xchg.env"; ai_model_resolve general "$URL" "$tmp/xchg.env" OLLAMA_MODEL <<<"1" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "an invalid answer is asked again, then taken" "envmodel:7b:1" \
  "$(terminal; reset tier-m:4b envmodel:7b; ai_model_resolve general "$URL" "" "" envmodel:7b <<<$'3\n1' 2>"$tmp/err"):$(grep -c 'answer 1 or 2' "$tmp/err")"
check "three invalid answers: the approved model, with a warning" "tier-m:4b:1" \
  "$(terminal; ai_model_resolve general "$URL" "" "" envmodel:7b <<<$'a\nb\nc\n1' 2>"$tmp/err"):$(grep -c 'No valid answer' "$tmp/err")"
check "end of input is the approved model" "tier-m:4b" "$(terminal; ai_model_resolve general "$URL" "" "" envmodel:7b </dev/null 2>/dev/null)"
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
  "$(terminal; OLLAMA_PULL_MISSING=0 ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" 2>/dev/null; echo "$?:$(pulled)")"

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

# --- CI, by any spelling ---------------------------------------------------------
machine; reset envmodel:7b tier-m:4b
check "CI=1 with a terminal: not asked" "tier-m:4b:0" \
  "$(terminal; CI=1 ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "GITHUB_ACTIONS with a terminal: not asked" "tier-m:4b:0" \
  "$(terminal; GITHUB_ACTIONS=true ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "CI=false with a terminal: asked" "envmodel:7b:1" \
  "$(terminal; CI=false ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
reset
check "in CI a missing model is not asked about with a terminal: nothing pulled (5)" "5::0" \
  "$(terminal; CI=true ai_model_resolve general "$URL" <<<"y" 2>"$tmp/err"; echo "$?:$(pulled):$(grep -c 'Pull now' "$tmp/err")")"

# --- the question names where the project's model came from --------------------------
machine; reset tier-m:4b envmodel:7b
check "a default model is called the project default" "1" \
  "$(terminal; ai_model_resolve general "$URL" "" "" envmodel:7b <<<"2" 2>"$tmp/err" >/dev/null; grep -c 'project default has envmodel:7b' "$tmp/err")"
check "an env model is called your env" "1" \
  "$(terminal; OLLAMA_MODEL=envmodel:7b ai_model_resolve general "$URL" "" OLLAMA_MODEL <<<"2" 2>"$tmp/err" >/dev/null; grep -c 'your env has envmodel:7b' "$tmp/err")"

# --- a choice set by hand ----------------------------------------------------------------
machine; reset tier-m:4b envmodel:7b newer:4b
printf 'OLLAMA_MODEL=envmodel:7b\nOLLAMA_MODEL_CHOICE=newer:4b\n' >"$tmp/hand.env"
check "NAME_CHOICE with no _FOR: used as set, never asked" "newer:4b:0" \
  "$(terminal; ai_model_resolve general "$URL" "$tmp/hand.env" OLLAMA_MODEL </dev/null 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "also when the project names no model of its own" "newer:4b" \
  "$(printf 'AI_MODEL_GENERAL_CHOICE=newer:4b\n' >"$tmp/hand2.env"; ai_model_resolve general "$URL" "$tmp/hand2.env" 2>/dev/null)"
check "and the file is left as it was" "OLLAMA_MODEL=envmodel:7b OLLAMA_MODEL_CHOICE=newer:4b" "$(one_line <"$tmp/hand.env")"
check "a hand choice that is not a model reference: 10" "10" \
  "$(printf 'OLLAMA_MODEL_CHOICE="bad model"\n' >"$tmp/hand3.env"; ai_model_resolve general "$URL" "$tmp/hand3.env" OLLAMA_MODEL 2>/dev/null; echo $?)"

# --- the .env must be git-ignored to be written ----------------------------------------
machine; reset tier-m:4b envmodel:7b
if command -v git >/dev/null 2>&1; then
  repo="$tmp/repo"
  git init -q "$repo"
  printf 'OLLAMA_MODEL=envmodel:7b\n' >"$repo/.env"
  check "a .env not ignored by git: the answer is used, not stored" "envmodel:7b:" \
    "$(terminal; ai_model_resolve general "$URL" "$repo/.env" OLLAMA_MODEL <<<"1" 2>"$tmp/err"):$(ollama_models_file_get "$repo/.env" OLLAMA_MODEL_CHOICE)"
  said "with a warning naming the file" "$tmp/err" "not git-ignored" "$repo/.env"
  printf '.env\n' >"$repo/.gitignore"
  check "once ignored: stored" "envmodel:7b:envmodel:7b" \
    "$(terminal; ai_model_resolve general "$URL" "$repo/.env" OLLAMA_MODEL <<<"1" 2>/dev/null):$(ollama_models_file_get "$repo/.env" OLLAMA_MODEL_CHOICE)"
fi

# --- an unreadable .env ------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
  printf 'OLLAMA_MODEL=envmodel:7b\n' >"$tmp/locked.env"
  chmod 000 "$tmp/locked.env"
  check "an env_file that cannot be read: 10, nothing asked" "10:0" \
    "$(terminal; ai_model_resolve general "$URL" "$tmp/locked.env" OLLAMA_MODEL <<<"1" 2>"$tmp/err"; echo "$?:$(grep -c 'Choose' "$tmp/err")")"
  chmod 600 "$tmp/locked.env"
fi

# --- nothing removed -----------------------------------------------------------------
check "no model was ever removed" "" "$(cat "$tmp/state/removed" 2>/dev/null)"

# --- the script ----------------------------------------------------------------------
machine; reset tier-m:4b envmodel:7b
script="$root_dir/scripts/ollama_models.sh"
check "--help exits 0, from any directory" "0" "$( (cd "$tmp" && bash "$script" --help >/dev/null 2>&1); echo $?)"
check "select prints the model alone on stdout" "tier-m:4b" "$( (cd "$tmp" && bash "$script" select general "$URL" "" "" envmodel:7b 2>/dev/null </dev/null) )"
check "select with no address: 2" "2" "$(bash "$script" select general 2>/dev/null; echo $?)"
check "select with no type: 2" "2" "$(bash "$script" select 2>/dev/null; echo $?)"
check "select with a bad tier: 11" "11" "$(AI_MODEL_TIER=x bash "$script" select general "$URL" 2>/dev/null </dev/null; echo $?)"
check "class with no data file: tier unknown, still 0" "0:tier=unknown" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/none" bash "$script" class 2>"$tmp/err" >"$tmp/out"; echo "$?:$(grep '^tier=' "$tmp/out")")"
check "and a warning, not an error, to match exit 0" "1:0" "$(grep -c 'WARN' "$tmp/err"):$(grep -ci 'error' "$tmp/err")"
check "class with no data file but AI_MODEL_TIER: that tier, no warning" "tier=large:0" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/none" AI_MODEL_TIER=large bash "$script" class 2>"$tmp/err" | grep '^tier='):$(grep -c . "$tmp/err")"
check "class with a bad AI_MODEL_TIER: 2" "2" "$(AI_MODEL_TIER=huge bash "$script" class >/dev/null 2>&1; echo $?)"
check "class names the tier" "tier=large" "$(AI_MODEL_TIER=large bash "$script" class | grep '^tier=')"
# Nothing stated: this runner's own memory (/proc/meminfo, sysctl hw.memsize) is
# read. Only the shape is checked, so any machine passes.
check "class with nothing stated measures this machine" "ok" \
  "$(measured="$(env -u AI_MODEL_TIER -u OLLAMA_BUDGET_MEM_TOTAL_BYTES -u OLLAMA_BUDGET_GPU_LARGEST_BYTES bash "$script" class 2>/dev/null | tr '\n' ' ')"
     grep -qE '^memory_gib=[0-9]+ largest_gpu_gib=[0-9]+ tier=(small|standard|large|xlarge) $' <<<"$measured" && echo ok)"
check "no model was removed by the script either" "tier-m:4b envmodel:7b" "$(installed)"

# --- a NAME named like the library's own variables -----------------------------------
# Small tier: its model is not installed, the project's is, so the project's is
# printed only if its value was read.
machine; reset envmodel:7b
for v in _oep_x _oep_name _oep_type IFS_MODEL; do
  check "NAME $v: the caller's value is read" "envmodel:7b" \
    "$(export AI_MODEL_TIER=small OLLAMA_PULL_MISSING=0; eval "$v=envmodel:7b"; ai_model_resolve general "$URL" "" "$v" 2>/dev/null </dev/null)"
done
check "more than five arguments: 10, nothing on stdout" "10" "$(ai_model_resolve general "$URL" "" "" tier-m:4b extra 2>/dev/null </dev/null; echo $?)"
check "select with an extra argument: 10, nothing on stdout" "10" "$(bash "$script" select general "$URL" "" "" tier-m:4b extra 2>/dev/null </dev/null; echo $?)"

# --- a tiers file with a byte-order mark before a data line -----------------------------
{ printf '\357\273\277threshold small_below_ram_gb 11\r\n'; grep -v small_below "$tmp/tiers.txt"; } >"$tmp/bom-tiers.txt"
check "a BOM before the first threshold: still read" "small" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/bom-tiers.txt" OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * 1073741824)) ollama_host_tier)"
printf '\357\273\277type solo a:1 b:2 c:3 d:4\n' >"$tmp/bom-type.txt"
check "a BOM before the first type: still listed" "solo" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/bom-type.txt" ollama_model_tier_types)"

# --- one listing of the Ollama per run -------------------------------------------------
machine; no_terminal; reset tier-m:4b envmodel:7b
check "no terminal, both installed: the Ollama is listed once, not twice" "tier-m:4b:1" \
  "$(ai_model_resolve general "$URL" "" "" envmodel:7b 2>/dev/null):$(listings)"
reset tier-m:4b
check "no project model: listed once" "tier-m:4b:1" "$(ai_model_resolve general "$URL" 2>/dev/null):$(listings)"

# --- one rule for both pickers ------------------------------------------------------------
# A models file with the tiers file's thresholds must class every machine as
# ollama_host_tier does; the two read different files through one function.
{ printf 'M=std:1\nM_SMALL=sm:1\nM_LARGE=lg:1\nM_XLARGE=xl:1\n'
  printf 'AI_TIER_SMALL_RAM_GB=%s\nAI_TIER_LARGE_RAM_GB=%s\nM_LARGE_VRAM_GB=%s\nM_XLARGE_VRAM_GB=%s\n' \
    "$(_ollama_ep_tiers_get threshold small_below_ram_gb)" "$(_ollama_ep_tiers_get threshold large_ram_gb)" \
    "$(_ollama_ep_tiers_get threshold large_vram_gb)" "$(_ollama_ep_tiers_get threshold xlarge_vram_gb)"; } >"$tmp/same.env"
drift=""
for mem in 4 10 11 12 29 30 64; do
  for gpu in 0 8 10 11 12 22 23 48; do
    a="$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((mem * GiB)) OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((gpu * GiB)) ollama_host_tier)"
    b="$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((mem * GiB)) OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((gpu * GiB)) ollama_model_for_class "$tmp/same.env" M)"
    case "$a:$b" in small:sm:1|standard:std:1|large:lg:1|xlarge:xl:1) ;; *) drift="$drift $mem/$gpu=$a,$b" ;; esac
  done
done
check "the tiers file and a models file with its numbers agree on every machine" "" "$drift"
# A class whose column names no model is never reached by measuring: the
# lower rules decide, not a fall back from the class above.
printf 'M=std:1\nM_XLARGE_VRAM_GB=23\nM_LARGE=lg:1\nM_LARGE_VRAM_GB=40\n' >"$tmp/nox.env"
check "no xlarge model, a 24 GiB card below the large floor: the default column" "std:1" \
  "$(OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((24 * GiB)) ollama_model_for_class "$tmp/nox.env" M)"
printf 'M=std:1\nM_SMALL=sm:1\nM_LARGE_VRAM_GB=3\nAI_TIER_SMALL_RAM_GB=11\n' >"$tmp/nol.env"
check "no large model, 8 GiB and a 4 GiB card over the large floor: the small column" "sm:1" \
  "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GiB)) OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((4 * GiB)) ollama_model_for_class "$tmp/nol.env" M)"

# --- the tier, the remaining edges ----------------------------------------------------------
machine
check "memory that cannot be read: standard, not a guess" "standard" \
  "$(unset OLLAMA_BUDGET_MEM_TOTAL_BYTES; memory_unreadable; ollama_host_tier)"
check "a card at the large floor (11 GiB) with 8 GiB of memory: large" "large" \
  "$(OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GiB)) OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((11 * GiB)) ollama_host_tier)"
printf 'threshold small_below_ram_gb 11\nthreshold large_vram_gb 16\nthreshold large_ram_gb 30\nthreshold xlarge_vram_gb 23\n' >"$tmp/gap.txt"
check "a small machine with a card between the floors is standard, not small" "standard" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/gap.txt" OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((8 * GiB)) OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ollama_host_tier)"
printf 'threshold large_ram_gb 99\nthreshold large_ram_gb 30\ntype dup a:1 b:1 c:1 d:1\ntype dup e:1 f:1 g:1 h:1\n' >"$tmp/dup.txt"
check "a key given twice: the last line wins" "large:f:1" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/dup.txt" OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((32 * GiB)) ollama_host_tier):$(OLLAMA_MODEL_TIERS_FILE="$tmp/dup.txt" ollama_tier_model dup standard)"
check "and the type is listed once" "dup" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/dup.txt" ollama_model_tier_types)"
check "ollama_tier_model with no data file: 2" "2:" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/none" ollama_tier_model general large 2>/dev/null; echo "$?:")"
check "ollama_tier_model with a bad tier argument: 3" "3:" "$(ollama_tier_model general huge 2>/dev/null; echo "$?:")"
check "ollama_tier_model with a bad AI_MODEL_TIER: 3" "3:" "$(AI_MODEL_TIER=huge ollama_tier_model general 2>/dev/null; echo "$?:")"
printf 'type short a:1 b:2\ntype badref a:1 "x y" c:1 d:1\n' >"$tmp/short.txt"
check "a row with no model for the tier: 2" "2:" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/short.txt" ollama_tier_model short large 2>/dev/null; echo "$?:")"
check "a row whose model is not a model reference: 2" "2:" "$(OLLAMA_MODEL_TIERS_FILE="$tmp/short.txt" ollama_tier_model badref standard 2>/dev/null; echo "$?:")"

# --- storing, the remaining refusals -------------------------------------------------------
printf 'A=1\n' >"$tmp/odd.env"
check "a NAME with no value is refused (1), the file untouched" "1:A=1" "$(_ollama_ep_env_set "$tmp/odd.env" A 2 B; echo "$?:$(one_line <"$tmp/odd.env")")"
check "a value with a line break is refused (1), the file untouched" "1:A=1" "$(_ollama_ep_env_set "$tmp/odd.env" A $'2\nB=3'; echo "$?:$(one_line <"$tmp/odd.env")")"
if [[ "$(id -u)" != "0" ]]; then
  machine; reset tier-m:4b envmodel:7b; mkdir -p "$tmp/ro"; chmod 500 "$tmp/ro"
  check "an answer that cannot be stored: 10, nothing on stdout" "10" \
    "$(terminal; ai_model_resolve general "$URL" "$tmp/ro/.env" "" envmodel:7b <<<"1" 2>/dev/null; echo $?)"
  chmod 700 "$tmp/ro"
  # A directory that is not writable, a file that is: written in place.
  mkdir -p "$tmp/rod"; printf 'OLLAMA_MODEL=envmodel:7b\nOTHER=1\n' >"$tmp/rod/.env"; chmod 640 "$tmp/rod/.env"; chmod 500 "$tmp/rod"
  check "read-only directory, writable .env: the answer is stored in place" "envmodel:7b:envmodel:7b tier-m:4b envmodel:7b 1 640" \
    "$(terminal; reset tier-m:4b envmodel:7b; ai_model_resolve general "$URL" "$tmp/rod/.env" OLLAMA_MODEL <<<"1" 2>/dev/null):$(ollama_models_file_get "$tmp/rod/.env" OLLAMA_MODEL_CHOICE) $(ollama_models_file_get "$tmp/rod/.env" OLLAMA_MODEL_CHOICE_FOR) $(ollama_models_file_get "$tmp/rod/.env" OLLAMA_MODEL_CHOICE_PROJECT) $(ollama_models_file_get "$tmp/rod/.env" OTHER) $( (stat -c %a "$tmp/rod/.env" 2>/dev/null || stat -f %Lp "$tmp/rod/.env") | tr -d '\n')"
  check "and nothing is left behind in the directory" "1" "$(find "$tmp/rod" -mindepth 1 | grep -c .)"
  chmod 700 "$tmp/rod"
  mkdir -p "$tmp/rof"; printf 'A=1\n' >"$tmp/rof/.env"; chmod 400 "$tmp/rof/.env"; chmod 500 "$tmp/rof"
  check "read-only directory and read-only .env: refused (1), untouched" "1:A=1" "$(_ollama_ep_env_set "$tmp/rof/.env" A 2; echo "$?:$(one_line <"$tmp/rof/.env")")"
  chmod 700 "$tmp/rof"
  chmod 500 "$tmp/rod"
  check "read-only directory, no .env yet: refused (1), nothing on stderr" "1:0" \
    "$(_ollama_ep_env_set "$tmp/rod/new.env" A 1 2>"$tmp/err"; echo "$?:$(grep -c . "$tmp/err")")"
  # In place, two writers at once: the lock is under TMPDIR, and both answers stay.
  mkdir -p "$tmp/tdir"; lost=0
  for _ in 1 2 3 4 5 6; do
    chmod 700 "$tmp/rod"; printf 'KEEP=1\n' >"$tmp/rod/.env"; chmod 500 "$tmp/rod"
    TMPDIR="$tmp/tdir" _ollama_ep_env_set "$tmp/rod/.env" A_CHOICE a A_CHOICE_FOR b & p1=$!
    # The second by a relative path: the same file, so the same lock.
    (cd "$tmp" && TMPDIR="$tmp/tdir" _ollama_ep_env_set rod/.env B_CHOICE c B_CHOICE_FOR d) & p2=$!
    wait "$p1" "$p2"
    [[ "$(grep -c -E '^(KEEP|A_CHOICE|A_CHOICE_FOR|B_CHOICE|B_CHOICE_FOR)=' "$tmp/rod/.env")" == 5 ]] || lost=$((lost + 1))
  done
  check "read-only directory, two writers at once: both answers stay" "0" "$lost"
  check "and no lock or temporary file is left under TMPDIR" "" "$(find "$tmp/tdir" -mindepth 1)"
  chmod 700 "$tmp/rod"
fi
# A lock left by a killed run (its owner's pid is gone) is taken over at once.
dead_pid() { sh -c 'echo $$'; }
printf 'A=1\n' >"$tmp/stale.env"; ln -s "$(dead_pid)" "$tmp/.stale.env.lock"
check "a lock whose owner is gone is taken over: written, the lock removed" "A=2:" \
  "$(_ollama_ep_env_set "$tmp/stale.env" A 2; one_line <"$tmp/stale.env"):$(find "$tmp" -maxdepth 1 -name '.stale.env.lock*')"
# Two waiters that both find the dead owner: each answer stays, no lock is left.
lost=0
for _ in 1 2 3 4 5 6; do
  printf 'KEEP=1\n' >"$tmp/stale.env"; ln -s "$(dead_pid)" "$tmp/.stale.env.lock"
  _ollama_ep_env_set "$tmp/stale.env" A_CHOICE a & p1=$!
  _ollama_ep_env_set "$tmp/stale.env" B_CHOICE b & p2=$!
  wait "$p1" "$p2"
  [[ "$(grep -c -E '^(KEEP|A_CHOICE|B_CHOICE)=' "$tmp/stale.env")" == 3 ]] || lost=$((lost + 1))
done
check "two waiters taking over a dead lock at once: both answers stay" "0:" \
  "$lost:$(find "$tmp" -maxdepth 1 -name '.stale.env.lock*')"
# A live owner is waited on, not taken over.
sleep 2 & holder=$!
ln -s "$holder" "$tmp/.stale.env.lock"
( sleep 1; rm -f "$tmp/.stale.env.lock" ) & releaser=$!
t0=$SECONDS; _ollama_ep_env_set "$tmp/stale.env" A_CHOICE z; t1=$SECONDS
wait "$releaser"; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "a live owner's lock is waited on, then the write goes ahead" "yes:z" \
  "$([[ $((t1 - t0)) -ge 1 ]] && echo yes):$(ollama_models_file_get "$tmp/stale.env" A_CHOICE)"
# A live owner of another user (pid 1: kill -0 fails with EPERM) is not dead.
if [[ "$(id -u)" != "0" ]]; then
  ln -s 1 "$tmp/.stale.env.lock"
  ( sleep 1; rm -f "$tmp/.stale.env.lock" ) & releaser=$!
  t0=$SECONDS; _ollama_ep_env_set "$tmp/stale.env" A_CHOICE y; t1=$SECONDS; wait "$releaser"
  check "another user's live process holding the lock is waited on, not taken over" "yes:y" \
    "$([[ $((t1 - t0)) -ge 1 ]] && echo yes):$(ollama_models_file_get "$tmp/stale.env" A_CHOICE)"
fi
mkdir "$tmp/.stale.env.lock"
t0=$SECONDS; _ollama_ep_env_set "$tmp/stale.env" A_CHOICE w; t1=$SECONDS
check "a directory where the lock goes: written at once, the directory left alone and empty" "yes:w:dir:" \
  "$([[ $((t1 - t0)) -le 3 ]] && echo yes):$(ollama_models_file_get "$tmp/stale.env" A_CHOICE):$([[ -d "$tmp/.stale.env.lock" ]] && echo dir):$(ls -A "$tmp/.stale.env.lock")"
rmdir "$tmp/.stale.env.lock"
check "a .env in a directory that does not exist: refused (1) at once, no lock" "1" \
  "$(_ollama_ep_env_set "$tmp/no/such/dir/.env" A 1 2>/dev/null; echo $?)"
# A hard-linked .env: both names keep the same file, both see the answer.
mkdir -p "$tmp/hl/a" "$tmp/hl/b"; printf 'A=1\nB=2\n' >"$tmp/hl/a/.env"; ln "$tmp/hl/a/.env" "$tmp/hl/b/.env"
inode() { ls -i "$1" | awk '{ print $1 }'; }
hl_before="$(inode "$tmp/hl/a/.env")"
mkdir -p "$tmp/td"
TMPDIR="$tmp/td" _ollama_ep_env_set "$tmp/hl/a/.env" A 9 C_CHOICE x
check "and no temporary file is left under TMPDIR" "0" "$(find "$tmp/td" -type f | grep -c .)"
check "a TMPDIR that does not exist: written in place through /tmp" "A=7 B=2 C_CHOICE=x" \
  "$(TMPDIR="$tmp/no-such-dir" _ollama_ep_env_set "$tmp/hl/a/.env" A 7 2>"$tmp/err"; one_line <"$tmp/hl/b/.env")"
check "and nothing on stderr" "0" "$(grep -c . "$tmp/err")"
check "an in-place write that does not read back: refused (1), old content restored" "1:A=7 B=2 C_CHOICE=x" \
  "$(cmp() { return 1; }; _ollama_ep_env_set "$tmp/hl/a/.env" A 8; echo "$?:$(one_line <"$tmp/hl/b/.env")")"
TMPDIR="$tmp/td" _ollama_ep_env_set "$tmp/hl/a/.env" A 9
check "a hard-linked .env: written in place, both links see the same new content" "A=9 B=2 C_CHOICE=x|A=9 B=2 C_CHOICE=x|same|same" \
  "$(one_line <"$tmp/hl/a/.env")|$(one_line <"$tmp/hl/b/.env")|$([[ "$(inode "$tmp/hl/a/.env")" == "$hl_before" ]] && echo same)|$([[ "$(inode "$tmp/hl/b/.env")" == "$hl_before" ]] && echo same)"

# --- the same model, however written --------------------------------------------------------
machine; reset tier-m:4b
check "the env model in another case is the tier's: not asked" "tier-m:4b:0" \
  "$(terminal; OLLAMA_MODEL='Tier-M:4B' ai_model_resolve general "$URL" "" OLLAMA_MODEL </dev/null 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
printf 'type plain plainmodel plainmodel plainmodel plainmodel\n' >"$tmp/plain.txt"
reset plainmodel:latest
check "an omitted :latest is the same model: not asked" "plainmodel:0" \
  "$(terminal; OLLAMA_MODEL_TIERS_FILE="$tmp/plain.txt" ai_model_resolve plain "$URL" "" "" plainmodel:latest </dev/null 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
reset tier-m:4b envmodel:7b
printf 'OLLAMA_MODEL=envmodel:7b\nOLLAMA_MODEL_CHOICE=tier-m:4b\nOLLAMA_MODEL_CHOICE_FOR=tier-m:4b\nOLLAMA_MODEL_CHOICE_PROJECT=envmodel:7b\n' >"$tmp/keep.env"
check "a stored answer of the tier's model stays while the project's model is the one asked about: not asked" "tier-m:4b:0" \
  "$(terminal; ai_model_resolve general "$URL" "$tmp/keep.env" OLLAMA_MODEL </dev/null 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"

reset envmodel:7b
printf 'OLLAMA_MODEL=envmodel:7b\nOLLAMA_MODEL_CHOICE=tier-m:4b\nOLLAMA_MODEL_CHOICE_FOR=tier-m:4b\n' >"$tmp/old.env"
check "an older .env (no _PROJECT), no terminal: the stored tier model is used, not the installed project model" "5:1" \
  "$(no_terminal; OLLAMA_PULL_MISSING=0 ai_model_resolve general "$URL" "$tmp/old.env" OLLAMA_MODEL </dev/null >/dev/null 2>"$tmp/err"; echo "$?:$(grep -c 'as answered before' "$tmp/err")")"

# --- the project's model changes after an answer of the tier's model ----------------------
reset tier-m:4b envmodel:7b newer:4b
stale() { printf 'OLLAMA_MODEL=newer:4b\nOLLAMA_MODEL_CHOICE=tier-m:4b\nOLLAMA_MODEL_CHOICE_FOR=tier-m:4b\nOLLAMA_MODEL_CHOICE_PROJECT=envmodel:7b\n' >"$1"; }
check "answered the tier's model, then the project's model changed: asked again on a terminal" "newer:4b:1" \
  "$(terminal; stale "$tmp/st1.env"; ai_model_resolve general "$URL" "$tmp/st1.env" OLLAMA_MODEL <<<"1" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "and the new project's model is stored with the answer" "newer:4b tier-m:4b newer:4b 1" \
  "$(ollama_models_file_get "$tmp/st1.env" OLLAMA_MODEL_CHOICE) $(ollama_models_file_get "$tmp/st1.env" OLLAMA_MODEL_CHOICE_FOR) $(ollama_models_file_get "$tmp/st1.env" OLLAMA_MODEL_CHOICE_PROJECT) $(grep -c '^OLLAMA_MODEL_CHOICE_PROJECT=' "$tmp/st1.env")"
check "then not asked again" "newer:4b:0" \
  "$(terminal; ai_model_resolve general "$URL" "$tmp/st1.env" OLLAMA_MODEL </dev/null 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "no terminal: the no-terminal order, not the stale answer (only the project's model installed)" "newer:4b:0" \
  "$(no_terminal; reset newer:4b; stale "$tmp/st2.env"; ai_model_resolve general "$URL" "$tmp/st2.env" OLLAMA_MODEL 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "in CI with a terminal: not asked, the no-terminal order" "newer:4b:0" \
  "$(terminal; reset newer:4b; stale "$tmp/st3.env"; CI=true ai_model_resolve general "$URL" "$tmp/st3.env" OLLAMA_MODEL <<<"2" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
reset tier-m:4b envmodel:7b
printf 'OLLAMA_MODEL=envmodel:7b\nOLLAMA_MODEL_CHOICE=tier-m:4b\nOLLAMA_MODEL_CHOICE_FOR=tier-m:4b\n' >"$tmp/old.env"
check "an answer of the tier's model from before _PROJECT, no terminal: used, not asked" "tier-m:4b:0" \
  "$(no_terminal; ai_model_resolve general "$URL" "$tmp/old.env" OLLAMA_MODEL 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "and the file is left as it was" "" "$(ollama_models_file_get "$tmp/old.env" OLLAMA_MODEL_CHOICE_PROJECT)"
reset tier-m:4b envmodel:7b
check "the same file on a terminal: asked once more" "tier-m:4b:1" \
  "$(terminal; ai_model_resolve general "$URL" "$tmp/old.env" OLLAMA_MODEL <<<"2" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "then stored with the project's model, and not asked again" "envmodel:7b tier-m:4b:0" \
  "$(ollama_models_file_get "$tmp/old.env" OLLAMA_MODEL_CHOICE_PROJECT) $(terminal; ai_model_resolve general "$URL" "$tmp/old.env" OLLAMA_MODEL </dev/null 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
printf 'OLLAMA_MODEL=envmodel:7b\nOLLAMA_MODEL_CHOICE=envmodel:7b\nOLLAMA_MODEL_CHOICE_FOR=tier-m:4b\n' >"$tmp/old2.env"
check "an answer of the project's model from before _PROJECT: still holds, not asked" "envmodel:7b:0" \
  "$(terminal; ai_model_resolve general "$URL" "$tmp/old2.env" OLLAMA_MODEL </dev/null 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"

# --- what the project's model is ----------------------------------------------------------
machine; no_terminal; reset envmodel:7b
check "spaces around the env model are trimmed" "envmodel:7b" \
  "$(OLLAMA_MODEL='  envmodel:7b ' ai_model_resolve general "$URL" "" OLLAMA_MODEL 2>/dev/null)"
check "spaces around the default model are trimmed" "envmodel:7b" \
  "$(ai_model_resolve general "$URL" "" "" ' envmodel:7b  ' 2>/dev/null)"
reset newer:4b
check "the environment wins over the env file" "newer:4b" \
  "$(printf 'OLLAMA_MODEL=envmodel:7b\n' >"$tmp/e4"; OLLAMA_MODEL=newer:4b ai_model_resolve general "$URL" "$tmp/e4" OLLAMA_MODEL 2>/dev/null)"
check "an empty address: 10, nothing on stdout" "10" "$(ai_model_resolve general "" 2>/dev/null; echo $?)"
check "no terminal, the two differ, no Ollama: 4" "4" "$(ai_model_resolve general http://127.0.0.1:1/ "" "" envmodel:7b 2>"$tmp/err"; echo $?)"
said "the address is named without its trailing slash" "$tmp/err" "No Ollama answers at http://127.0.0.1:1."

# --- answers ----------------------------------------------------------------------------
machine; reset tier-m:4b envmodel:7b
check "an empty answer is the default at once, not asked again" "tier-m:4b:0" \
  "$(terminal; ai_model_resolve general "$URL" "" "" envmodel:7b <<<"" 2>"$tmp/err"):$(grep -c 'answer 1 or 2' "$tmp/err")"
check "an answer with spaces is read" "envmodel:7b" \
  "$(terminal; ai_model_resolve general "$URL" "" "" envmodel:7b <<<" 1 " 2>/dev/null)"
check "CI=0 with a terminal: asked" "envmodel:7b:1" \
  "$(terminal; CI=0 ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"
check "CI=FALSE with a terminal: asked" "envmodel:7b:1" \
  "$(terminal; CI=FALSE ai_model_resolve general "$URL" "" "" envmodel:7b <<<"1" 2>"$tmp/err"):$(grep -c 'Choose' "$tmp/err")"

# --- a remote Ollama ----------------------------------------------------------------------
machine; reset
check "a remote Ollama with stated memory, no stated GPU: this machine's GPU is not counted" "tier-m:4b" \
  "$(reset tier-m:4b tier-x:20b; remote; unset OLLAMA_BUDGET_GPU_LARGEST_BYTES; local_gpu_24
     OLLAMA_BUDGET_MEM_TOTAL_BYTES=$((16 * GiB)) ai_model_resolve general "$URL" 2>/dev/null)"
# Free disk is known here only at "/": a local models directory would be unreadable (7).
check "a remote Ollama: the disk is read at /, not this machine's models directory" "0:tier-m:4b" \
  "$(reset; remote; unset OLLAMA_BUDGET_DISK_FREE_BYTES; disk_known_at_root_only
     OLLAMA_PULL_MISSING=1 ai_model_resolve general "$URL" >/dev/null 2>&1; echo "$?:$(pulled)")"

# --- per-model floors (size lines) ---------------------------------------------------------
# A large or xlarge cell may name a model a host of that tier cannot hold (the
# large tier starts at an 11 GiB card). A size line gives the model's floor; a
# host under it gets the next lower tier's model for that type.
cat >"$tmp/floors.txt" <<'EOF'
threshold small_below_ram_gb 11
threshold large_ram_gb 30
threshold large_vram_gb 11
threshold xlarge_vram_gb 23
type reasoning  r-s:4b  r-m:8b  r-l:26b  r-x:27b
type code       c-s:4b  c-m:7b  c-l:30b  c-x:27b
size r-l:26b large  19 30
size c-l:30b large  19 30
size r-x:27b xlarge 23 -
size c-x:27b xlarge 23 -
EOF
pick() { # pick <type> <mem GiB> <gpu GiB> [file; empty: the shipped one]
  OLLAMA_MODEL_TIERS_FILE="${4-$tmp/floors.txt}" OLLAMA_BUDGET_MEM_TOTAL_BYTES=$(($2 * GiB)) \
    OLLAMA_BUDGET_GPU_LARGEST_BYTES=$(($3 * GiB)) ollama_tier_model "$1" 2>/dev/null
}
machine
check "a 12 GB card (large tier) under the 19 GiB floor: the standard pick" "r-m:8b c-m:7b" "$(pick reasoning 16 12) $(pick code 16 12)"
check "a 24 GB card: the xlarge picks" "r-x:27b c-x:27b" "$(pick reasoning 16 24) $(pick code 16 24)"
check "32 GiB memory, no GPU: the large picks, on the CPU" "r-l:26b c-l:30b" "$(pick reasoning 32 0) $(pick code 32 0)"
check "a 20 GB card: large (19 GiB floor met, under xlarge)" "c-l:30b" "$(pick code 16 20)"
check "a 23 GB card: xlarge" "c-x:27b" "$(pick code 16 23)"
check "16 GiB, no GPU: standard, no floor involved" "c-m:7b" "$(pick code 16 0)"
check "a stated tier is used as stated, floors not applied" "c-l:30b" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/floors.txt" OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) AI_MODEL_TIER=large ollama_tier_model code)"
check "select on a 12 GB card prints the standard pick" "c-m:7b" \
  "$(reset c-m:7b; OLLAMA_MODEL_TIERS_FILE="$tmp/floors.txt" OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ai_model_resolve code "$URL" 2>/dev/null)"
check "with no terminal and neither model, the message names the tier actually used" "12" \
  "$(reset; OLLAMA_PULL_MISSING=0 OLLAMA_MODEL_TIERS_FILE="$tmp/floors.txt" OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ai_model_resolve code "$URL" "" "" other:1b 2>"$tmp/err" </dev/null; echo "$?")"
said "the standard tier, not large" "$tmp/err" "c-m:7b (approved for the standard tier)"
grep -v '^size' "$tmp/floors.txt" >"$tmp/old.txt"
check "a file with no size lines (old format): the tier's model, as before" "c-l:30b c-x:27b" \
  "$(pick code 16 12 "$tmp/old.txt") $(pick code 16 24 "$tmp/old.txt")"
{ cat "$tmp/old.txt"; echo 'size c-l:30b large 19GB 30'; } >"$tmp/badsize.txt"
check "a size line with a bad floor: 2" "2:" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/badsize.txt" OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ollama_tier_model code 2>"$tmp/err"; echo "$?:")"
said "the error names the model and the value" "$tmp/err" "c-l:30b" "19GB"
check "so select stops (10)" "10" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/badsize.txt" OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ai_model_resolve code "$URL" 2>/dev/null; echo "$?")"
{ cat "$tmp/old.txt"; echo 'size c-l:30b huge 19 30'; } >"$tmp/badclass.txt"
check "a size line with an unknown class: 2" "2" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/badclass.txt" OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ollama_tier_model code 2>/dev/null; echo "$?")"
{ cat "$tmp/old.txt"; echo 'size c-l:30b large 19'; } >"$tmp/shortsize.txt"
check "a size line with a missing field: 2" "2" \
  "$(OLLAMA_MODEL_TIERS_FILE="$tmp/shortsize.txt" OLLAMA_BUDGET_GPU_LARGEST_BYTES=$((12 * GiB)) ollama_tier_model code 2>/dev/null; echo "$?")"

# --- the checker -----------------------------------------------------------------------------
checker=scripts/ollama_tiers_check.sh
check "the shipped tiers file passes the checker" "0" "$(OLLAMA_MODEL_TIERS_FILE='' bash "$checker" >/dev/null 2>&1; echo $?)"
check "the floors test file passes" "0" "$(bash "$checker" "$tmp/floors.txt" >/dev/null 2>&1; echo $?)"
check "an old-format file passes" "0" "$(bash "$checker" "$tmp/old.txt" >/dev/null 2>&1; echo $?)"
sed 's/^type code .*/type code c-s:4b c-m:7b c-x:27b c-x:27b/' "$tmp/floors.txt" >"$tmp/toobig.txt"
check "an xlarge-class model in a large cell is refused (1)" "1" "$(bash "$checker" "$tmp/toobig.txt" 2>"$tmp/err" >/dev/null; echo $?)"
said "naming the type, tier and model" "$tmp/err" "code" "large" "c-x:27b"
sed 's/^size c-l:30b large  19 30/size c-l:30b large 9 30/' "$tmp/floors.txt" >"$tmp/lowfloor.txt"
check "a large-class GPU floor under the large threshold is refused (1)" "1" "$(bash "$checker" "$tmp/lowfloor.txt" >/dev/null 2>&1; echo $?)"
sed 's/^size c-l:30b large  19 30/size c-l:30b large 25 -/' "$tmp/floors.txt" >"$tmp/highfloor.txt"
check "a large-class GPU floor at or above the xlarge threshold is refused (1)" "1" "$(bash "$checker" "$tmp/highfloor.txt" >/dev/null 2>&1; echo $?)"
{ cat "$tmp/floors.txt"; echo 'size c-x2:14b large 15 -'; echo 'type code2 c-s:4b c-m:7b c-l:30b c-x2:14b'; } >"$tmp/order.txt"
check "two models of one class in a row: the higher tier needing less is refused (1)" "1" "$(bash "$checker" "$tmp/order.txt" 2>"$tmp/err" >/dev/null; echo $?)"
said "naming both models" "$tmp/err" "c-l:30b" "c-x2:14b"
{ cat "$tmp/floors.txt"; echo 'size c-x3:14b xlarge 23 -'; echo 'type code3 c-s:4b c-m:7b c-l:30b c-x3:14b'; } >"$tmp/classes.txt"
check "models of different classes are not compared" "0" "$(bash "$checker" "$tmp/classes.txt" >/dev/null 2>&1; echo $?)"
check "a malformed size line is refused (1)" "1" "$(bash "$checker" "$tmp/badsize.txt" >/dev/null 2>&1; echo $?)"
check "a missing file: 2" "2" "$(bash "$checker" "$tmp/none" >/dev/null 2>&1; echo $?)"
check "--help: 0" "0" "$(bash "$checker" --help >/dev/null 2>&1; echo $?)"
check "the shipped code and reasoning rows are the approved ones" \
  "qwen3.5:4b qwen3:8b gemma4:26b qwen3.6:27b|qwen3.5:4b qwen2.5-coder:7b qwen3-coder:30b qwen3.6:27b-coding" \
  "$(OLLAMA_MODEL_TIERS_FILE='' _ollama_ep_tiers_get type reasoning)|$(OLLAMA_MODEL_TIERS_FILE='' _ollama_ep_tiers_get type code)"
check "with the shipped file: a 12 GB card gets the standard code and reasoning picks" "qwen2.5-coder:7b qwen3:8b" \
  "$(pick code 16 12 '') $(pick reasoning 16 12 '')"
check "with the shipped file: a 24 GB card the xlarge ones, 32 GiB no GPU the large ones" \
  "qwen3.6:27b-coding qwen3.6:27b qwen3-coder:30b gemma4:26b" \
  "$(pick code 16 24 '') $(pick reasoning 16 24 '') $(pick code 32 0 '') $(pick reasoning 32 0 '')"

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "all passed"
