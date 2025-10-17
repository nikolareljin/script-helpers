#!/usr/bin/env bash

# git-helpers.sh
# Provides git repository helper methods

# Guard against multiple sourcing
[[ -n "${_GIT_HELPERS_LOADED:-}" ]] && return 0
readonly _GIT_HELPERS_LOADED=1

# Source logging and dialog helpers if available
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

if [[ -f "$SCRIPT_DIR/dialog-helpers.sh" ]]; then
    source "$SCRIPT_DIR/dialog-helpers.sh"
fi

# Check if git is installed
check_git_installed() {
    if ! command -v git &> /dev/null; then
        log_error "git command not found. Please install git."
        return 1
    fi
    return 0
}

# Check if we're in a git repository
git_is_repo() {
    git rev-parse --is-inside-work-tree &> /dev/null
}

# Get current branch name
git_current_branch() {
    check_git_installed || return 1
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Check if a branch exists locally
git_branch_exists_local() {
    local branch="$1"
    check_git_installed || return 1
    
    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        return 1
    fi
    
    git show-ref --verify --quiet "refs/heads/$branch"
}

# Check if a branch exists remotely
git_branch_exists_remote() {
    local branch="$1"
    local remote="${2:-origin}"
    check_git_installed || return 1
    
    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        return 1
    fi
    
    git ls-remote --heads "$remote" "$branch" | grep -q "$branch"
}

# Check if a branch exists (local or remote)
git_branch_exists() {
    local branch="$1"
    local remote="${2:-origin}"
    
    git_branch_exists_local "$branch" || git_branch_exists_remote "$branch" "$remote"
}

# List all local branches
git_list_branches_local() {
    check_git_installed || return 1
    git branch --format='%(refname:short)' | sort
}

# List all remote branches
git_list_branches_remote() {
    local remote="${1:-origin}"
    check_git_installed || return 1
    git branch -r --format='%(refname:short)' | grep "^$remote/" | sed "s|^$remote/||" | grep -v HEAD | sort
}

# List all branches (local and remote, deduplicated)
git_list_branches_all() {
    check_git_installed || return 1
    {
        git_list_branches_local
        git_list_branches_remote
    } | sort -u
}

# Checkout a branch (create if doesn't exist)
git_checkout_branch() {
    local branch="$1"
    local create_if_missing="${2:-false}"
    
    check_git_installed || return 1
    
    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        return 1
    fi
    
    if git_branch_exists_local "$branch"; then
        log_info "Checking out existing branch: $branch"
        git checkout "$branch"
    elif git_branch_exists_remote "$branch"; then
        log_info "Checking out remote branch: $branch"
        git checkout -b "$branch" "origin/$branch"
    elif [[ "$create_if_missing" == "true" ]]; then
        log_info "Creating new branch: $branch"
        git checkout -b "$branch"
    else
        log_error "Branch '$branch' does not exist"
        return 1
    fi
}

# Select a branch using dialog
git_select_branch_dialog() {
    local title="${1:-Select Branch}"
    local message="${2:-Choose a branch to checkout:}"
    local current_branch
    current_branch=$(git_current_branch)
    
    check_git_installed || return 1
    
    # Check if dialog helpers are available
    if ! command -v dialog &> /dev/null; then
        log_error "dialog is not installed. Please install dialog or use git_select_branch_prompt instead."
        return 1
    fi
    
    # Get all branches
    local branches
    mapfile -t branches < <(git_list_branches_all)
    
    if [[ ${#branches[@]} -eq 0 ]]; then
        log_error "No branches found"
        return 1
    fi
    
    # Build menu items array
    local menu_items=()
    for branch in "${branches[@]}"; do
        if [[ "$branch" == "$current_branch" ]]; then
            menu_items+=("$branch" "* Current branch")
        else
            menu_items+=("$branch" "")
        fi
    done
    
    # Show dialog
    local selected
    selected=$(dialog_menu "$title" "$message" "${menu_items[@]}")
    local exit_code=$?
    
    if [[ $exit_code -eq 0 && -n "$selected" ]]; then
        echo "$selected"
        return 0
    else
        return 1
    fi
}

# Select a branch using simple prompt (fallback when dialog not available)
git_select_branch_prompt() {
    local prompt="${1:-Select a branch:}"
    
    check_git_installed || return 1
    
    # Get all branches
    local branches
    mapfile -t branches < <(git_list_branches_all)
    
    if [[ ${#branches[@]} -eq 0 ]]; then
        log_error "No branches found"
        return 1
    fi
    
    # Display branches
    log_info "$prompt"
    local i=1
    for branch in "${branches[@]}"; do
        echo "$i) $branch" >&2
        ((i++))
    done
    
    # Get user selection
    local selection
    read -rp "Enter number (1-${#branches[@]}): " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#branches[@]} ]]; then
        echo "${branches[$((selection-1))]}"
        return 0
    else
        log_error "Invalid selection"
        return 1
    fi
}

# Clone a repository
git_clone_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="${3:-}"
    
    check_git_installed || return 1
    
    if [[ -z "$repo_url" ]]; then
        log_error "Repository URL is required"
        return 1
    fi
    
    log_info "Cloning repository: $repo_url"
    
    if [[ -n "$branch" ]]; then
        log_info "Cloning branch: $branch"
        if [[ -n "$target_dir" ]]; then
            git clone -b "$branch" "$repo_url" "$target_dir"
        else
            git clone -b "$branch" "$repo_url"
        fi
    else
        if [[ -n "$target_dir" ]]; then
            git clone "$repo_url" "$target_dir"
        else
            git clone "$repo_url"
        fi
    fi
}

# Pull latest changes
git_pull_latest() {
    local remote="${1:-origin}"
    local branch="${2:-}"
    
    check_git_installed || return 1
    
    if ! git_is_repo; then
        log_error "Not in a git repository"
        return 1
    fi
    
    if [[ -z "$branch" ]]; then
        branch=$(git_current_branch)
    fi
    
    log_info "Pulling latest changes from $remote/$branch"
    git pull "$remote" "$branch"
}

# Push changes
git_push_changes() {
    local remote="${1:-origin}"
    local branch="${2:-}"
    local force="${3:-false}"
    
    check_git_installed || return 1
    
    if ! git_is_repo; then
        log_error "Not in a git repository"
        return 1
    fi
    
    if [[ -z "$branch" ]]; then
        branch=$(git_current_branch)
    fi
    
    log_info "Pushing changes to $remote/$branch"
    
    if [[ "$force" == "true" ]]; then
        git push --force-with-lease "$remote" "$branch"
    else
        git push "$remote" "$branch"
    fi
}

# Create a new branch
git_create_branch() {
    local branch_name="$1"
    local base_branch="${2:-}"
    
    check_git_installed || return 1
    
    if [[ -z "$branch_name" ]]; then
        log_error "Branch name is required"
        return 1
    fi
    
    if git_branch_exists_local "$branch_name"; then
        log_error "Branch '$branch_name' already exists locally"
        return 1
    fi
    
    if [[ -n "$base_branch" ]]; then
        log_info "Creating branch '$branch_name' from '$base_branch'"
        git checkout -b "$branch_name" "$base_branch"
    else
        log_info "Creating branch '$branch_name'"
        git checkout -b "$branch_name"
    fi
}

# Delete a branch
git_delete_branch() {
    local branch_name="$1"
    local force="${2:-false}"
    
    check_git_installed || return 1
    
    if [[ -z "$branch_name" ]]; then
        log_error "Branch name is required"
        return 1
    fi
    
    local current_branch
    current_branch=$(git_current_branch)
    
    if [[ "$branch_name" == "$current_branch" ]]; then
        log_error "Cannot delete current branch. Please checkout another branch first."
        return 1
    fi
    
    if ! git_branch_exists_local "$branch_name"; then
        log_error "Branch '$branch_name' does not exist locally"
        return 1
    fi
    
    if [[ "$force" == "true" ]]; then
        log_info "Force deleting branch: $branch_name"
        git branch -D "$branch_name"
    else
        log_info "Deleting branch: $branch_name"
        git branch -d "$branch_name"
    fi
}

# Get repository root directory
git_repo_root() {
    check_git_installed || return 1
    git rev-parse --show-toplevel 2>/dev/null
}

# Get repository name
git_repo_name() {
    check_git_installed || return 1
    basename "$(git_repo_root)"
}

# Get remote URL
git_remote_url() {
    local remote="${1:-origin}"
    check_git_installed || return 1
    git remote get-url "$remote" 2>/dev/null
}

# Check if working directory is clean
git_is_clean() {
    check_git_installed || return 1
    [[ -z "$(git status --porcelain)" ]]
}

# Get current commit hash
git_current_commit() {
    local short="${1:-false}"
    check_git_installed || return 1
    
    if [[ "$short" == "true" ]]; then
        git rev-parse --short HEAD
    else
        git rev-parse HEAD
    fi
}

# Fetch from remote
git_fetch() {
    local remote="${1:-origin}"
    check_git_installed || return 1
    
    log_info "Fetching from $remote"
    git fetch "$remote"
}

# Create a pull request using GitHub CLI (gh)
git_create_pr_github() {
    local title="$1"
    local body="${2:-}"
    local base_branch="${3:-main}"
    local draft="${4:-false}"
    
    if ! command -v gh &> /dev/null; then
        log_error "GitHub CLI (gh) is not installed. Please install it:"
        log_error "  https://cli.github.com/"
        return 1
    fi
    
    check_git_installed || return 1
    
    if [[ -z "$title" ]]; then
        log_error "PR title is required"
        return 1
    fi
    
    local current_branch
    current_branch=$(git_current_branch)
    
    log_info "Creating pull request from '$current_branch' to '$base_branch'"
    
    local gh_args=(
        "pr" "create"
        "--title" "$title"
        "--base" "$base_branch"
    )
    
    if [[ -n "$body" ]]; then
        gh_args+=("--body" "$body")
    fi
    
    if [[ "$draft" == "true" ]]; then
        gh_args+=("--draft")
    fi
    
    gh "${gh_args[@]}"
}

# Stash changes
git_stash() {
    local message="${1:-}"
    check_git_installed || return 1
    
    if [[ -n "$message" ]]; then
        log_info "Stashing changes: $message"
        git stash push -m "$message"
    else
        log_info "Stashing changes"
        git stash
    fi
}

# Pop stashed changes
git_stash_pop() {
    check_git_installed || return 1
    log_info "Popping stashed changes"
    git stash pop
}

# List stashes
git_stash_list() {
    check_git_installed || return 1
    git stash list
}
