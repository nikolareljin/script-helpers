#!/usr/bin/env bash
# SCRIPT: service_test.sh
# DESCRIPTION: Tests for lib/service.sh -- start, stop, status and readiness for compose and native processes.
# USAGE: ./tests/service_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/service_test.sh
# ----------------------------------------------------
#
# Native processes run for real in a temporary repository root. Compose is
# faked by a `docker` stub on PATH that records each call, so no Docker is
# needed. Ports are taken by a small Python listener on 127.0.0.1.
# ----------------------------------------------------
# The SVC_* variables are read by lib/service.sh, which shellcheck does not follow.
# shellcheck disable=SC2034
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[service_test] $*"; }
error() { echo "[service_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[service_test]   ok  $*"; }
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
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

tmp="$(mktemp -d)"
listener_pid=""; other=""
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  [[ -n "$listener_pid" ]] && kill "$listener_pid" 2>/dev/null
  [[ -n "$other" ]] && kill "$other" 2>/dev/null
  local f p
  for f in "$tmp"/repo/.run/*.pid; do
    [[ -f "$f" ]] || continue
    p="$(cat "$f")"; [[ -n "$p" ]] && kill -KILL -- "-$p" 2>/dev/null
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging service

mkdir -p "$tmp/repo"
export SVC_ROOT="$tmp/repo"
out="$tmp/out"

proc_setup() {
  SVC_BACKEND=proc
  SVC_PROCS=("$@")
  SVC_PORTS=(); SVC_URLS=(); SVC_HEALTH_URL=""
  SVC_STOP_TIMEOUT=5; SVC_READY_TIMEOUT=5
}

# --- usage -------------------------------------------------------------------
unset SVC_BACKEND
svc_start >"$out" 2>&1; check "SVC_BACKEND unset is a usage error" 2 $?
SVC_BACKEND=systemd
svc_stop >"$out" 2>&1; check "unknown SVC_BACKEND is a usage error" 2 $?
proc_setup
svc_start >"$out" 2>&1; check "empty SVC_PROCS is a usage error" 2 $?
proc_setup "../evil:sleep 1"
svc_start >"$out" 2>&1; check "a name with a slash is refused" 2 $?
proc_setup "a:sleep 1" "a:sleep 2"
svc_start >"$out" 2>&1; check "a duplicate name is refused" 2 $?
proc_setup "a:sleep 1"; SVC_STOP_TIMEOUT=abc
svc_stop >"$out" 2>&1; check "a non-numeric timeout is refused" 2 $?

# --- proc: start, start again, stop -------------------------------------------
run_lifecycle() { # run_lifecycle <detach method>
  local how="$1" pid
  _SVC_DETACH="$how"
  # A duration no other process on this machine is likely to use.
  local nap=$((40000 + $$ % 10000))
  proc_setup "web:sleep $nap"
  svc_start >"$out" 2>&1; check "[$how] start exits 0" 0 $?
  pid="$(cat "$SVC_ROOT/.run/web.pid" 2>/dev/null)"
  check "[$how] pid recorded and alive" yes "$(alive "${pid:-0}")"
  svc_start >"$out" 2>&1; check "[$how] second start exits 0" 0 $?
  said "[$how] second start says it is running" "$out" "already running (pid $pid)"
  check "[$how] start twice leaves one process" 1 "$(pgrep -f "^sleep $nap\$" | grep -c .)"
  svc_status >"$out" 2>&1; check "[$how] status of a running proc exits 0" 0 $?
  said "[$how] status names the pid" "$out" "web: running (pid $pid)"
  svc_stop >"$out" 2>&1; check "[$how] stop exits 0" 0 $?
  check "[$how] process gone after stop" no "$(alive "$pid")"
  check "[$how] pidfile removed" no "$([[ -e "$SVC_ROOT/.run/web.pid" ]] && echo yes || echo no)"
  svc_status >"$out" 2>&1; check "[$how] status of a stopped proc exits 1" 1 $?
  unset _SVC_DETACH
}
for how in setsid perl; do
  if command -v "$how" >/dev/null 2>&1; then run_lifecycle "$how"; else note "SKIP $how path: no $how"; fi
done

# A caller with job control (an interactive shell) already makes the job a
# group leader, where setsid() fails; the process must still get its own session.
for how in setsid perl; do
  command -v "$how" >/dev/null 2>&1 || continue
  sid="$(bash -c '
    set -m
    source ./helpers.sh; shlib_import logging service
    SVC_BACKEND=proc; _SVC_DETACH="$1"; SVC_PROCS=("jc:sleep 300")
    svc_start >/dev/null 2>&1 || exit 1
    p="$(cat "$SVC_ROOT/.run/jc.pid")"
    # /proc first: BusyBox ps has no -p. macOS ps has no sid keyword (its sess
    # is a kernel address), so there getsid(2) is asked through python3.
    if [[ -r "/proc/$p/stat" ]]; then
      s="$(cat "/proc/$p/stat")"; s="${s##*) }"; s="$(echo "$s" | awk "{ print \$4 }")"
    else
      s="$(python3 -c "import os,sys; print(os.getsid(int(sys.argv[1])))" "$p" 2>/dev/null)"
    fi
    svc_stop >/dev/null 2>&1
    [[ "$s" == "$p" ]] && echo own || echo "pid $p sid $s"' x "$how" 2>/dev/null)"
  check "[$how] own session under job control" own "$sid"
done

proc_setup "web:sleep 300"
svc_stop >"$out" 2>&1; check "stop with nothing running exits 0" 0 $?
said "stop with nothing running says so" "$out" "web is not running"

# --- stale pidfiles ---------------------------------------------------------
mkdir -p "$SVC_ROOT/.run"
( exit 0 ) & dead=$!; sleep 0.3
echo "$dead" >"$SVC_ROOT/.run/web.pid"
svc_stop >"$out" 2>&1; check "stop with a stale pidfile exits 0" 0 $?
said "stale pidfile is reported" "$out" "removed stale pidfile"
check "stale pidfile is removed" no "$([[ -e "$SVC_ROOT/.run/web.pid" ]] && echo yes || echo no)"

# A pidfile naming an unrelated live process group must not be signalled.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import os, time; os.setsid(); time.sleep(300)' &
  other=$!; sleep 0.5
  echo "$other" >"$SVC_ROOT/.run/web.pid"; echo "not-this-one" >"$SVC_ROOT/.run/web.started"
  svc_stop >"$out" 2>&1; check "stop with a reused pid exits 0" 0 $?
  said "reused pid is reported" "$out" "is now another process"
  check "unrelated process left alive" yes "$(alive "$other")"
  echo "$other" >"$SVC_ROOT/.run/web.pid"; rm -f "$SVC_ROOT/.run/web.started"
  svc_stop >"$out" 2>&1
  said "pidfile without a start record is reported" "$out" "no start record"
  check "pidfile without a start record leaves pid alone" yes "$(alive "$other")"
  kill "$other" 2>/dev/null; other=""
else
  note "SKIP reused pid: no python3"
fi

# --- a child is stopped with its parent ---------------------------------------
proc_setup "tree:sleep 301 & echo \$! >'$tmp/child.pid'; sleep 302"
svc_start >"$out" 2>&1; check "start of a process with a child exits 0" 0 $?
leader="$(cat "$SVC_ROOT/.run/tree.pid")"; child="$(cat "$tmp/child.pid" 2>/dev/null)"
check "child is running" yes "$(alive "${child:-0}")"
svc_stop >"$out" 2>&1
check "leader gone after stop" no "$(alive "$leader")"
check "child gone after stop" no "$(alive "${child:-0}")"
check "no sleep 301/302 left (pgrep)" 0 "$(pgrep -f '^sleep 30[12]$' | grep -c .)"

# A process that ignores TERM is killed after SVC_STOP_TIMEOUT.
proc_setup "stubborn:trap '' TERM; while :; do sleep 0.2; done"; SVC_STOP_TIMEOUT=1
svc_start >"$out" 2>&1
pid="$(cat "$SVC_ROOT/.run/stubborn.pid")"
svc_stop >"$out" 2>&1; check "stop of a TERM-ignoring process exits 0" 0 $?
said "KILL is reported" "$out" "sending KILL"
check "TERM-ignoring process gone" no "$(alive "$pid")"

# --- quoting, and a command that exits at once -------------------------------
proc_setup "q.1:printf '%s|%s\n' \"a b\" 'c \"d\"'; sleep 300"
svc_start >"$out" 2>&1
sleep 0.3
said "quotes and spaces reach the command intact" "$SVC_ROOT/.run/q.1.log" 'a b|c "d"'
svc_stop >"$out" 2>&1
proc_setup "quick:echo bye-now; exit 3"
svc_start >"$out" 2>&1; check "a command that exits at once fails start" 1 $?
said "its log is shown" "$out" "bye-now"

# --- health timeout -----------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  proc_setup "slow:for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45; do echo boot-\$i; done; sleep 300"
  SVC_HEALTH_URL="http://127.0.0.1:9/health"; SVC_READY_TIMEOUT=2
  svc_start >"$out" 2>&1; check "health timeout exits 1" 1 $?
  said "timeout prints the log tail" "$out" "not ready after 2s" "boot-45" "boot-6"
  if grep -qx 'boot-5' "$out"; then error "log tail is longer than 40 lines"; else ok "log tail is 40 lines"; fi
  svc_stop >/dev/null 2>&1
  proc_setup "crash:echo crash-now; exit 1"
  SVC_HEALTH_URL="http://127.0.0.1:9/health"; SVC_READY_TIMEOUT=60
  t0=$SECONDS
  svc_start >"$out" 2>&1; check "a crash during the readiness wait exits 1" 1 $?
  said "the crash is reported with its log" "$out" "every process exited" "crash-now"
  if (( SECONDS - t0 < 10 )); then ok "a crash does not wait out the timeout"; else error "a crash waited $((SECONDS - t0))s"; fi
else
  note "SKIP health timeout: no curl"
fi

# --- a taken port refuses start ---------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(300)' "$tmp/port" &
  listener_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$tmp/port" ]] && break; sleep 0.2; done
  port="$(cat "$tmp/port")"
  proc_setup "web:sleep 300"; SVC_PORTS=("$port")
  svc_start >"$out" 2>&1; check "a taken port refuses start" 1 $?
  said "the refusal names the port" "$out" "port $port is already in use by"
  if port_in_use_by "$port" >/dev/null 2>&1; then
    # By PID: the command name differs by OS ("python3", "Python" from macOS lsof).
    said "the refusal names the owner" "$out" "PID $listener_pid"
  else
    note "SKIP owner name: no lsof/ss/netstat that sees it"
  fi
  check "nothing was started" no "$([[ -e "$SVC_ROOT/.run/web.pid" ]] && echo yes || echo no)"
  said "and says what to do about it" "$out" "stop that process, or move the service to a free port"
  SVC_PORTS=("WEB_PORT:$port")
  svc_start >"$out" 2>&1; check "a taken NAME:port refuses start" 1 $?
  said "naming the setting to change" "$out" "port $port (WEB_PORT) is already in use" "set WEB_PORT to a free port" "is free) in .env or the environment"
  SVC_PORTS=("WEB-PORT:$port")
  svc_start >"$out" 2>&1; check "a NAME that is not a variable name is usage (2)" 2 $?
  for bad in PATH LD_PRELOAD SVC_ROOT; do
    SVC_PORTS=("$bad:$port")
    svc_start >"$out" 2>&1; check "NAME $bad, which a taken port would overwrite, is usage (2)" 2 $?
  done
  SVC_PORTS=("$port")

  # On a terminal (stood in for), a taken NAME:port is asked about; the answer
  # is what the process gets, and the URLs follow it.
  real_can_ask="$(declare -f _ports__can_ask)"
  _ports__can_ask() { return 0; }
  proc_setup 'web:echo "$WEB_PORT" >"$SVC_ROOT/.run/got"; sleep 300'
  SVC_PORTS=("WEB_PORT:$port"); SVC_URLS=("Web http://127.0.0.1:$port/")
  SVC_HEALTH_URL=""
  export SVC_ROOT
  svc_start <<<"" >"$out" 2>&1; check "a taken NAME:port on a terminal: Enter takes the suggested port, and start goes on" 0 $?
  newp="$(cat "$SVC_ROOT/.run/got" 2>/dev/null)"
  check "the process got the new port through WEB_PORT" "yes" "$([[ "$newp" =~ ^[0-9]+$ && "$newp" != "$port" ]] && echo yes || echo no)"
  said "the URLs follow it" "$out" "http://127.0.0.1:$newp/"
  said "not saved when the answer is no (here: none), and it says how to keep it" "$out" "for this start only; set WEB_PORT=$newp in .env to keep it"
  check "and .env is untouched" no "$([[ -e "$SVC_ROOT/.env" ]] && echo yes || echo no)"
  check "SVC_PORTS follows it too" "WEB_PORT:$newp" "${SVC_PORTS[0]}"
  svc_stop >/dev/null 2>&1
  proc_setup 'web:sleep 300'; SVC_PORTS=("WEB_PORT:$port")
  printf '\n\n' | svc_start >"$out" 2>&1; check "Enter twice: the suggested port, and saved" 0 $?
  check "saved in the repository's .env" "WEB_PORT=" "$(grep -o '^WEB_PORT=' "$SVC_ROOT/.env" 2>/dev/null)"
  said "and it says so" "$out" "saved WEB_PORT="
  svc_stop >/dev/null 2>&1; rm -f "$SVC_ROOT/.env"
  proc_setup "web:sleep 300"; SVC_PORTS=("$port")
  svc_start <<<"" >"$out" 2>&1; check "a bare port on a terminal cannot be moved: refused" 1 $?
  proc_setup "web:sleep 300"; SVC_PORTS=("WEB_PORT:$port")
  svc_start </dev/null >"$out" 2>&1; check "no answer to the question: refused" 1 $?
  check "and nothing was started" no "$([[ -e "$SVC_ROOT/.run/web.pid" ]] && echo yes || echo no)"
  eval "$real_can_ask"
  kill "$listener_pid" 2>/dev/null; listener_pid=""
else
  note "SKIP taken port: no python3"
fi

# --- no curl, with a health URL: refused before anything starts --------------
proc_setup "web:sleep 300"; SVC_HEALTH_URL="http://127.0.0.1:1/health"
mkdir -p "$tmp/nocurl"; for t in bash sh cat head mkdir rm sleep awk sed ps tr date mv perl setsid git dirname basename; do
  w="$(command -v "$t" 2>/dev/null)" && ln -sf "$w" "$tmp/nocurl/$t"; done
( PATH="$tmp/nocurl"; svc_start ) >"$out" 2>&1; check "no curl with SVC_HEALTH_URL refuses start" 1 $?
said "saying what is needed" "$out" "curl is needed to check SVC_HEALTH_URL"
check "and nothing was started" no "$([[ -e "$SVC_ROOT/.run/web.pid" ]] && echo yes || echo no)"
SVC_HEALTH_URL=""

# --- compose, with a stub docker --------------------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >>"$DOCKER_CALLS"
case "$1" in
  info) [[ -n "${DOCKER_DOWN:-}" ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }; exit 0 ;;
esac
exit 0
SH
chmod +x "$tmp/bin/docker"
export DOCKER_CALLS="$tmp/calls"
PATH="$tmp/bin:$PATH"
SVC_BACKEND=compose
SVC_COMPOSE_FILES=("compose.yml" "compose dev.yml"); SVC_COMPOSE_PROJECT=demo
SVC_PORTS=(); SVC_HEALTH_URL=""; SVC_URLS=("Web UI http://localhost:8080/"); SVC_STOP_TIMEOUT=7
calls() { grep -v -e '^docker info' -e '^docker compose version' "$DOCKER_CALLS"; }

: >"$DOCKER_CALLS"
svc_start --build >"$out" 2>&1; check "compose start exits 0" 0 $?
check "compose start commands" "docker compose -f compose.yml -f compose dev.yml -p demo ps -q
docker compose -f compose.yml -f compose dev.yml -p demo up -d --build" "$(calls)"
said "compose start prints URLs" "$out" "Web UI: http://localhost:8080/"

: >"$DOCKER_CALLS"
svc_stop >"$out" 2>&1; check "compose stop exits 0" 0 $?
check "compose stop is down with the timeout" "docker compose -f compose.yml -f compose dev.yml -p demo down --timeout 7" "$(calls)"
: >"$DOCKER_CALLS"; SVC_STOP_MODE=stop
svc_stop >"$out" 2>&1
check "SVC_STOP_MODE=stop uses stop" "docker compose -f compose.yml -f compose dev.yml -p demo stop --timeout 7" "$(calls)"
unset SVC_STOP_MODE
: >"$DOCKER_CALLS"; SVC_LOGS_FOLLOW=1
svc_logs api >"$out" 2>&1
check "compose logs follows one service" "docker compose -f compose.yml -f compose dev.yml -p demo logs -f api" "$(calls)"
: >"$DOCKER_CALLS"
DOCKER_DOWN=1 svc_start >"$out" 2>&1; check "docker daemon down fails start" 1 $?
check "nothing is brought up with docker down" "" "$(calls)"

echo
if [[ $failures -eq 0 ]]; then
  note "all tests passed"
else
  note "$failures failure(s)"
  exit 1
fi
