#!/usr/bin/env bash
# SCRIPT: dev_service_verbs_test.sh
# DESCRIPTION: ./dev start, stop, restart, status, logs and a repository's own verbs (templates/dev-cli).
# USAGE: bash tests/dev_service_verbs_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_service_verbs_test.sh
# ----------------------------------------------------
# A scratch repository gets the template, and lib/service.sh does the work:
# a native process (python3's http.server) and a compose stack (a stand-in
# docker that records its calls). Each is driven through ./dev and through the
# root shims install_dev_cli.sh writes.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[dev_service_verbs_test]   ok  $*"; }
error() { echo "[dev_service_verbs_test][ERROR] $*" >&2; failures=$((failures+1)); }
check() { if [[ "$2" == "$3" ]]; then note "$1"; else error "$1: expected [$2], got [$3]"; fi; }
said() { # said <description> <text> <expected substring>...
  local d="$1" t="$2"; shift 2
  for x in "$@"; do [[ "$t" == *"$x"* ]] || { error "$d: '$x' not in: $t"; return; }; done
  note "$d"
}

for tool in git python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "[dev_service_verbs_test] SKIP: $tool not available"; exit 0; }
done

tmp="$(mktemp -d)"
cleanup() {
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  [[ -d "$tmp/proc" ]] && (cd "$tmp/proc" && ./dev stop >/dev/null 2>&1)
  rm -rf "$tmp"
}
trap cleanup EXIT

new_repo() { # new_repo <name>; the template installed with the service shims
  local repo="$tmp/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q .
  bash scripts/install_dev_cli.sh --repo "$repo" --shims service --no-hooks >/dev/null 2>&1 \
    || { error "install_dev_cli.sh into $1 failed"; return 1; }
  rm -rf "$repo/scripts/script-helpers"
  ln -s "$ROOT_DIR" "$repo/scripts/script-helpers"
  printf '%s\n' "$repo"
}
run() { (cd "$1" && shift && "$@" </dev/null 2>&1); }

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"

# --- native processes ----------------------------------------------------------
repo="$(new_repo proc)" || exit 1
cat >"$repo/scripts/project.sh" <<EOF
SVC_BACKEND=proc
SVC_PROCS=("web:python3 -m http.server \${WEB_PORT:-$port} --bind 127.0.0.1")
SVC_PORTS=("WEB_PORT:\${WEB_PORT:-$port}")
SVC_HEALTH_URL="http://127.0.0.1:\${WEB_PORT:-$port}/"
SVC_URLS=("Web http://127.0.0.1:\${WEB_PORT:-$port}/")
SVC_READY_TIMEOUT=120
SVC_LOGS_FOLLOW=0
project_hello() { echo "hello: \$*"; }
project_user_add() { echo "user-add: \$*"; }
EOF

for shim in start stop restart status logs; do
  [[ -x "$repo/$shim" ]] || error "the installer did not write the $shim shim"
done
check "a service shim says it is kept, not that it will be removed" 1 "$(grep -c '^# Service shim. Use ./dev start -- kept' "$repo/start")"
out="$(bash scripts/install_dev_cli.sh --repo "$repo" --shims service --no-hooks 2>&1)"; rc=$?
check "installing again over its own service shims: 0" 0 "$rc"
check "recognises them as its own (no warning, no backup)" "0:0" "$(printf '%s' "$out" | grep -c 'not a shim we wrote'):$(ls "$repo" | grep -c 'pre-dev-cli')"

out="$(run "$repo" ./dev start)"; rc=$?
check "./dev start starts the service and waits until it is ready" 0 "$rc"
said "and prints its URL" "$out" "Web: http://127.0.0.1:$port/"
out="$(run "$repo" ./start)"; rc=$?
check "the start shim, a second time: already running, exit 0" 0 "$rc"
said "and says so" "$out" "web is already running"
out="$(run "$repo" ./dev status)"; rc=$?
check "./dev status while running: 0" 0 "$rc"
said "it shows the process, the port and health" "$out" "web: running" "port $port: listening" "health http://127.0.0.1:$port/: ok"
out="$(run "$repo" ./status)"; rc=$?
check "the status shim answers the same" 0 "$rc"
out="$(run "$repo" ./dev logs web)"; rc=$?
check "./dev logs web, a name that is also a target word" 0 "$rc"
said "shows that service's log" "$out" "GET / HTTP"
out="$(run "$repo" ./restart)"; rc=$?
check "the restart shim stops and starts again" 0 "$rc"
out="$(run "$repo" ./stop)"; rc=$?
check "the stop shim stops it" 0 "$rc"
out="$(run "$repo" ./dev stop)"; rc=$?
check "./dev stop with nothing running is not an error" 0 "$rc"
out="$(run "$repo" ./dev status)"; rc=$?
check "./dev status once stopped: 1" 1 "$rc"

