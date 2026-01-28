#!/usr/bin/env bash
# SCRIPT: ci_flutter.sh
# DESCRIPTION: Run Flutter CI steps (analyze, test, build) with configurable commands.
# USAGE: scripts/ci_flutter.sh [--workdir <path>] [--skip-analyze] [--skip-test] [--skip-build]
# PARAMETERS:
#   --workdir <path>   Working directory for flutter commands (default: current dir).
#   --skip-analyze     Skip flutter analyze.
#   --skip-test        Skip flutter test.
#   --skip-build       Skip flutter build step.
#   --build-cmd <c>    Override build command (default: flutter build appbundle --release).
#   --image <img>      Docker image to use (default: ghcr.io/cirruslabs/flutter:stable).
#   --no-docker        Run on the host instead of Docker.
#   -h, --help         Show this help message.
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
SKIP_ANALYZE=false
SKIP_TEST=false
SKIP_BUILD=false
BUILD_CMD="flutter build appbundle --release"
USE_DOCKER=true
IMAGE="ghcr.io/cirruslabs/flutter:stable"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --skip-analyze) SKIP_ANALYZE=true; shift;;
    --skip-test) SKIP_TEST=true; shift;;
    --skip-build) SKIP_BUILD=true; shift;;
    --build-cmd) BUILD_CMD="$2"; shift 2;;
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
    DOCKER_CMD+=(-v "$HOME/.pub-cache":/home/flutter/.pub-cache)
  fi
  DOCKER_CMD+=("$IMAGE" bash -lc)
  if [[ "$SKIP_ANALYZE" == "false" ]]; then
    log_info "flutter analyze"
    "${DOCKER_CMD[@]}" "flutter analyze"
  fi
  if [[ "$SKIP_TEST" == "false" ]]; then
    log_info "flutter test"
    "${DOCKER_CMD[@]}" "flutter test"
  fi
  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "$BUILD_CMD"
    "${DOCKER_CMD[@]}" "$BUILD_CMD"
  fi
else
  if ! command -v flutter >/dev/null 2>&1; then
    log_error "flutter is required on PATH."
    exit 1
  fi
  pushd "$WORKDIR" >/dev/null
  if [[ "$SKIP_ANALYZE" == "false" ]]; then
    log_info "flutter analyze"
    flutter analyze
  fi
  if [[ "$SKIP_TEST" == "false" ]]; then
    log_info "flutter test"
    flutter test
  fi
  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "$BUILD_CMD"
    bash -lc "$BUILD_CMD"
  fi
  popd >/dev/null
fi
