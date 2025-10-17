#!/usr/bin/env bash
#
# Docker Helpers - Example Usage
#

# Source the script helpers
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
source "${SCRIPT_DIR}/script-helpers.sh"

echo "=== Docker Helpers Example Usage ==="
echo ""

# Check Docker status
echo "1. Checking Docker status..."
docker_status
echo ""

# List running containers
echo "2. Listing running containers..."
docker_list
echo ""

# Example: Use docker-compose wrapper
echo "3. Using docker_compose wrapper..."
echo "   This will automatically use 'docker compose' or 'docker-compose'"
echo "   depending on what's available on your system"
echo ""
echo "   Command: docker_compose --version"
docker_compose --version
echo ""

# Example: SSH into a container (commented out - requires running container)
# echo "4. SSH into a container..."
# docker_ssh my-container
# echo ""

# Example: Get container logs (commented out - requires running container)
# echo "5. Getting container logs..."
# docker_logs my-container 20
# echo ""

# Example: List all containers including stopped ones
echo "4. Listing all containers (including stopped)..."
docker_list --all
echo ""

echo "=== Example completed ==="
echo ""
echo "To use these functions in your own scripts:"
echo "  source ${SCRIPT_DIR}/script-helpers.sh"
echo "  docker_status"
echo "  docker_ssh <container-name>"
echo "  docker_compose up -d"