# --- the repository's own verbs -----------------------------------------------
out="$(run "$repo" ./dev hello a --b "c d")"; rc=$?
check "./dev hello runs project_hello" 0 "$rc"
check "with its arguments as typed, options included" "hello: a --b c d" "$out"
out="$(run "$repo" ./dev user-add bob --admin)"
check "a verb with a dash runs project_user_add" "user-add: bob --admin" "$out"
out="$(run "$repo" ./dev --help)"
said "--help lists the repository's own verbs" "$out" "This repository (scripts/project.sh)" "  hello" "  user-add"
out="$(run "$repo" ./dev)"; rc=$?
check "./dev alone shows the verbs and exits 0" 0 "$rc"
out="$(run "$repo" ./dev bogus)"; rc=$?
check "./dev bogus exits 2" 2 "$rc"
said "and shows the verbs" "$out" "Unknown verb: bogus" "Services"

# --- compose, through a stand-in docker ------------------------------------------
crepo="$(new_repo compose)" || exit 1
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$*" in
  info*|"compose version"*) exit 0 ;;
  *" ps -q"*) [[ -f "$DOCKER_STATE" ]] && echo abc123; exit 0 ;;
  *" up -d"*) : >"$DOCKER_STATE"; exit 0 ;;
  *" down"*|*" stop"*) rm -f "$DOCKER_STATE"; exit 0 ;;
  *" ps"*) [[ -f "$DOCKER_STATE" ]] && echo "web  running"; exit 0 ;;
  *" logs"*) echo "web-1 | hello from compose"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/docker"
export DOCKER_LOG="$tmp/docker.log" DOCKER_STATE="$tmp/docker.up"
printf 'services: {}\n' >"$crepo/compose.yml"
cat >"$crepo/scripts/project.sh" <<'EOF'
SVC_BACKEND=compose
SVC_COMPOSE_FILES=(compose.yml)
SVC_COMPOSE_PROJECT=verbs
SVC_LOGS_FOLLOW=0
EOF
crun() { (cd "$crepo" && PATH="$tmp/bin:$PATH" "$@" </dev/null 2>&1); }
out="$(crun ./dev start)"; rc=$?
check "compose: ./dev start" 0 "$rc"
check "runs compose up -d with the files and project" 1 "$(grep -c -- "-f compose.yml -p verbs up -d" "$DOCKER_LOG")"
out="$(crun ./status)"; rc=$?
check "compose: the status shim, while up" 0 "$rc"
out="$(crun ./logs)"; rc=$?
said "compose: the logs shim shows the stack's logs" "$out" "hello from compose"
out="$(crun ./dev stop)"; rc=$?
check "compose: ./dev stop" 0 "$rc"
check "runs compose down" 1 "$(grep -c -- "-p verbs down" "$DOCKER_LOG")"

# --- no services declared: not applicable, exit 3 ---------------------------------
nrepo="$(new_repo none)" || exit 1
for verb in start restart status; do
  out="$(run "$nrepo" ./dev "$verb")"; rc=$?
  check "./dev $verb with no services is not applicable (3)" 3 "$rc"
  said "and says what to set" "$out" "$verb: not applicable" "SVC_BACKEND"
done
out="$(run "$nrepo" ./dev stop)"; rc=$?
check "./dev stop with no services and no compose file: 3" 3 "$rc"

# status still reports a service's own status payload when only that is set.
printf '{"ok":true}\n' >"$tmp/status.json"
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$tmp" >"$tmp/sp.log" 2>&1 &
sp=$!
# Up to 60 s: python3 starts slowly on a macOS runner (measured >20 s there).
for _ in $(seq 1 120); do sport="$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$tmp/sp.log" | head -1)"; [[ -n "$sport" ]] && break; sleep 0.5; done
printf 'SVC_STATUS_URL="http://127.0.0.1:%s/status.json"\n' "$sport" >"$nrepo/scripts/project.sh"
out="$(run "$nrepo" ./dev status)"; rc=$?
check "status with only SVC_STATUS_URL prints the payload" "0:{\"ok\":true}" "$rc:$(printf '%s' "$out" | grep -o '{"ok":true}')"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null

# logs android stays device logs even where services are declared.
mkdir -p "$tmp/adbbin"
printf '#!/usr/bin/env bash\ncase "$*" in devices*) printf "List of devices attached\\nSER123\\tdevice\\n" ;; *logcat*) echo "device log line" ;; esac\n' >"$tmp/adbbin/adb"
chmod +x "$tmp/adbbin/adb"
out="$(cd "$repo" && PATH="$tmp/adbbin:$PATH" ./dev logs android </dev/null 2>&1)"
said "logs android streams the device log, not the service's" "$out" "device log line"

if [[ $failures -eq 0 ]]; then
  echo "[dev_service_verbs_test] ALL PASSED"
else
  echo "[dev_service_verbs_test] FAILED: $failures"
  exit 1
fi
