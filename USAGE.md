# Usage Guide

This document provides quick start examples for using script-helpers.

## Quick Start

### Using as a Git Submodule (Recommended)

1. Add to your repository:
```bash
git submodule add https://github.com/nikolareljin/script-helpers.git scripts/helpers
git submodule update --init --recursive
```

2. In your bash script:
```bash
#!/usr/bin/env bash

# Source the helpers
source "$(dirname "$0")/scripts/helpers/script-helpers.sh"

# Use the functions
log_info "Starting deployment..."
current_branch=$(git_current_branch)
log_info "Deploying from branch: $current_branch"
```

### Standalone Usage

```bash
# Clone the repository
git clone https://github.com/nikolareljin/script-helpers.git

# Source in your scripts
source /path/to/script-helpers/script-helpers.sh
```

## Common Patterns

### 1. Git Branch Selection with Dialog

```bash
#!/usr/bin/env bash
source ./script-helpers.sh

# Select a branch interactively
branch=$(git_select_branch_dialog "Select Branch" "Choose branch to deploy:")
if [[ -n "$branch" ]]; then
    git_checkout_branch "$branch"
    log_success "Switched to branch: $branch"
fi
```

### 2. Interactive User Confirmation

```bash
#!/usr/bin/env bash
source ./script-helpers.sh

if dialog_yesno "Confirm Action" "Do you want to delete the container?"; then
    docker_remove_container "myapp" true
    log_success "Container removed"
else
    log_info "Action cancelled"
fi
```

### 3. Progress Indicator

```bash
#!/usr/bin/env bash
source ./script-helpers.sh

{
    for i in {0..100}; do
        echo $i
        # Simulate work
        sleep 0.1
    done
} | dialog_gauge "Processing" "Please wait while processing..."
```

### 4. Comprehensive Deployment Script

```bash
#!/usr/bin/env bash
set -e

# Source helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/helpers/script-helpers.sh"

log_section "Starting Deployment"

# Check prerequisites
if ! check_docker_installed || ! docker_is_running; then
    log_error "Docker is not available"
    exit 1
fi

if ! git_is_repo; then
    log_error "Not in a git repository"
    exit 1
fi

# Get current status
log_info "Repository: $(git_repo_name)"
log_info "Branch: $(git_current_branch)"
log_info "Commit: $(git_current_commit true)"

# Check working directory
if ! git_is_clean; then
    log_warn "Working directory has uncommitted changes"
    if ! dialog_yesno "Continue?" "Continue with uncommitted changes?"; then
        log_info "Deployment cancelled"
        exit 0
    fi
fi

# Pull latest changes
log_info "Pulling latest changes..."
git_pull_latest

# Build Docker image
log_info "Building Docker image..."
docker_build_image "myapp:latest" "Dockerfile" "."

# Stop old container
if docker_container_is_running "myapp"; then
    log_info "Stopping old container..."
    docker_stop_container "myapp"
fi

# Remove old container
if docker_container_exists "myapp"; then
    log_info "Removing old container..."
    docker_remove_container "myapp"
fi

# Start new container
log_info "Starting new container..."
docker_run_container "myapp:latest" -d --name myapp -p 8080:8080

log_section "Deployment Complete"
log_success "Application is now running!"
log_info "Container logs:"
docker_logs "myapp" false 50
```

### 5. Multi-Environment Selection

```bash
#!/usr/bin/env bash
source ./script-helpers.sh

env=$(dialog_menu "Select Environment" "Choose deployment target:" \
    "dev" "Development environment" \
    "staging" "Staging environment" \
    "prod" "Production environment")

case "$env" in
    dev)
        log_info "Deploying to development"
        # deployment logic
        ;;
    staging)
        log_info "Deploying to staging"
        # deployment logic
        ;;
    prod)
        log_warn "Deploying to PRODUCTION"
        if dialog_yesno "Confirm" "Are you sure you want to deploy to PRODUCTION?"; then
            # production deployment
            log_success "Deployed to production"
        fi
        ;;
esac
```

### 6. Automated PR Creation

```bash
#!/usr/bin/env bash
source ./script-helpers.sh

# Create feature branch
feature_name=$(dialog_inputbox "Feature Name" "Enter feature name:")
branch_name="feature/${feature_name}"

git_create_branch "$branch_name"

# Make changes...
# git add and commit...

# Push and create PR
git_push_changes origin "$branch_name"
git_create_pr_github \
    "Add $feature_name" \
    "This PR implements $feature_name feature" \
    "main" \
    false

log_success "Pull request created!"
```

## Environment Variables

### Logging Configuration

```bash
# Set log level (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR)
export LOG_LEVEL=1

# Disable timestamps
export LOG_TIMESTAMPS=0
```

### Dialog Configuration

Dialog size is automatically calculated as 85% of terminal size by default.
You can override this in individual calls:

```bash
# Use 70% of screen size
dialog_menu "Title" "Message" 70 "1" "Option 1" "2" "Option 2"
```

## Testing Your Scripts

Always test your scripts thoroughly:

```bash
# Test with different log levels
LOG_LEVEL=0 ./your-script.sh  # Debug mode
LOG_LEVEL=1 ./your-script.sh  # Normal mode
LOG_LEVEL=2 ./your-script.sh  # Warnings only

# Test without dialog (for CI/CD)
# Use git_select_branch_prompt instead of git_select_branch_dialog
```

## See Also

- [README.md](README.md) - Complete documentation
- [examples/example-usage.sh](examples/example-usage.sh) - Working examples
