#!/usr/bin/env bash
# SCRIPT: ollama_project_prepare_test.sh
# DESCRIPTION: Tests for ollama_runtime, ollama_project_compose_files, ollama_project_prepare and the container probe of ollama_endpoint_container_reach.
# USAGE: ./tests/ollama_project_prepare_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ollama_project_prepare_test.sh
# ----------------------------------------------------
#
# docker and curl are stubs on PATH: docker records each call and answers as
# FAKE_* say; curl answers the container's port when FAKE_UP is set. The model
# check and the reach check are replaced by functions that record what they
# were given, so nothing here needs an Ollama or a Docker daemon.
# The cases that matter most: the container is never chosen by itself, a
# stale address naming it is refused, a bad setting stops before Docker is
# touched, and a failed check is not reported as success.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[ollama_project_prepare_test] $*"; }
error() { echo "[ollama_project_prepare_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[ollama_project_prepare_test]   ok  $*"; }
check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else error "$1: expected [$2], got [$3]"; fi
}

tmp="$(mktemp -d)"
# Invoked only by the EXIT trap.
# shellcheck disable=SC2317
cleanup() { [[ ${BASHPID-$$} == "$$" ]] || return 0; rm -rf "$tmp"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging ollama_endpoint

# --- stubs -----------------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/proj"
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env sh
echo "docker $*" >>"$CALLS"
case "$1 $2" in
  "volume inspect") [ -n "${FAKE_VOLUME:-}" ] ;;
  "volume create") [ -z "${FAKE_VOLUME_FAIL:-}" ] ;;
  "compose up"|"compose --env-file") [ -z "${FAKE_UP_FAIL:-}" ] ;;
  "network inspect") [ -n "${FAKE_NET:-}" ] ;;
  "image ls") [ -n "${FAKE_IMAGE:-}" ] && echo "$FAKE_IMAGE" ;;
  "run --rm")
    [ -n "${FAKE_RUN_FAIL:-}" ] && exit 125
    echo ollama-reach-probe; printf '%s' "${FAKE_RUN_BODY:-}" ;;
esac
SH
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env sh
echo "curl $*" >>"$CALLS"
[ -n "${FAKE_UP:-}" ] || exit 7
printf '%s' "${FAKE_BODY:-{\"models\":[]}}"
SH
chmod +x "$tmp/bin/docker" "$tmp/bin/curl"
: >"$tmp/proj/docker-compose.yml"
: >"$tmp/proj/docker-ollama.yml"
printf 'OLLAMA_MODEL=main:7b\n' >"$tmp/proj/ai-models.env"

# prep [VAR=value...] -- <args>: runs ollama_project_prepare in a subshell with
# the stubs. Prints "rc" then what was exported and what the checks were given.
prep() {
  local -a kv=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do kv+=("$1"); shift; done
  shift
  : >"$tmp/calls"
  ( unset OLLAMA_RUNTIME OLLAMA_URL OLLAMA_BASE_URL OLLAMA_HOST OLLAMA_MODEL OLLAMA_CONTAINER_PORT \
      COMPOSE_FILE AI_MODEL_TIER OLLAMA_PULL_MISSING OLLAMA_MODE APP_SKIP
    export CALLS="$tmp/calls" PATH="$tmp/bin:$PATH" OLLAMA_CONTAINER_WAIT_SECONDS=1 _OLLAMA_EP_DOCKERENV="$tmp/none"
    for v in ${kv[@]+"${kv[@]}"}; do export "${v?}"; done
    sleep() { :; }
    ollama_project_ensure_models() {
      echo "ensure: file=${1##*/} env=${2##*/} names=${*:3} url=${!OLLAMA_URL_VARS} mode=${OLLAMA_MODE:-} port=${OLLAMA_HOST_PORT:-} pull=${OLLAMA_PULL_MISSING:-} tier=${AI_MODEL_TIER:-}" >>"$CALLS"
      return "${FAKE_ENSURE:-0}"
    }
    ollama_endpoint_container_reach() { echo "reach: $1 net=${2:-}" >>"$CALLS"; return "${FAKE_REACH:-0}"; }
    ollama_project_prepare "$tmp/proj" "$@" >"$tmp/out" 2>"$tmp/err"
    rc=$?
    echo "rc=$rc"
    echo "COMPOSE_FILE=${COMPOSE_FILE:-}"
    echo "OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-}"
    echo "OLLAMA_MODEL=${OLLAMA_MODEL:-}"
    echo "OLLAMA_CONTAINER_PORT=${OLLAMA_CONTAINER_PORT:-}"
    echo "AI_MODEL_TIER=${AI_MODEL_TIER:-}" )
}
got() { grep -c -F -e "$1" "${2:-$tmp/calls}" | tr -d ' '; }
# order <file> <first> <second>: "yes" when first is said before second.
order() {
  local a b
  a="$(grep -n -F -e "$2" "$1" | head -n 1 | cut -d: -f1)"; b="$(grep -n -F -e "$3" "$1" | head -n 1 | cut -d: -f1)"
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then echo yes; else echo no; fi
}
D=(--mode docker --url-var OLLAMA_BASE_URL --volume proj_ollama_data --model-var OLLAMA_MODEL)

