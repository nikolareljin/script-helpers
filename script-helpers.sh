#!/usr/bin/env bash
#
# Script Helpers - Main Entry Point
# Collection of helper bash scripts for Docker, OS-specific operations, and GitHub
#
# Usage:
#   Source this file in your bash script or shell:
#   source /path/to/script-helpers.sh
#
# Or run directly to see available functions:
#   bash script-helpers.sh help
#

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Source all helper modules
source "${SCRIPT_DIR}/docker-helpers.sh"
source "${SCRIPT_DIR}/os-helpers.sh"
source "${SCRIPT_DIR}/github-helpers.sh"

# Display help information
show_help() {
    cat <<EOF
=============================================================================
                          Script Helpers
=============================================================================

A collection of helper bash scripts for common operations with Docker,
OS-specific package management, and GitHub.

USAGE:
    source script-helpers.sh         # Load all helper functions
    script-helpers.sh help           # Show this help message
    script-helpers.sh list           # List all available functions

MODULES:
    1. Docker Helpers (docker-helpers.sh)
       - Docker container management
       - Docker Compose wrapper with smart detection
       - Container SSH access

    2. OS Helpers (os-helpers.sh)
       - OS detection (macOS, Linux, Windows)
       - Package manager detection and smart installation
       - System information utilities

    3. GitHub Helpers (github-helpers.sh)
       - Repository management
       - Pull request operations
       - Issue tracking
       - Webhook and team management
       - GitHub Actions workflow helpers

EXAMPLES:
    # Docker operations
    source script-helpers.sh
    docker_status                    # Check Docker status
    docker_ssh my-container          # SSH into a container
    docker_compose up -d             # Run docker-compose (auto-detect v1/v2)

    # Package installation
    install_packages git curl wget   # Smart install based on OS
    install_macos node               # macOS specific
    install_linux_apt python3        # Linux apt specific

    # GitHub operations
    github_create_pr main feature "My Feature" "Description"
    github_add_webhook owner/repo https://example.com/hook
    github_add_team owner/repo my-team push

For more information, visit:
    https://github.com/nikolareljin/script-helpers

=============================================================================
EOF
}

# List all available functions
list_functions() {
    cat <<EOF
=============================================================================
                     Available Helper Functions
=============================================================================

DOCKER HELPERS:
    docker_compose                 - Smart docker-compose wrapper (v1/v2)
    docker_ssh                     - SSH into a specific container
    docker_status                  - Check Docker status and display info
    docker_list                    - List Docker containers
    docker_logs                    - Get logs from a container
    docker_logs_follow             - Follow container logs
    docker_restart                 - Restart a container
    docker_stop_all                - Stop all running containers
    docker_clean_containers        - Remove all stopped containers
    docker_cleanup                 - Clean up Docker system

OS HELPERS:
    detect_os                      - Detect operating system
    detect_linux_distro            - Detect Linux distribution
    get_package_manager            - Get package manager for current OS
    install_packages               - Smart package installer
    install_macos                  - Install packages on macOS
    install_linux_apt              - Install packages with apt
    install_linux_dnf              - Install packages with dnf
    install_linux_yum              - Install packages with yum
    install_linux_pacman           - Install packages with pacman
    install_linux_apk              - Install packages with apk
    install_windows_choco          - Install packages with Chocolatey
    install_windows_winget         - Install packages with winget
    system_info                    - Display system information
    command_exists                 - Check if a command exists
    install_dev_tools              - Install common development tools

GITHUB HELPERS:
    check_gh_installed             - Check if GitHub CLI is installed
    check_gh_authenticated         - Check if GitHub CLI is authenticated
    github_add_team                - Add a team to a repository
    github_add_webhook             - Add a webhook to a repository
    github_list_webhooks           - List webhooks for a repository
    github_create_workflow         - Create a GitHub Actions workflow
    github_create_pr               - Create a pull request
    github_list_prs                - List pull requests
    github_view_pr                 - View pull request details
    github_merge_pr                - Merge a pull request
    github_create_issue            - Create a new issue
    github_list_issues             - List issues
    github_clone                   - Clone a repository
    github_create_repo             - Create a new repository
    github_repo_info               - View repository information
    github_workflow_list           - List workflows
    github_workflow_runs           - View workflow runs
    github_status                  - Display GitHub CLI status

=============================================================================

To see detailed help for any function, use:
    type <function_name>

Example:
    type docker_ssh

=============================================================================
EOF
}

# Main execution when script is run directly (not sourced)
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    case "${1:-}" in
        help|--help|-h)
            show_help
            ;;
        list|--list|-l)
            list_functions
            ;;
        *)
            show_help
            ;;
    esac
else
    # Script is being sourced
    echo "✅ Script Helpers loaded successfully"
    echo "Run 'script-helpers.sh help' to see available functions"
fi
