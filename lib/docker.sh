#!/usr/bin/env bash
# Docker/Docker Compose helpers

# Prefer 'docker compose' (V2) over 'docker-compose' (V1); print error if neither.
get_docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return 0
  else
    log_error "Neither 'docker compose' nor 'docker-compose' found."
    return 1
  fi
}

# Execute docker compose with auto-detected command
docker_compose() {
  local cmd; cmd=$(get_docker_compose_cmd) || return 1
  log_debug "Executing: $cmd $*"
  $cmd "$@"
}

# Compatibility: document-tracker style
run_docker_compose() { docker_compose "$@"; }

# Compatibility: helpergpt style (takes a single combined command string)
run_docker_compose_command() {
  local cmd; cmd=$(get_docker_compose_cmd) || return 1
  # shellcheck disable=SC2086
  $cmd $*
}

check_docker() {
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon is not running or not accessible."
    return 1
  fi
}

check_project_root() {
  if [[ ! -f "docker-compose.yml" ]]; then
    log_error "docker-compose.yml not found. Run from the project root."
    return 1
  fi
}

wait_for_service() {
  local service_name="$1"; local max_wait="${2:-60}"; local wait_time=0
  log_info "Waiting for service '$service_name' to be ready..."
  while [[ $wait_time -lt $max_wait ]]; do
    if docker_compose ps "$service_name" 2>/dev/null | grep -q "running"; then
      log_info "Service '$service_name' is ready"
      return 0
    fi
    sleep 2; wait_time=$((wait_time + 2))
    if [[ $((wait_time % 10)) -eq 0 ]]; then
      log_info "Still waiting for '$service_name'... (${wait_time}s elapsed)"
    fi
  done
  log_error "Timeout waiting for service '$service_name' after ${max_wait}s"
  return 1
}

