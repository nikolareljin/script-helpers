<<<<<<< HEAD
script-helpers
================

Reusable Bash helpers extracted from projects in this workspace. Source modules you need (docker, logging, dialog, file, json, ports, etc.) and reuse them across scripts.

Quick start
-----------

- Add as a subfolder (recommended for local repo):
  - Copy or symlink `script-helpers` into your project (e.g., `scripts/script-helpers`).
  - Source the loader and import modules in your script:

    ```bash
    #!/usr/bin/env bash
    set -euo pipefail
    SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(dirname "$0")/script-helpers}"
    # Load the loader
    # shellcheck source=/dev/null
    source "$SCRIPT_HELPERS_DIR/helpers.sh"
    # Import only what you need
    shlib_import logging docker dialog file json env ports browser traps certs hosts clipboard
    ```

- Git submodule (once this repo is hosted remotely):
  - `git submodule add <remote-url> scripts/script-helpers`
  - Source as shown above.

Loader and modules
------------------

- `helpers.sh`: resolves library path and provides `shlib_import` to source modules by name.
- Modules live in `lib/*.sh` and are small, dependency-light files:
  - `logging.sh` — color constants and logging helpers (`print_info`, `log_info`, etc.).
  - `dialog.sh` — dialog sizing helpers and `get_value`.
  - `os.sh` — OS detection (`get_os`, `getos`), clipboard helpers.
  - `deps.sh` — install utilities (`install_dependencies`) where applicable.
  - `docker.sh` — docker compose detection/wrapper (`docker_compose`, `run_docker_compose_command`, etc.).
  - `file.sh` — file/dir helpers, checksum verification.
  - `json.sh` — json utilities (`json_escape`, `format_response`, `format_md_response`).
  - `env.sh` — `.env` loading, `require_env`, project-root detection.
  - `ports.sh` — port usage/availability helpers.
  - `browser.sh` — `open_url`, `open_frontend_when_ready`.
  - `traps.sh` — cleanup and signal traps.
  - `certs.sh` — self-signed cert creation and trust-store helpers.
  - `hosts.sh` — `/etc/hosts` helpers.
  - `clipboard.sh` — `copy_to_clipboard`.

Compatibility notes
-------------------

- Function names from existing projects are preserved where possible. Where multiple variants existed, this library accepts both styles (e.g., `print_color` accepts either ANSI code constants or color names like `red`, `green`).
- Some functions (e.g., `download_iso`) expect data like `DISTROS` associative array to be supplied by the caller project.
- `install_dependencies` may run `sudo` and perform network installs; use cautiously in CI or locked-down environments.

Example usage
-------------

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/script-helpers}"
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging docker env file json

print_info "Project root: $(get_project_root)"
compose_cmd=$(get_docker_compose_cmd)
log_info "Compose cmd: $compose_cmd"
```

Testing locally
---------------

- Source `helpers.sh` from a shell and import modules to try functions interactively:

```bash
source ./helpers.sh
shlib_import logging json
print_success "It works!"
```

Conventions
-----------

- Shell: POSIX-friendly where possible; scripts should set `set -euo pipefail` in the caller.
- Filenames are `snake_case`. Functions are preserved from original includes for compatibility.

=======
# script-helpers

A collection of bash helper scripts for common operations including git repository management, interactive dialogs, logging, and Docker operations. Designed to be used as a git submodule in multiple repositories.

## Features

- **Git Helpers**: Branch management, repository operations, PR creation
- **Dialog Helpers**: Interactive UI using the `dialog` CLI tool with automatic sizing
- **Logging**: Colored, timestamped logging with multiple log levels
- **Docker Helpers**: Container and image management, docker-compose operations

## Installation

### As a Git Submodule

```bash
# Add as a submodule to your repository
git submodule add https://github.com/nikolareljin/script-helpers.git scripts/helpers

# Initialize and update the submodule
git submodule update --init --recursive
```

### Standalone Clone

```bash
git clone https://github.com/nikolareljin/script-helpers.git
```

## Usage

### Basic Usage

Source the main script in your bash scripts:

```bash
#!/usr/bin/env bash

