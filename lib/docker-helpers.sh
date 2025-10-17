#!/usr/bin/env bash

# docker-helpers.sh
# Provides docker helper methods for common operations

# Guard against multiple sourcing
[[ -n "${_DOCKER_HELPERS_LOADED:-}" ]] && return 0
readonly _DOCKER_HELPERS_LOADED=1

# Source logging helpers if available
SCRIPT_DIR="${BASH_SOURCE%/*}"
if [[ -f "$SCRIPT_DIR/logging-helpers.sh" ]]; then
    source "$SCRIPT_DIR/logging-helpers.sh"
else
    log_error() { echo "ERROR: $*" >&2; }
    log_warn() { echo "WARN: $*" >&2; }
    log_info() { echo "INFO: $*" >&2; }
    log_debug() { echo "DEBUG: $*" >&2; }
    log_success() { echo "SUCCESS: $*" >&2; }
fi

# Check if docker is installed
check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        log_error "docker command not found. Please install Docker."
        return 1
    fi
    return 0
}

# Check if docker daemon is running
docker_is_running() {
    check_docker_installed || return 1
    docker info &> /dev/null
}

# List running containers
docker_list_containers() {
    local all="${1:-false}"
    check_docker_installed || return 1
    
    if [[ "$all" == "true" ]]; then
        docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}"
    else
        docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}"
    fi
}

# List images
docker_list_images() {
    check_docker_installed || return 1
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}"
}

# Check if container exists
docker_container_exists() {
    local container="$1"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    docker ps -a --format "{{.Names}}" | grep -q "^${container}$"
}

# Check if container is running
docker_container_is_running() {
    local container="$1"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    docker ps --format "{{.Names}}" | grep -q "^${container}$"
}

# Start a container
docker_start_container() {
    local container="$1"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    if docker_container_is_running "$container"; then
        log_warn "Container '$container' is already running"
        return 0
    fi
    
    log_info "Starting container: $container"
    docker start "$container"
}

# Stop a container
docker_stop_container() {
    local container="$1"
    local timeout="${2:-10}"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    if ! docker_container_is_running "$container"; then
        log_warn "Container '$container' is not running"
        return 0
    fi
    
    log_info "Stopping container: $container"
    docker stop -t "$timeout" "$container"
}

# Restart a container
docker_restart_container() {
    local container="$1"
    local timeout="${2:-10}"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    log_info "Restarting container: $container"
    docker restart -t "$timeout" "$container"
}

# Remove a container
docker_remove_container() {
    local container="$1"
    local force="${2:-false}"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    if ! docker_container_exists "$container"; then
        log_warn "Container '$container' does not exist"
        return 0
    fi
    
    local args=()
    if [[ "$force" == "true" ]]; then
        args+=("-f")
        log_info "Force removing container: $container"
    else
        log_info "Removing container: $container"
    fi
    
    docker rm "${args[@]}" "$container"
}

# Run a container
docker_run_container() {
    local image="$1"
    shift
    check_docker_installed || return 1
    
    if [[ -z "$image" ]]; then
        log_error "Image name is required"
        return 1
    fi
    
    log_info "Running container from image: $image"
    docker run "$@" "$image"
}

# Execute command in container
docker_exec() {
    local container="$1"
    shift
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    if ! docker_container_is_running "$container"; then
        log_error "Container '$container' is not running"
        return 1
    fi
    
    log_debug "Executing in container '$container': $*"
    docker exec "$container" "$@"
}

# Execute interactive shell in container
docker_exec_shell() {
    local container="$1"
    local shell="${2:-/bin/bash}"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    if ! docker_container_is_running "$container"; then
        log_error "Container '$container' is not running"
        return 1
    fi
    
    log_info "Opening shell in container: $container"
    docker exec -it "$container" "$shell"
}

# Get container logs
docker_logs() {
    local container="$1"
    local follow="${2:-false}"
    local tail="${3:-}"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    local args=()
    
    if [[ "$follow" == "true" ]]; then
        args+=("-f")
    fi
    
    if [[ -n "$tail" ]]; then
        args+=("--tail" "$tail")
    fi
    
    docker logs "${args[@]}" "$container"
}

# Check if image exists
docker_image_exists() {
    local image="$1"
    check_docker_installed || return 1
    
    if [[ -z "$image" ]]; then
        log_error "Image name is required"
        return 1
    fi
    
    docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image}$"
}

# Pull an image
docker_pull_image() {
    local image="$1"
    check_docker_installed || return 1
    
    if [[ -z "$image" ]]; then
        log_error "Image name is required"
        return 1
    fi
    
    log_info "Pulling image: $image"
    docker pull "$image"
}

