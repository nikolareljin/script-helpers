# script-helpers

Helper bash scripts for common actions in maintaining directories, git repos, logging, dialogs, docker, OS-specific operations, and GitHub management.

## Features

This repository provides a collection of bash helper scripts organized into three main modules:

### 1. Docker Helpers (`docker-helpers.sh`)
- **Smart docker-compose wrapper**: Automatically detects and uses `docker compose` (v2) or `docker-compose` (v1)
- **Container SSH access**: Easy SSH/shell access to running containers
- **Docker status checking**: Comprehensive Docker system status and information
- **Container management**: List, restart, stop, and clean up containers
- **Log viewing**: View and follow container logs

### 2. OS-Specific Helpers (`os-helpers.sh`)
- **OS detection**: Detect macOS, Linux (with distro detection), or Windows
- **Package manager detection**: Automatically detect available package managers
- **Smart package installation**: Install packages with automatic OS/package manager detection
- **Platform-specific installers**: Support for Homebrew, apt, dnf, yum, pacman, apk, Chocolatey, and winget
- **System information**: Display comprehensive system details
- **Development tools**: Quick installation of common development tools

### 3. GitHub Helpers (`github-helpers.sh`)
- **Repository management**: Create, clone, and view repository information
- **Pull request operations**: Create, list, view, and merge pull requests
- **Issue tracking**: Create and list issues
- **Team management**: Add teams to repositories with specific permissions
- **Webhook management**: Add and list webhooks
- **GitHub Actions**: Create workflow files and view workflow runs
- **Authentication checking**: Verify GitHub CLI installation and authentication

## Installation

1. Clone this repository:
```bash
git clone https://github.com/nikolareljin/script-helpers.git
cd script-helpers
```

2. Source the main script in your bash scripts or shell:
```bash
source /path/to/script-helpers.sh
```

Or add it to your `.bashrc` or `.bash_profile`:
```bash
echo 'source /path/to/script-helpers.sh' >> ~/.bashrc
```

## Usage

### Quick Start

```bash
# Load all helper functions
source script-helpers.sh

# See available functions
bash script-helpers.sh list

# Get help
bash script-helpers.sh help
```

### Docker Examples

```bash
# Check Docker status
docker_status

# SSH into a container
docker_ssh my-container

# Use docker-compose (auto-detects v1 or v2)
docker_compose up -d
docker_compose down

# View container logs
docker_logs my-container 50

# List all containers
docker_list --all

# Clean up Docker system
docker_cleanup
```

### OS-Specific Examples

```bash
# Detect OS
OS=$(detect_os)
echo "Running on: $OS"

# Display system information
system_info

# Smart package installation (auto-detects OS and package manager)
install_packages git curl wget vim

# OS-specific installation
install_macos node npm              # macOS with Homebrew
install_linux_apt python3 pip       # Ubuntu/Debian
install_linux_dnf nodejs            # Fedora
install_windows_choco git           # Windows with Chocolatey

# Check if command exists
if command_exists docker; then
    echo "Docker is installed"
fi

# Install common development tools
install_dev_tools
```

### GitHub Examples

