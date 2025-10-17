#!/usr/bin/env bash

# example-usage.sh
# Demonstrates how to use the script-helpers library

# Source the script helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../script-helpers.sh"

# Example 1: Logging
log_section "Logging Examples"
log_info "This is an info message"
log_success "This is a success message"
log_warn "This is a warning message"
log_error "This is an error message"
log_debug "This is a debug message (only visible when LOG_LEVEL=0)"

# Example 2: Git operations
log_section "Git Helper Examples"

if git_is_repo; then
    log_info "Current repository: $(git_repo_name)"
    log_info "Current branch: $(git_current_branch)"
    log_info "Repository root: $(git_repo_root)"
    log_info "Current commit: $(git_current_commit true)"
    
    if git_is_clean; then
        log_success "Working directory is clean"
    else
        log_warn "Working directory has uncommitted changes"
    fi
    
    log_info "Available branches:"
    git_list_branches_local | while read -r branch; do
        echo "  - $branch"
    done
else
    log_warn "Not in a git repository"
fi

# Example 3: Docker operations (if docker is available)
log_section "Docker Helper Examples"

if check_docker_installed && docker_is_running; then
    log_info "Docker is installed and running"
    
    log_info "Running containers:"
    docker_list_containers false
    
    log_info "Available images:"
    docker_list_images
else
    log_warn "Docker is not available or not running"
fi

# Example 4: Dialog (only if dialog is installed)
log_section "Dialog Examples"

if check_dialog_installed; then
    log_info "Dialog is installed. Examples:"
    log_info "  - dialog_msgbox \"Title\" \"Message\""
    log_info "  - dialog_yesno \"Title\" \"Question?\""
    log_info "  - dialog_inputbox \"Title\" \"Enter value:\""
    log_info "  - dialog_menu \"Title\" \"Choose:\" \"1\" \"Option 1\" \"2\" \"Option 2\""
    
    # Uncomment to test interactively:
    # dialog_msgbox "Example" "This is an example message box"
    # if dialog_yesno "Example" "Do you want to continue?"; then
    #     log_info "User selected Yes"
    # else
    #     log_info "User selected No"
    # fi
else
    log_warn "Dialog is not installed"
    log_info "Install with: sudo apt-get install dialog"
fi

log_section "Example Complete"
log_success "All examples executed successfully!"