# Source the script helpers
source /path/to/script-helpers.sh

# Now you have access to all helper functions
log_info "Starting my script"
git_current_branch
docker_list_containers
```

### Individual Module Usage

You can also source individual modules:

```bash
source /path/to/script-helpers/lib/logging-helpers.sh
source /path/to/script-helpers/lib/git-helpers.sh
```

## Logging Helpers

### Available Functions

- `log_debug "message"` - Debug level logging (only shown when LOG_LEVEL=0)
- `log_info "message"` - Info level logging
- `log_warn "message"` - Warning level logging
- `log_error "message"` - Error level logging
- `log_success "message"` - Success message logging
- `log_section "title"` - Section header logging
- `log_exec command args...` - Log and execute a command

### Configuration

```bash
# Set log level (default: INFO)
export LOG_LEVEL=0  # DEBUG
export LOG_LEVEL=1  # INFO
export LOG_LEVEL=2  # WARN
export LOG_LEVEL=3  # ERROR

# Enable/disable timestamps (default: enabled)
export LOG_TIMESTAMPS=1  # enabled
export LOG_TIMESTAMPS=0  # disabled
```

### Example

```bash
log_section "Starting Deployment"
log_info "Deploying application version 1.0"
log_warn "This will override the current deployment"
log_error "Deployment failed!"
log_success "Deployment completed successfully"
```

## Dialog Helpers

Interactive UI components using the `dialog` CLI tool. Automatically calculates optimal dialog size based on terminal dimensions (default 85% of screen).

### Prerequisites

```bash
# Ubuntu/Debian
sudo apt-get install dialog

# CentOS/RHEL
sudo yum install dialog

# macOS
brew install dialog
```

### Available Functions

- `dialog_msgbox "title" "message" [percentage]` - Display a message box
- `dialog_yesno "title" "question" [percentage]` - Yes/No dialog
- `dialog_inputbox "title" "prompt" [default] [percentage]` - Input dialog
- `dialog_passwordbox "title" "prompt" [percentage]` - Password input
- `dialog_menu "title" "text" [percentage] "tag1" "item1" "tag2" "item2" ...` - Menu selection
- `dialog_checklist "title" "text" [percentage] "tag1" "item1" "status1" ...` - Multi-select list
- `dialog_radiolist "title" "text" [percentage] "tag1" "item1" "status1" ...` - Radio button list
- `dialog_gauge "title" "text" [percentage]` - Progress bar (reads percentage from stdin)
- `dialog_textbox "title" "file" [percentage]` - Display file contents

### Example

```bash
# Message box
dialog_msgbox "Welcome" "Welcome to the installer"

# Yes/No dialog
if dialog_yesno "Confirm" "Do you want to continue?"; then
    log_info "User confirmed"
fi

# Input dialog
username=$(dialog_inputbox "Username" "Enter your username:")
echo "Username: $username"

# Menu selection
choice=$(dialog_menu "Select Option" "Choose an action:" \
    "1" "Install" \
    "2" "Update" \
    "3" "Remove")
echo "Selected: $choice"

# Progress bar
for i in {1..100}; do
    echo $i
    sleep 0.1