> **Note**: GitHub helpers require [GitHub CLI](https://cli.github.com/) to be installed and authenticated (`gh auth login`).

```bash
# Check GitHub CLI status
github_status

# Create a pull request
github_create_pr main feature-branch "Add new feature" "Detailed description"

# Add a webhook to a repository
github_add_webhook owner/repo https://example.com/webhook push,pull_request

# Add a team to a repository with push permission
github_add_team owner/repo my-team push

# Create a GitHub Actions workflow
github_create_workflow "CI Pipeline" ci.yml

# Create an issue
github_create_issue "Bug: Something is broken" "Detailed description"

# List pull requests
github_list_prs owner/repo open

# Clone a repository
github_clone owner/repo local-directory

# Create a new repository
github_create_repo my-new-repo --public "My new project"

# List webhooks
github_list_webhooks owner/repo
```

## Function Reference

### Docker Functions

| Function | Description |
|----------|-------------|
| `docker_compose` | Smart wrapper that uses available docker-compose command |
| `docker_ssh <container> [shell]` | SSH/shell into a running container |
| `docker_status` | Display comprehensive Docker status |
| `docker_list [--all]` | List running (or all) containers |
| `docker_logs <container> [lines]` | View container logs |
| `docker_logs_follow <container>` | Follow container logs in real-time |
| `docker_restart <container>` | Restart a container |
| `docker_stop_all` | Stop all running containers |
| `docker_clean_containers` | Remove all stopped containers |
| `docker_cleanup [--all]` | Clean up Docker system |

### OS Functions

| Function | Description |
|----------|-------------|
| `detect_os` | Detect OS (macos, linux, windows, unknown) |
| `detect_linux_distro` | Detect Linux distribution |
| `get_package_manager` | Get available package manager |
| `install_packages <pkgs...>` | Smart install with auto-detection |
| `install_macos <pkgs...>` | Install packages on macOS (Homebrew) |
| `install_linux_apt <pkgs...>` | Install packages with apt (Debian/Ubuntu) |
| `install_linux_dnf <pkgs...>` | Install packages with dnf (Fedora) |
| `install_linux_yum <pkgs...>` | Install packages with yum (CentOS/RHEL) |
| `install_linux_pacman <pkgs...>` | Install packages with pacman (Arch) |
| `install_linux_apk <pkgs...>` | Install packages with apk (Alpine) |
| `install_windows_choco <pkgs...>` | Install packages with Chocolatey |
| `install_windows_winget <pkgs...>` | Install packages with winget |
| `system_info` | Display system information |
| `command_exists <cmd>` | Check if command is available |
| `install_dev_tools` | Install common development tools |

### GitHub Functions

| Function | Description |
|----------|-------------|
| `github_status` | Check GitHub CLI status and authentication |
| `github_add_team <repo> <team> [perm]` | Add team to repository |
| `github_add_webhook <repo> <url> [events]` | Add webhook to repository |
| `github_list_webhooks <repo>` | List repository webhooks |
| `github_create_workflow <name> <file>` | Create GitHub Actions workflow |
| `github_create_pr <base> <head> <title> [body]` | Create pull request |
| `github_list_prs [repo] [state]` | List pull requests |
| `github_view_pr <number> [repo]` | View pull request details |
| `github_merge_pr <number> [method]` | Merge pull request |
| `github_create_issue <title> [body]` | Create new issue |
| `github_list_issues [repo] [state]` | List issues |
| `github_clone <repo> [dir]` | Clone repository |
| `github_create_repo <name> [visibility] [desc]` | Create repository |
| `github_repo_info [repo]` | View repository information |
| `github_workflow_list [repo]` | List workflows |
| `github_workflow_runs <workflow> [repo]` | View workflow runs |

## Examples

Check the `examples/` directory for complete usage examples:
- `examples/docker-example.sh` - Docker operations examples
- `examples/os-example.sh` - OS detection and package management examples
- `examples/github-example.sh` - GitHub operations examples

To run an example:
```bash
bash examples/docker-example.sh
bash examples/os-example.sh
bash examples/github-example.sh
```

## Requirements

### Core Requirements
- Bash 4.0 or later
- Basic Unix utilities (grep, awk, sed, etc.)

### Docker Helpers
- Docker installed and running
- Docker Compose (v1 or v2)

### GitHub Helpers
- [GitHub CLI (gh)](https://cli.github.com/) installed and authenticated
- Run `gh auth login` before using GitHub functions

### OS-Specific Helpers
- Package manager appropriate for your OS:
  - macOS: Homebrew (will attempt to install if missing)
  - Linux: apt, dnf, yum, pacman, or apk
  - Windows: Chocolatey or winget

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Author

Nik Reljin

## Support

For issues, questions, or contributions, please visit:
https://github.com/nikolareljin/script-helpers