# --- ollama_runtime ----------------------------------------------------------
rt() { ( unset OLLAMA_RUNTIME; for v in "$@"; do export "${v?}"; done; ollama_runtime "$tmp/proj/.env" 2>"$tmp/err"; echo "rc=$?" ) | tr '\n' ' ' | sed 's/ $//'; }
rm -f "$tmp/proj/.env"
check "no setting: host" "host rc=0" "$(rt)"
check "blank is not set" "host rc=0" "$(rt OLLAMA_RUNTIME=' ')"
printf 'OLLAMA_RUNTIME=container\n' >"$tmp/proj/.env"
check ".env says container" "container rc=0" "$(rt)"
check "the environment wins over .env" "host rc=0" "$(rt OLLAMA_RUNTIME=host)"
check "anything else: 9, naming both" "rc=9:1" "$(rt OLLAMA_RUNTIME=docker):$(got 'use host (the machine' "$tmp/err")"
rm -f "$tmp/proj/.env"

# --- ollama_project_compose_files --------------------------------------------
P="$tmp/proj"
check "stop: the override always, so a started container stops" "$P/docker-compose.yml:$P/docker-ollama.yml" "$(ollama_project_compose_files "$P")"
check "--by-runtime, host: the main file only" "$P/docker-compose.yml" "$(unset OLLAMA_RUNTIME; ollama_project_compose_files "$P" --by-runtime)"
check "--by-runtime, container: both" "$P/docker-compose.yml:$P/docker-ollama.yml" "$(OLLAMA_RUNTIME=container ollama_project_compose_files "$P" --by-runtime)"
check "--by-runtime, a bad runtime: 9" "9" "$(OLLAMA_RUNTIME=bogus ollama_project_compose_files "$P" --by-runtime 2>/dev/null; echo $?)"
mkdir -p "$P/api"; : >"$P/api/docker-compose.yml"
check "no override file: the main file only" "$P/api/docker-compose.yml" "$(ollama_project_compose_files "$P" --compose api/docker-compose.yml)"
check "an unknown option: 9" "9" "$(ollama_project_compose_files "$P" --nope 2>/dev/null; echo $?)"