# Build an image
docker_build_image() {
    local image_name="$1"
    local dockerfile_path="${2:-.}"
    local build_context="${3:-.}"
    shift 3
    check_docker_installed || return 1
    
    if [[ -z "$image_name" ]]; then
        log_error "Image name is required"
        return 1
    fi
    
    log_info "Building image: $image_name"
    
    local args=("-t" "$image_name")
    
    if [[ "$dockerfile_path" != "." ]]; then
        args+=("-f" "$dockerfile_path")
    fi
    
    # Add any additional build args
    args+=("$@")
    
    args+=("$build_context")
    
    docker build "${args[@]}"
}

# Remove an image
docker_remove_image() {
    local image="$1"
    local force="${2:-false}"
    check_docker_installed || return 1
    
    if [[ -z "$image" ]]; then
        log_error "Image name is required"
        return 1
    fi
    
    if ! docker_image_exists "$image"; then
        log_warn "Image '$image' does not exist"
        return 0
    fi
    
    local args=()
    if [[ "$force" == "true" ]]; then
        args+=("-f")
        log_info "Force removing image: $image"
    else
        log_info "Removing image: $image"
    fi
    
    docker rmi "${args[@]}" "$image"
}

# Tag an image
docker_tag_image() {
    local source_image="$1"
    local target_image="$2"
    check_docker_installed || return 1
    
    if [[ -z "$source_image" ]] || [[ -z "$target_image" ]]; then
        log_error "Both source and target image names are required"
        return 1
    fi
    
    log_info "Tagging image: $source_image -> $target_image"
    docker tag "$source_image" "$target_image"
}

# Push an image to registry
docker_push_image() {
    local image="$1"
    check_docker_installed || return 1
    
    if [[ -z "$image" ]]; then
        log_error "Image name is required"
        return 1
    fi
    
    log_info "Pushing image: $image"
    docker push "$image"
}

# Clean up stopped containers
docker_cleanup_containers() {
    check_docker_installed || return 1
    log_info "Removing stopped containers"
    docker container prune -f
}

# Clean up unused images
docker_cleanup_images() {
    check_docker_installed || return 1
    log_info "Removing unused images"
    docker image prune -f
}

# Clean up everything (containers, images, volumes, networks)
docker_cleanup_all() {
    check_docker_installed || return 1
    log_warn "Removing all unused Docker resources"
    docker system prune -a -f --volumes
}

# Get container IP address
docker_container_ip() {
    local container="$1"
    check_docker_installed || return 1
    
    if [[ -z "$container" ]]; then
        log_error "Container name or ID is required"
        return 1
    fi
    
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container"
}

# Docker Compose helpers

# Check if docker-compose is installed
check_docker_compose_installed() {
    if command -v docker-compose &> /dev/null; then
        return 0
    elif docker compose version &> /dev/null; then
        return 0
    else
        log_error "docker-compose or 'docker compose' command not found"
        return 1
    fi
}

# Get docker-compose command (handles both standalone and plugin versions)
_docker_compose_cmd() {
    if command -v docker-compose &> /dev/null; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

# Start docker-compose services
docker_compose_up() {
    local compose_file="${1:-docker-compose.yml}"
    local detached="${2:-true}"
    check_docker_compose_installed || return 1
    
    local cmd
    cmd=$(_docker_compose_cmd)
    
    local args=("-f" "$compose_file" "up")
    
    if [[ "$detached" == "true" ]]; then
        args+=("-d")
    fi
    
    log_info "Starting docker-compose services"
    $cmd "${args[@]}"
}

# Stop docker-compose services
docker_compose_down() {
    local compose_file="${1:-docker-compose.yml}"
    local remove_volumes="${2:-false}"
    check_docker_compose_installed || return 1
    
    local cmd
    cmd=$(_docker_compose_cmd)
    
    local args=("-f" "$compose_file" "down")
    
    if [[ "$remove_volumes" == "true" ]]; then
        args+=("-v")
    fi
    
    log_info "Stopping docker-compose services"
    $cmd "${args[@]}"
}

# Restart docker-compose services
docker_compose_restart() {
    local compose_file="${1:-docker-compose.yml}"
    check_docker_compose_installed || return 1
    
    local cmd
    cmd=$(_docker_compose_cmd)
    
    log_info "Restarting docker-compose services"
    $cmd -f "$compose_file" restart
}

# View docker-compose logs
docker_compose_logs() {
    local compose_file="${1:-docker-compose.yml}"
    local follow="${2:-false}"
    check_docker_compose_installed || return 1
    
    local cmd
    cmd=$(_docker_compose_cmd)
    
    local args=("-f" "$compose_file" "logs")
    
    if [[ "$follow" == "true" ]]; then
        args+=("-f")
    fi
    
    $cmd "${args[@]}"
}
