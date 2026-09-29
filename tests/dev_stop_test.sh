#!/usr/bin/env bash
# SCRIPT: dev_stop_test.sh
# DESCRIPTION: Tests the `stop` verb in templates/dev-cli/cli.sh.
# USAGE: bash tests/dev_stop_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_stop_test.sh
# ----------------------------------------------------
#
# Three paths: project_stop wins; a compose file at the root gets
# `docker compose -f <file> stop`; anything else exits 0 saying it does not apply.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[dev_stop_test] $*"; }
error() { echo "[dev_stop_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# A stand-in consumer repo running the real template.
new_repo() {
  local repo="$tmp/$1"
  mkdir -p "$repo/scripts"
  git -C "$repo" init -q .
  cp templates/dev-cli/cli.sh templates/dev-cli/_bootstrap.sh "$repo/scripts/"
  ln -s "$ROOT_DIR" "$repo/scripts/script-helpers"
  echo "$repo"
}

# A docker on PATH that records what it was asked and succeeds.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
exit 0
EOF
chmod +x "$tmp/bin/docker"
export DOCKER_LOG="$tmp/docker.log"

dev() { (cd "$1" && shift && PATH="$tmp/bin:$PATH" bash scripts/cli.sh "$@") 2>&1; }

# 1. project_stop replaces the default.
repo="$(new_repo custom)"
printf 'project_stop() { echo "custom stop ran"; }\n' > "$repo/scripts/project.sh"
: > "$repo/docker-compose.yml"
: > "$DOCKER_LOG"
out="$(dev "$repo" stop)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"custom stop ran"* && ! -s "$DOCKER_LOG" ]]; then
  note "project_stop replaces the default"
else
  error "project_stop: rc=$rc out='$out' docker='$(cat "$DOCKER_LOG")'"
fi

# 2. A compose file at the root: docker compose -f <that file> stop.
repo="$(new_repo compose)"
: > "$repo/compose.yaml"
: > "$DOCKER_LOG"
out="$(dev "$repo" stop)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "compose -f $repo/compose.yaml stop" "$DOCKER_LOG"; then
  note "a compose file gets docker compose stop"
else
  error "compose: rc=$rc out='$out' docker='$(cat "$DOCKER_LOG")'"
fi

# 3. Nothing to stop: exit 0 and say so.
repo="$(new_repo plain)"
: > "$DOCKER_LOG"
out="$(dev "$repo" stop)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"stop: not applicable"* && ! -s "$DOCKER_LOG" ]]; then
  note "no compose file and no project_stop: not applicable, exit 0"
else
  error "plain: rc=$rc out='$out'"
fi

# 4. The verb is listed.
out="$(dev "$repo" help)"
if [[ "$out" == *"stop          Stop what run started"* ]]; then
  note "help lists stop"
else
  error "help does not list stop"
fi

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