done | dialog_gauge "Installing" "Please wait..."
```

## Git Helpers

Comprehensive git repository management functions.

### Available Functions

#### Branch Management
- `git_current_branch` - Get current branch name
- `git_branch_exists "branch"` - Check if branch exists (local or remote)
- `git_branch_exists_local "branch"` - Check if branch exists locally
- `git_branch_exists_remote "branch" [remote]` - Check if branch exists remotely
- `git_list_branches_local` - List all local branches
- `git_list_branches_remote [remote]` - List all remote branches
- `git_list_branches_all` - List all branches (local and remote, deduplicated)
- `git_checkout_branch "branch" [create_if_missing]` - Checkout branch
- `git_create_branch "name" [base_branch]` - Create new branch
- `git_delete_branch "branch" [force]` - Delete branch

#### Interactive Selection
- `git_select_branch_dialog [title] [message]` - Select branch using dialog
- `git_select_branch_prompt [prompt]` - Select branch using simple prompt

#### Repository Operations
- `git_clone_repo "url" [target_dir] [branch]` - Clone repository
- `git_pull_latest [remote] [branch]` - Pull latest changes
- `git_push_changes [remote] [branch] [force]` - Push changes
- `git_fetch [remote]` - Fetch from remote
- `git_is_repo` - Check if in a git repository
- `git_is_clean` - Check if working directory is clean
- `git_repo_root` - Get repository root directory
- `git_repo_name` - Get repository name
- `git_remote_url [remote]` - Get remote URL
- `git_current_commit [short]` - Get current commit hash

#### Stash Operations
- `git_stash [message]` - Stash changes
- `git_stash_pop` - Pop stashed changes
- `git_stash_list` - List stashes

#### Pull Requests
- `git_create_pr_github "title" [body] [base_branch] [draft]` - Create PR using GitHub CLI

### Example

```bash
# Check current status
log_info "Current branch: $(git_current_branch)"
log_info "Repository: $(git_repo_name)"

# List and select branch
branch=$(git_select_branch_dialog "Switch Branch" "Select a branch:")
if [[ -n "$branch" ]]; then
    git_checkout_branch "$branch"
fi

# Create and push a new branch
git_create_branch "feature/new-feature"
# Make some changes...
git_push_changes origin "feature/new-feature"

# Create a pull request
git_create_pr_github "Add new feature" "This PR adds a new feature" "main"
```

## Docker Helpers

Helper functions for Docker container and image management.

### Available Functions

#### Container Management
- `docker_container_exists "container"` - Check if container exists
- `docker_container_is_running "container"` - Check if container is running
- `docker_list_containers [all]` - List containers
- `docker_start_container "container"` - Start container
- `docker_stop_container "container" [timeout]` - Stop container
- `docker_restart_container "container" [timeout]` - Restart container
- `docker_remove_container "container" [force]` - Remove container
- `docker_run_container "image" [args...]` - Run a new container
- `docker_exec "container" command [args...]` - Execute command in container
- `docker_exec_shell "container" [shell]` - Open interactive shell
- `docker_logs "container" [follow] [tail]` - Get container logs
- `docker_container_ip "container"` - Get container IP address

#### Image Management
- `docker_image_exists "image"` - Check if image exists
- `docker_list_images` - List all images
- `docker_pull_image "image"` - Pull an image
- `docker_build_image "name" [dockerfile] [context] [args...]` - Build an image
- `docker_remove_image "image" [force]` - Remove an image
- `docker_tag_image "source" "target"` - Tag an image
- `docker_push_image "image"` - Push image to registry

#### Cleanup
- `docker_cleanup_containers` - Remove stopped containers
- `docker_cleanup_images` - Remove unused images
- `docker_cleanup_all` - Remove all unused resources

#### Docker Compose
- `docker_compose_up [file] [detached]` - Start services
- `docker_compose_down [file] [remove_volumes]` - Stop services
- `docker_compose_restart [file]` - Restart services
- `docker_compose_logs [file] [follow]` - View logs

### Example

```bash
# Check Docker status
if docker_is_running; then
    log_info "Docker is running"
fi

# List running containers
docker_list_containers

# Manage a container
if docker_container_is_running "myapp"; then
    docker_stop_container "myapp"
fi

docker_start_container "myapp"
docker_logs "myapp" false 100  # Show last 100 lines

# Build and push an image
docker_build_image "myapp:latest" "Dockerfile" "."
docker_tag_image "myapp:latest" "registry.example.com/myapp:latest"
docker_push_image "registry.example.com/myapp:latest"

# Docker Compose operations
docker_compose_up "docker-compose.yml" true
docker_compose_logs "docker-compose.yml" true
```

## Complete Example Script

See `examples/example-usage.sh` for a complete example demonstrating all features.

```bash
# Run the example
bash examples/example-usage.sh
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

See the [LICENSE](LICENSE) file for details.
>>>>>>> 0aed43189ff9630ea06b8af5618689a6375b0326
