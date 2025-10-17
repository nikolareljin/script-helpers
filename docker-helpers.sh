#!/usr/bin/env bash
#
# Docker Helper Functions
# Collection of helper functions for Docker operations
#

# Smart docker-compose detection and wrapper
# Detects whether 'docker compose' (v2) or 'docker-compose' (v1) is available
# and uses the appropriate command
docker_compose() {
    # Check if docker compose v2 is available (docker compose)
    if docker compose version &> /dev/null; then
        docker compose "$@"
    # Check if docker-compose v1 is available
    elif command -v docker-compose &> /dev/null; then
        docker-compose "$@"
    else
        echo "Error: Neither 'docker compose' nor 'docker-compose' is available on this system" >&2
        echo "Please install Docker Compose: https://docs.docker.com/compose/install/" >&2
        return 1
    fi
}

# SSH into a specific Docker container
# Usage: docker_ssh <container_name_or_id> [shell]
# Example: docker_ssh my-container bash
docker_ssh() {
    local container="${1}"
    local shell="${2:-/bin/bash}"
    
    if [ -z "$container" ]; then
        echo "Error: Container name or ID is required" >&2
        echo "Usage: docker_ssh <container_name_or_id> [shell]" >&2
        return 1
    fi
    
    # Check if container exists and is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$" && \
       ! docker ps --format '{{.ID}}' | grep -q "^${container}"; then
        echo "Error: Container '${container}' not found or not running" >&2
        echo "Available running containers:" >&2
        docker ps --format "  {{.Names}} ({{.ID}})" >&2
        return 1
    fi
    
    echo "Connecting to container: ${container}"
    
    # Try bash first, then sh if bash is not available
    if ! docker exec -it "${container}" "${shell}" 2>/dev/null; then
        if [ "${shell}" = "/bin/bash" ]; then
            echo "Bash not available, trying sh..." >&2
            docker exec -it "${container}" /bin/sh
        else
            echo "Error: Failed to connect to container with shell: ${shell}" >&2
            return 1
        fi
    fi
}

# Check Docker status and display information
# Usage: docker_status
docker_status() {
    echo "=== Docker Status ==="
    echo ""
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        echo "❌ Docker daemon is not running or not accessible"
        echo "Please start Docker daemon and try again"
        return 1
    fi
    
    echo "✅ Docker daemon is running"
    echo ""
    
    # Display Docker version
    echo "--- Docker Version ---"
    docker version --format 'Client: {{.Client.Version}}\nServer: {{.Server.Version}}'
    echo ""
    
    # Check docker-compose availability
    echo "--- Docker Compose ---"
    if docker compose version &> /dev/null; then
        docker compose version
    elif command -v docker-compose &> /dev/null; then
        docker-compose version
    else
        echo "⚠️  Docker Compose not found"
    fi
    echo ""
    
    # Display running containers
    echo "--- Running Containers ---"
    local running_count=$(docker ps -q | wc -l)
    if [ "$running_count" -eq 0 ]; then
        echo "No containers running"
    else
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    fi
    echo ""
    
    # Display all containers (including stopped)
    echo "--- All Containers ---"
    local total_count=$(docker ps -aq | wc -l)
    if [ "$total_count" -eq 0 ]; then
        echo "No containers found"
    else
        docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
    fi
    echo ""
    
    # Display images
    echo "--- Docker Images ---"
    local image_count=$(docker images -q | wc -l)
    if [ "$image_count" -eq 0 ]; then
        echo "No images found"
    else
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
    fi
    echo ""
    
    # Display volumes
    echo "--- Docker Volumes ---"
    local volume_count=$(docker volume ls -q | wc -l)
    if [ "$volume_count" -eq 0 ]; then
        echo "No volumes found"
    else
        docker volume ls
    fi
    echo ""
    
    # Display networks
    echo "--- Docker Networks ---"
    docker network ls
    echo ""
    
    # Display system-wide information
    echo "--- System Usage ---"
    docker system df
}

# List all Docker containers with enhanced information
# Usage: docker_list [--all]
docker_list() {
    local show_all=false
    
    if [ "$1" = "--all" ] || [ "$1" = "-a" ]; then
        show_all=true
    fi
    
    if [ "$show_all" = true ]; then
        echo "=== All Docker Containers ==="
        docker ps -a --format "table {{.Names}}\t{{.ID}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
    else
        echo "=== Running Docker Containers ==="
        docker ps --format "table {{.Names}}\t{{.ID}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
    fi
}

# Get logs from a specific container
# Usage: docker_logs <container_name_or_id> [lines]
docker_logs() {
    local container="${1}"
    local lines="${2:-50}"
    
    if [ -z "$container" ]; then
        echo "Error: Container name or ID is required" >&2
        echo "Usage: docker_logs <container_name_or_id> [lines]" >&2
        return 1
    fi
    
    echo "=== Last ${lines} log lines from ${container} ==="
    docker logs --tail "${lines}" "${container}"
}

# Follow logs from a specific container
# Usage: docker_logs_follow <container_name_or_id>
docker_logs_follow() {
    local container="${1}"
    
    if [ -z "$container" ]; then
        echo "Error: Container name or ID is required" >&2
        echo "Usage: docker_logs_follow <container_name_or_id>" >&2
        return 1
    fi
    
    echo "=== Following logs from ${container} (Ctrl+C to stop) ==="
    docker logs -f "${container}"
}

# Restart a specific container
# Usage: docker_restart <container_name_or_id>
docker_restart() {
    local container="${1}"
    
    if [ -z "$container" ]; then
        echo "Error: Container name or ID is required" >&2
        echo "Usage: docker_restart <container_name_or_id>" >&2
        return 1
    fi
    
    echo "Restarting container: ${container}"
    docker restart "${container}"
}

# Stop all running containers
# Usage: docker_stop_all
docker_stop_all() {
    local running=$(docker ps -q)
    
    if [ -z "$running" ]; then
        echo "No running containers to stop"
        return 0
    fi
    
    echo "Stopping all running containers..."
    echo "$running" | xargs docker stop
    echo "All containers stopped"
}

# Remove all stopped containers
# Usage: docker_clean_containers
docker_clean_containers() {
    local stopped=$(docker ps -aq -f status=exited)
    
    if [ -z "$stopped" ]; then
        echo "No stopped containers to remove"
        return 0
    fi
    
    echo "Removing all stopped containers..."
    echo "$stopped" | xargs docker rm
    echo "Stopped containers removed"
}

# Clean up Docker system (remove unused data)
# Usage: docker_cleanup [--all]
docker_cleanup() {
    if [ "$1" = "--all" ] || [ "$1" = "-a" ]; then
        echo "Removing all unused Docker data (containers, networks, images, volumes)..."
        docker system prune -a --volumes -f
    else
        echo "Removing unused Docker data (stopped containers, dangling images, unused networks)..."
        docker system prune -f
    fi
    echo "Cleanup complete"
}