# --- host runtime (the default) ----------------------------------------------
out="$(prep -- "${D[@]}")"
check "host: rc 0" "rc=0" "$(sed -n 1p <<<"$out")"
check "host: COMPOSE_FILE is the main file only" "COMPOSE_FILE=$P/docker-compose.yml" "$(grep COMPOSE_FILE <<<"$out")"
check "host, docker: the app gets host.docker.internal" "OLLAMA_BASE_URL=http://host.docker.internal:11434" "$(grep OLLAMA_BASE_URL <<<"$out")"
check "the model is exported from the models file" "OLLAMA_MODEL=main:7b" "$(grep OLLAMA_MODEL= <<<"$out")"
check "the check asks that address and that model, pull ask" "1" "$(got 'ensure: file=ai-models.env env=.env names=OLLAMA_MODEL url=http://host.docker.internal:11434 mode= port= pull=ask')"
check "then the reach check, from the project's network when it exists" "1" "$(prep FAKE_NET=1 -- "${D[@]}" >/dev/null; got 'reach: http://host.docker.internal:11434 net=proj_default')"
check "no container started or volume created in host mode" "0:0" "$(got 'docker volume'):$(got 'up -d')"
printf 'OLLAMA_PULL_MISSING=0\n' >"$P/.env"
check "a project's own OLLAMA_PULL_MISSING is kept" "1" "$(prep -- "${D[@]}" >/dev/null; got 'pull= tier')"
rm -f "$P/.env"
check "a remote host Ollama: no pull default" "1" "$(prep OLLAMA_BASE_URL=http://192.0.2.7:11434 -- "${D[@]}" >/dev/null; got 'pull= tier')"
check "--url-suffix goes on the default" "OLLAMA_BASE_URL=http://host.docker.internal:11434/api/generate" "$(prep -- "${D[@]}" --url-suffix /api/generate | grep OLLAMA_BASE_URL)"
check "local mode: 127.0.0.1, no reach check" "OLLAMA_BASE_URL=http://127.0.0.1:11434:0" "$(prep -- --mode local --url-var OLLAMA_BASE_URL --volume v | grep OLLAMA_BASE_URL):$(got 'reach:')"
check "local mode: Docker's name for the host is this machine" "OLLAMA_BASE_URL=http://127.0.0.1:11434/api/generate" "$(prep OLLAMA_BASE_URL=http://host.docker.internal:11434/api/generate -- --mode local --url-var OLLAMA_BASE_URL --volume v | grep OLLAMA_BASE_URL)"
check "--standard-tier sets standard and warns about another" "AI_MODEL_TIER=standard:1" "$(prep AI_MODEL_TIER=large -- "${D[@]}" --standard-tier | grep AI_MODEL_TIER):$(got 'AI_MODEL_TIER=large is not used' "$tmp/err")"

# Failure paths in host mode.
out="$(prep FAKE_ENSURE=4 -- "${D[@]}")"
check "no host Ollama: 4, host named first, then OLLAMA_RUNTIME=container" "rc=4:yes" "$(sed -n 1p <<<"$out"):$(order "$tmp/err" "host's Ollama does not answer" 'set OLLAMA_RUNTIME=container in .env')"
check "and the container is never started by itself" "0:0" "$(got 'up -d'):$(got 'reach:')"
check "a model refusal is passed on (5)" "rc=5" "$(prep FAKE_ENSURE=5 -- "${D[@]}" | sed -n 1p)"
check "the reach check failing is the result (4)" "rc=4" "$(prep FAKE_REACH=4 -- "${D[@]}" | sed -n 1p)"
out="$(prep OLLAMA_BASE_URL=http://ollama:11434 -- "${D[@]}")"
check "stale: a host-mode address naming the container is 9, with the fixes" "rc=9:1:0" "$(sed -n 1p <<<"$out"):$(got 'runs only with OLLAMA_RUNTIME=container' "$tmp/err"):$(got 'ensure:')"
printf 'OLLAMA_BASE_URL=ollama:11434\n' >"$P/.env"
check "the same from .env, written without a scheme" "rc=9" "$(prep -- "${D[@]}" | sed -n 1p)"
printf 'OLLAMA_BASE_URL=\n' >"$P/.env"
check "an empty .env line is not set: the default" "OLLAMA_BASE_URL=http://host.docker.internal:11434" "$(prep -- "${D[@]}" | grep OLLAMA_BASE_URL)"
rm -f "$P/.env"
check "not an address: 9" "rc=9" "$(prep 'OLLAMA_BASE_URL=http:/x y' -- "${D[@]}" | sed -n 1p)"
check "a bad runtime: 9, before Docker or the check" "rc=9:0:0" "$(prep OLLAMA_RUNTIME=Container -- "${D[@]}" | sed -n 1p):$(got docker):$(got ensure)"
check "skip: set up, nothing checked" "rc=0:0:OLLAMA_BASE_URL=http://host.docker.internal:11434" "$(prep APP_SKIP=1 -- "${D[@]}" --skip-var APP_SKIP > "$tmp/o"; sed -n 1p "$tmp/o"):$(got ensure):$(grep OLLAMA_BASE_URL "$tmp/o")"

