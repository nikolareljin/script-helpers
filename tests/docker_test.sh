#!/usr/bin/env bash
# SCRIPT: docker_test.sh
# DESCRIPTION: Tests for lib/docker.sh -- wait_for_service readiness and run_docker_compose_command splitting.
# USAGE: ./tests/docker_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/docker_test.sh
# ----------------------------------------------------
#
# No Docker needed: `docker` and `docker-compose` are stubs on PATH that
# answer the way Compose v2 and v1 do, and log how they were called.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[docker_test] $*"; }
error() { echo "[docker_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[docker_test]   ok  $*"; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging docker

# Compose v2: `docker compose ...`. STATE_FILE says whether svc is running.
mkdir -p "$tmp/v2"
cat >"$tmp/v2/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
[[ "${1:-}" == "compose" ]] || exit 1
shift
case "$*" in
  version) echo "Docker Compose version v2.29.0" ;;
  "ps --status running -q svc") [[ "$(cat "$STATE_FILE")" == up ]] && echo 3f2a1b ;;
  "ps svc")
    echo "NAME        IMAGE     COMMAND   SERVICE   CREATED         STATUS         PORTS"
    [[ "$(cat "$STATE_FILE")" == up ]] && echo "proj-svc-1  bash:3.2  sleep 60  svc       6 seconds ago   Up 5 seconds"
    ;;
  *) : ;;
esac
exit 0
STUB
# Compose v1: no `docker compose`, and `ps` has no --status.
mkdir -p "$tmp/v1"
cat >"$tmp/v1/docker" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat >"$tmp/v1/docker-compose" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
  *--status*) echo "No such option: --status" >&2; exit 1 ;;
  "ps svc")
    echo "    Name      Command   State   Ports"
    echo "-----------------------------------"
    if [[ "$(cat "$STATE_FILE")" == up ]]; then echo "proj_svc_1   sleep 60   Up"; else echo "proj_svc_1   sleep 60   Exit 0"; fi
    ;;
esac
exit 0
STUB
chmod +x "$tmp/v1/docker" "$tmp/v1/docker-compose" "$tmp/v2/docker"
export STUB_LOG="$tmp/calls.log" STATE_FILE="$tmp/state"

saved_path="$PATH"
for v in v2 v1; do
  echo up >"$STATE_FILE"
  PATH="$tmp/$v:$saved_path"
  rc=0; wait_for_service svc 4 >/dev/null 2>&1 || rc=$?
  PATH="$saved_path"
  if [[ "$rc" == "0" ]]; then ok "$v: a running service is ready"; else error "$v: running service not seen (rc=$rc)"; fi

  echo down >"$STATE_FILE"
  PATH="$tmp/$v:$saved_path"
  rc=0; wait_for_service svc 2 >/dev/null 2>&1 || rc=$?
  PATH="$saved_path"
  if [[ "$rc" == "1" ]]; then ok "$v: a stopped service times out"; else error "$v: stopped service reported ready (rc=$rc)"; fi
done

note "run_docker_compose_command"
: >"$STUB_LOG"
PATH="$tmp/v2:$saved_path"
out="$(set -u; run_docker_compose_command "" 2>&1)"; rc=$?
PATH="$saved_path"
if [[ "$rc" == "0" && "$out" != *unbound* ]]; then ok "an empty command string is not an unbound-variable error"; else error "empty command: rc=$rc out=$out"; fi
: >"$STUB_LOG"
PATH="$tmp/v2:$saved_path"
run_docker_compose_command "up -d  --build" >/dev/null 2>&1
PATH="$saved_path"
if grep -qx "compose up -d --build" "$STUB_LOG"; then ok "a command string is split on whitespace"; else error "split wrong: $(cat "$STUB_LOG")"; fi

if [[ $failures -eq 0 ]]; then
  note "all docker tests passed"
  exit 0
fi
note "$failures failure(s)"
exit 1
