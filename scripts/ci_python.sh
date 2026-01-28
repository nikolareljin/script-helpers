#!/usr/bin/env bash
# SCRIPT: ci_python.sh
# DESCRIPTION: Run Python CI steps (install + pytest) with configurable commands.
# USAGE: scripts/ci_python.sh [--workdir <path>] [--no-install] [--requirements <file>] [--constraints <file>]
# PARAMETERS:
#   --workdir <path>     Working directory for Python commands (default: current dir).
#   --no-install         Skip dependency install step.
#   --requirements <f>   Requirements file to install (default: requirements.txt if present).
#   --constraints <f>    Constraints file to use (optional).
#   --extra-install <c>  Extra packages to install (e.g. "pytest tldextract").
#   --test-cmd <c>       Test command (default: python -m pytest -q).
#   --pip-cmd <c>        Override pip install command (replaces default install logic).
#   --image <img>        Docker image to use (default: python:3.11-slim).
#   --no-docker          Run on the host instead of Docker.
#   -h, --help           Show this help message.
# ----------------------------------------------------
set -euo pipefail

if [[ "${CI:-}" == "true" ]]; then
  echo "This script is intended for local use only." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging

WORKDIR="."
NO_INSTALL=false
REQ_FILE=""
CONSTRAINTS_FILE=""
EXTRA_INSTALL=""
TEST_CMD="python -m pytest -q"
PIP_CMD=""
USE_DOCKER=true
IMAGE="python:3.11-slim"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --no-install) NO_INSTALL=true; shift;;
    --requirements) REQ_FILE="$2"; shift 2;;
    --constraints) CONSTRAINTS_FILE="$2"; shift 2;;
    --extra-install) EXTRA_INSTALL="$2"; shift 2;;
    --test-cmd) TEST_CMD="$2"; shift 2;;
    --pip-cmd) PIP_CMD="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --no-docker) USE_DOCKER=false; shift;;
    -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ "$USE_DOCKER" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required for --docker runs."
    exit 1
  fi
  ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
  DOCKER_CMD=(docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -v "$ABS_WORKDIR":/work -w /work)
  if [[ -n "${HOME:-}" ]]; then
    DOCKER_CMD+=(-v "$HOME/.cache/pip":/root/.cache/pip)
  fi
  DOCKER_CMD+=("$IMAGE" bash -lc)
  if [[ "$NO_INSTALL" == "false" ]]; then
    if [[ -n "$PIP_CMD" ]]; then
      log_info "$PIP_CMD"
      "${DOCKER_CMD[@]}" "$PIP_CMD"
    else
      log_info "python -m pip install --upgrade pip"
      "${DOCKER_CMD[@]}" "python -m pip install --upgrade pip"
      if [[ -z "$REQ_FILE" && -f "$ABS_WORKDIR/requirements.txt" ]]; then
        REQ_FILE="requirements.txt"
      fi
      if [[ -n "$REQ_FILE" ]]; then
        install_cmd="python -m pip install -r \"$REQ_FILE\""
        if [[ -n "$CONSTRAINTS_FILE" ]]; then
          install_cmd+=" -c \"$CONSTRAINTS_FILE\""
        fi
        log_info "$install_cmd"
        "${DOCKER_CMD[@]}" "$install_cmd"
      fi
      if [[ -n "$EXTRA_INSTALL" ]]; then
        log_info "python -m pip install $EXTRA_INSTALL"
        "${DOCKER_CMD[@]}" "python -m pip install $EXTRA_INSTALL"
      fi
    fi
  fi
  log_info "$TEST_CMD"
  "${DOCKER_CMD[@]}" "$TEST_CMD"
else
  if ! command -v python >/dev/null 2>&1; then
    log_error "python is required on PATH."
    exit 1
  fi
  pushd "$WORKDIR" >/dev/null
  if [[ "$NO_INSTALL" == "false" ]]; then
    if [[ -n "$PIP_CMD" ]]; then
      log_info "$PIP_CMD"
      bash -lc "$PIP_CMD"
    else
      log_info "python -m pip install --upgrade pip"
      python -m pip install --upgrade pip
      if [[ -z "$REQ_FILE" && -f "requirements.txt" ]]; then
        REQ_FILE="requirements.txt"
      fi
      if [[ -n "$REQ_FILE" ]]; then
        install_cmd="python -m pip install -r \"$REQ_FILE\""
        if [[ -n "$CONSTRAINTS_FILE" ]]; then
          install_cmd+=" -c \"$CONSTRAINTS_FILE\""
        fi
        log_info "$install_cmd"
        bash -lc "$install_cmd"
      fi
      if [[ -n "$EXTRA_INSTALL" ]]; then
        log_info "python -m pip install $EXTRA_INSTALL"
        python -m pip install $EXTRA_INSTALL
      fi
    fi
  fi
  log_info "$TEST_CMD"
  bash -lc "$TEST_CMD"
  popd >/dev/null
fi