# Bad calls.
check "no --mode: 9" "rc=9" "$(prep -- --url-var X --volume v | sed -n 1p)"
check "no --url-var: 9" "rc=9" "$(prep -- --mode docker --volume v | sed -n 1p)"
check "no --volume: 9" "rc=9" "$(prep -- --mode docker --url-var X | sed -n 1p)"
check "an unknown option: 9" "rc=9" "$(prep -- "${D[@]}" --nope | sed -n 1p)"
check "an option without its value: 9" "rc=9" "$(prep -- "${D[@]}" --url-suffix | sed -n 1p)"
check "not a root directory: 9" "9" "$(ollama_project_prepare "$tmp/none" "${D[@]}" 2>/dev/null; echo $?)"

# --- container runtime -------------------------------------------------------
out="$(prep OLLAMA_RUNTIME=container FAKE_UP=1 -- "${D[@]}")"
check "container: rc 0" "rc=0" "$(sed -n 1p <<<"$out")"
check "container: COMPOSE_FILE adds the override" "COMPOSE_FILE=$P/docker-compose.yml:$P/docker-ollama.yml" "$(grep COMPOSE_FILE <<<"$out")"
check "container, docker: the app gets the service" "OLLAMA_BASE_URL=http://ollama:11434" "$(grep OLLAMA_BASE_URL <<<"$out")"
check "the port is exported for compose" "OLLAMA_CONTAINER_PORT=11435" "$(grep OLLAMA_CONTAINER_PORT <<<"$out")"
check "the volume is created when missing, then compose up" "1:1" "$(got 'docker volume create proj_ollama_data'):$(got 'compose up -d ollama')"
check "checked on 127.0.0.1:port with OLLAMA_MODE=docker" "1:1" "$(got 'curl -fsS -m 2 http://127.0.0.1:11435/api/tags'):$(got 'url=http://ollama:11434 mode=docker port=11435 pull=ask')"
check "no reach check for the container" "0" "$(got 'reach:')"
check "an existing volume is not created again" "0" "$(prep OLLAMA_RUNTIME=container FAKE_UP=1 FAKE_VOLUME=1 -- "${D[@]}" >/dev/null; got 'volume create')"
printf 'OLLAMA_RUNTIME=container\nOLLAMA_CONTAINER_PORT=11500\n' >"$P/.env"
out="$(prep FAKE_UP=1 -- --mode local --url-var OLLAMA_BASE_URL --volume v)"
check "from .env, local mode: the app gets 127.0.0.1:port" "OLLAMA_BASE_URL=http://127.0.0.1:11500" "$(grep OLLAMA_BASE_URL <<<"$out")"
check "compose gets the project's .env" "1" "$(got "compose --env-file $P/.env up -d ollama")"
rm -f "$P/.env"
check "the container does not answer: 4" "rc=4:1" "$(prep OLLAMA_RUNTIME=container -- "${D[@]}" | sed -n 1p):$(got 'does not answer on 127.0.0.1:11435' "$tmp/err")"
check "compose up fails: 10" "rc=10" "$(prep OLLAMA_RUNTIME=container FAKE_UP_FAIL=1 -- "${D[@]}" | sed -n 1p)"
check "the volume cannot be created: 10" "rc=10" "$(prep OLLAMA_RUNTIME=container FAKE_VOLUME_FAIL=1 -- "${D[@]}" | sed -n 1p)"
check "port 11434 is the host's: 9" "rc=9" "$(prep OLLAMA_RUNTIME=container OLLAMA_CONTAINER_PORT=11434 -- "${D[@]}" | sed -n 1p)"
check "a port that is not one: 9, before Docker" "rc=9:0" "$(prep OLLAMA_RUNTIME=container OLLAMA_CONTAINER_PORT=70000 -- "${D[@]}" | sed -n 1p):$(got docker)"
check "--port-var reads the project's own name" "1" "$(prep OLLAMA_RUNTIME=container OLLAMA_PORT=11600 FAKE_UP=1 -- "${D[@]}" --port-var OLLAMA_PORT >/dev/null; got 'port=11600')"
rm "$P/docker-ollama.yml"
check "no override file: 9, pointing at the host" "rc=9:1" "$(prep OLLAMA_RUNTIME=container -- "${D[@]}" | sed -n 1p):$(got 'no optional Ollama container' "$tmp/err")"
: >"$P/docker-ollama.yml"
check "--no-container-pull: volume made, not started or checked" "rc=0:1:0:0" "$(prep OLLAMA_RUNTIME=container -- "${D[@]}" --no-container-pull | sed -n 1p):$(got 'volume create'):$(got 'up -d'):$(got ensure)"
check "skip in container mode: volume made, not started" "rc=0:1:0" "$(prep OLLAMA_RUNTIME=container APP_SKIP=1 -- "${D[@]}" --skip-var APP_SKIP | sed -n 1p):$(got 'volume create'):$(got 'up -d')"
check "a model refusal from the container is passed on" "rc=5" "$(prep OLLAMA_RUNTIME=container FAKE_UP=1 FAKE_ENSURE=5 -- "${D[@]}" | sed -n 1p)"
check "docker absent: 10" "rc=10" "$(prep OLLAMA_RUNTIME=container 'PATH=/usr/bin:/bin' -- "${D[@]}" | sed -n 1p)"

# --- the container probe of ollama_endpoint_container_reach -----------------
reach() { # reach <url> <network> [VAR=value...]
  local url="$1" net="$2"; shift 2
  : >"$tmp/calls"
  ( export CALLS="$tmp/calls" PATH="$tmp/bin:$PATH" _OLLAMA_EP_DOCKERENV="$tmp/none"
    unset OLLAMA_REACH_IMAGE
    for v in "$@"; do export "${v?}"; done
    ollama_endpoint_container_reach "$url" "$net" >"$tmp/out" 2>"$tmp/err"; echo $? )
}
TAGS='{"models":[]}'
check "an image is here: asked from a container on the project's network" "0:1" "$(reach http://host.docker.internal:11434 app_default FAKE_IMAGE=busybox:1.36 FAKE_NET=1 FAKE_RUN_BODY="$TAGS"):$(got 'run --rm --pull=never --network app_default --add-host host.docker.internal:host-gateway --entrypoint sh busybox:1.36')"
check "the URL is an argument, not part of the program" "1" "$(got 'probe http://host.docker.internal:11434/api/tags')"
check "no answer from the container: 4, naming the network" "4:1" "$(reach http://host.docker.internal:11434 app_default FAKE_IMAGE=busybox:1.36 FAKE_NET=1):$(got 'container on network app_default cannot reach' "$tmp/err")"
check "a network not made yet: the default bridge" "4:0:1" "$(reach http://host.docker.internal:11434 app_default FAKE_IMAGE=busybox:1.36):$(got '--network app_default'):$(got "Docker's default bridge cannot" "$tmp/err")"
check "nothing is pulled: --pull=never" "1" "$(got 'pull=never')"
# No image: the old probe from the host, and it says the network was not checked.
mkdir -p "$tmp/bin2"
cat >"$tmp/bin2/docker" <<'SH'
#!/usr/bin/env sh
echo "docker $*" >>"$CALLS"
case "$1" in network) [ "$2" = inspect ] && [ "$3" = bridge ] && echo "198.51.100.1 " ;; esac
exit 0
SH
cat >"$tmp/bin2/ip" <<'SH'
#!/usr/bin/env sh
echo "3: docker0    inet 198.51.100.1/24 scope global docker0"
SH
chmod +x "$tmp/bin2/docker" "$tmp/bin2/ip"
check "no image: the bridge probe, and 'not checked from the project's network'" "0:0:1" "$(reach http://host.docker.internal:11434 '' "PATH=$tmp/bin2:$tmp/bin:$PATH" FAKE_UP=1):$(got 'run --rm'):$(got "not checked from the project's network" "$tmp/err")"
check "a container run that fails (old Docker): falls back to the bridge probe" "0:1" "$(reach http://host.docker.internal:11434 '' FAKE_IMAGE=busybox:1.36 FAKE_RUN_FAIL=1 "PATH=$tmp/bin2:$tmp/bin:$PATH" FAKE_UP=1 OLLAMA_REACH_IMAGE=busybox:1.36):$(got 'curl -sS -m 5 --interface 127.0.0.1')"
check "a loopback URL is not asked from a container" "0" "$(reach http://127.0.0.1:11434 '' FAKE_IMAGE=busybox:1.36 "PATH=$tmp/bin2:$tmp/bin:$PATH" FAKE_UP=1 >/dev/null; got 'run --rm')"
check "another machine: nothing asked" "0:0" "$(reach http://192.0.2.10:11434 '' FAKE_IMAGE=busybox:1.36):$(wc -l <"$tmp/calls" | tr -d ' ')"

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "ALL PASSED"
