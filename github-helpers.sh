#!/usr/bin/env bash
#
# GitHub Helper Functions
# Collection of helper functions for GitHub operations using GitHub CLI (gh)
#

# Check if GitHub CLI is installed
check_gh_installed() {
    if ! command -v gh &> /dev/null; then
        echo "Error: GitHub CLI (gh) is not installed" >&2
        echo "Please install it from: https://cli.github.com/" >&2
        echo "" >&2
        echo "Installation options:" >&2
        echo "  macOS:   brew install gh" >&2
        echo "  Linux:   See https://github.com/cli/cli/blob/trunk/docs/install_linux.md" >&2
        echo "  Windows: winget install GitHub.cli" >&2
        return 1
    fi
    return 0
}

# Check if GitHub CLI is authenticated
check_gh_authenticated() {
    if ! gh auth status &> /dev/null; then
        echo "Error: GitHub CLI is not authenticated" >&2
        echo "Please run: gh auth login" >&2
        return 1
    fi
    return 0
}

# Add a team to a repository
# Usage: github_add_team <owner/repo> <team-slug> [permission]
# Permission can be: pull, push, admin, maintain, triage (default: push)
github_add_team() {
    local repo="${1}"
    local team="${2}"
    local permission="${3:-push}"
    
    if [ -z "$repo" ] || [ -z "$team" ]; then
        echo "Error: Repository and team are required" >&2
        echo "Usage: github_add_team <owner/repo> <team-slug> [permission]" >&2
        echo "Permission options: pull, push, admin, maintain, triage (default: push)" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "Adding team '${team}' to repository '${repo}' with '${permission}' permission..."
    
    # Extract owner and repo name
    local owner=$(echo "$repo" | cut -d'/' -f1)
    local repo_name=$(echo "$repo" | cut -d'/' -f2)
    
    # Use GitHub API via gh
    gh api \
        --method PUT \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/orgs/${owner}/teams/${team}/repos/${owner}/${repo_name}" \
        -f permission="${permission}"
    
    if [ $? -eq 0 ]; then
        echo "✅ Team '${team}' successfully added to repository '${repo}'"
    else
        echo "❌ Failed to add team to repository" >&2
        return 1
    fi
}

# Define a webhook for a repository
# Usage: github_add_webhook <owner/repo> <webhook-url> [events]
# Events: Comma-separated list (default: push,pull_request)
github_add_webhook() {
    local repo="${1}"
    local webhook_url="${2}"
    local events="${3:-push,pull_request}"
    
    if [ -z "$repo" ] || [ -z "$webhook_url" ]; then
        echo "Error: Repository and webhook URL are required" >&2
        echo "Usage: github_add_webhook <owner/repo> <webhook-url> [events]" >&2
        echo "Events example: push,pull_request,issues (comma-separated)" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "Adding webhook to repository '${repo}'..."
    echo "Webhook URL: ${webhook_url}"
    echo "Events: ${events}"
    
    # Convert comma-separated events to JSON array
    local events_json="["
    IFS=',' read -ra event_array <<< "$events"
    for i in "${!event_array[@]}"; do
        if [ $i -gt 0 ]; then
            events_json+=","
        fi
        events_json+="\"${event_array[$i]}\""
    done
    events_json+="]"
    
    # Create webhook using GitHub API with proper JSON payload
    gh api \
        --method POST \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/repos/${repo}/hooks" \
        --input - <<EOF
{
  "name": "web",
  "active": true,
  "events": ${events_json},
  "config": {
    "url": "${webhook_url}",
    "content_type": "json"
  }
}
EOF
    
    if [ $? -eq 0 ]; then
        echo "✅ Webhook successfully added to repository '${repo}'"
    else
        echo "❌ Failed to add webhook to repository" >&2
        return 1
    fi
}

# List webhooks for a repository
# Usage: github_list_webhooks <owner/repo>
github_list_webhooks() {
    local repo="${1}"
    
    if [ -z "$repo" ]; then
        echo "Error: Repository is required" >&2
        echo "Usage: github_list_webhooks <owner/repo>" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "=== Webhooks for repository '${repo}' ==="
    gh api "/repos/${repo}/hooks" --jq '.[] | "ID: \(.id)\nURL: \(.config.url)\nEvents: \(.events | join(", "))\nActive: \(.active)\n"'
}

# Create a GitHub Actions workflow file
# Usage: github_create_workflow <workflow-name> <workflow-file-path>
github_create_workflow() {
    local workflow_name="${1}"
    local workflow_file="${2}"
    
    if [ -z "$workflow_name" ] || [ -z "$workflow_file" ]; then
        echo "Error: Workflow name and file path are required" >&2
        echo "Usage: github_create_workflow <workflow-name> <workflow-file-path>" >&2
        return 1
    fi
    
    # Create .github/workflows directory if it doesn't exist
    local workflow_dir=".github/workflows"
    if [ ! -d "$workflow_dir" ]; then
        mkdir -p "$workflow_dir"
        echo "Created directory: $workflow_dir"
    fi
    
    local target_file="${workflow_dir}/${workflow_file}"
    
    if [ -f "$target_file" ]; then
        echo "Warning: Workflow file already exists: $target_file" >&2
        read -p "Overwrite? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted"
            return 1
        fi
    fi
    
    # Create a basic workflow template
    cat > "$target_file" <<EOF
name: ${workflow_name}

on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]

jobs:
  build:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Run a one-line script
      run: echo Hello, world!
    
    - name: Run a multi-line script
      run: |
        echo Add your build steps here
        echo This is a template workflow
EOF
    
    echo "✅ Created workflow file: $target_file"
    echo "Please edit the file to customize the workflow for your needs"
    return 0
}

# Create a pull request
# Usage: github_create_pr <base-branch> <head-branch> <title> [body]
github_create_pr() {
    local base_branch="${1}"
    local head_branch="${2}"
    local title="${3}"
    local body="${4:-}"
    
    if [ -z "$base_branch" ] || [ -z "$head_branch" ] || [ -z "$title" ]; then
        echo "Error: Base branch, head branch, and title are required" >&2
        echo "Usage: github_create_pr <base-branch> <head-branch> <title> [body]" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "Creating pull request..."
    echo "Base: ${base_branch}"
    echo "Head: ${head_branch}"
    echo "Title: ${title}"
    
    if [ -n "$body" ]; then
        gh pr create --base "$base_branch" --head "$head_branch" --title "$title" --body "$body"
    else
        gh pr create --base "$base_branch" --head "$head_branch" --title "$title"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Pull request created successfully"
    else
        echo "❌ Failed to create pull request" >&2
        return 1
    fi
}

# List pull requests
# Usage: github_list_prs [owner/repo] [state]
# State can be: open, closed, merged, all (default: open)
github_list_prs() {
    local repo="${1}"
    local state="${2:-open}"
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "=== Pull Requests (${state}) ==="
    
    if [ -n "$repo" ]; then
        gh pr list --repo "$repo" --state "$state"
    else
        gh pr list --state "$state"
    fi
}

# View pull request details
# Usage: github_view_pr <pr-number> [owner/repo]
github_view_pr() {
    local pr_number="${1}"
    local repo="${2}"
    
    if [ -z "$pr_number" ]; then
        echo "Error: PR number is required" >&2
        echo "Usage: github_view_pr <pr-number> [owner/repo]" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    if [ -n "$repo" ]; then
        gh pr view "$pr_number" --repo "$repo"
    else
        gh pr view "$pr_number"
    fi
}

# Merge a pull request
# Usage: github_merge_pr <pr-number> [merge-method]
# Merge method can be: merge, squash, rebase (default: merge)
github_merge_pr() {
    local pr_number="${1}"
    local method="${2:-merge}"
    
    if [ -z "$pr_number" ]; then
        echo "Error: PR number is required" >&2
        echo "Usage: github_merge_pr <pr-number> [merge-method]" >&2
        echo "Merge methods: merge, squash, rebase (default: merge)" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    case "$method" in
        merge|squash|rebase)
            echo "Merging pull request #${pr_number} using ${method} method..."
            gh pr merge "$pr_number" "--${method}" --delete-branch
            ;;
        *)
            echo "Error: Invalid merge method: ${method}" >&2
            echo "Valid methods: merge, squash, rebase" >&2
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        echo "✅ Pull request merged successfully"
    else
        echo "❌ Failed to merge pull request" >&2
        return 1
    fi
}

# Create a new issue
# Usage: github_create_issue <title> [body]
github_create_issue() {
    local title="${1}"
    local body="${2:-}"
    
    if [ -z "$title" ]; then
        echo "Error: Issue title is required" >&2
        echo "Usage: github_create_issue <title> [body]" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "Creating issue..."
    echo "Title: ${title}"
    
    if [ -n "$body" ]; then
        gh issue create --title "$title" --body "$body"
    else
        gh issue create --title "$title"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Issue created successfully"
    else
        echo "❌ Failed to create issue" >&2
        return 1
    fi
}

# List issues
# Usage: github_list_issues [owner/repo] [state]
# State can be: open, closed, all (default: open)
github_list_issues() {
    local repo="${1}"
    local state="${2:-open}"
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "=== Issues (${state}) ==="
    
    if [ -n "$repo" ]; then
        gh issue list --repo "$repo" --state "$state"
    else
        gh issue list --state "$state"
    fi
}

# Clone a repository
# Usage: github_clone <owner/repo> [directory]
github_clone() {
    local repo="${1}"
    local directory="${2}"
    
    if [ -z "$repo" ]; then
        echo "Error: Repository is required" >&2
        echo "Usage: github_clone <owner/repo> [directory]" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    
    echo "Cloning repository: ${repo}"
    
    if [ -n "$directory" ]; then
        gh repo clone "$repo" "$directory"
    else
        gh repo clone "$repo"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Repository cloned successfully"
    else
        echo "❌ Failed to clone repository" >&2
        return 1
    fi
}

# Create a new repository
# Usage: github_create_repo <repo-name> [--public|--private] [description]
github_create_repo() {
    local repo_name="${1}"
    local visibility="--public"
    local description=""
    
    if [ -z "$repo_name" ]; then
        echo "Error: Repository name is required" >&2
        echo "Usage: github_create_repo <repo-name> [--public|--private] [description]" >&2
        return 1
    fi
    
    shift
    
    # Parse optional arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --public|--private)
                visibility="$1"
                shift
                ;;
            *)
                description="$1"
                shift
                ;;
        esac
    done
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "Creating repository: ${repo_name}"
    echo "Visibility: ${visibility}"
    
    if [ -n "$description" ]; then
        gh repo create "$repo_name" "$visibility" --description "$description"
    else
        gh repo create "$repo_name" "$visibility"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✅ Repository created successfully"
    else
        echo "❌ Failed to create repository" >&2
        return 1
    fi
}

# View repository information
# Usage: github_repo_info [owner/repo]
github_repo_info() {
    local repo="${1}"
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    if [ -n "$repo" ]; then
        gh repo view "$repo"
    else
        gh repo view
    fi
}

# Workflow run operations
# Usage: github_workflow_list [owner/repo]
github_workflow_list() {
    local repo="${1}"
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "=== GitHub Actions Workflows ==="
    
    if [ -n "$repo" ]; then
        gh workflow list --repo "$repo"
    else
        gh workflow list
    fi
}

# View workflow runs
# Usage: github_workflow_runs <workflow-name-or-id> [owner/repo]
github_workflow_runs() {
    local workflow="${1}"
    local repo="${2}"
    
    if [ -z "$workflow" ]; then
        echo "Error: Workflow name or ID is required" >&2
        echo "Usage: github_workflow_runs <workflow-name-or-id> [owner/repo]" >&2
        return 1
    fi
    
    check_gh_installed || return 1
    check_gh_authenticated || return 1
    
    echo "=== Workflow Runs for '${workflow}' ==="
    
    if [ -n "$repo" ]; then
        gh run list --workflow "$workflow" --repo "$repo"
    else
        gh run list --workflow "$workflow"
    fi
}

# Display GitHub CLI status and authentication
# Usage: github_status
github_status() {
    echo "=== GitHub CLI Status ==="
    echo ""
    
    if ! check_gh_installed; then
        return 1
    fi
    
    echo "✅ GitHub CLI is installed"
    gh --version
    echo ""
    
    echo "--- Authentication Status ---"
    if gh auth status 2>&1; then
        echo ""
        echo "✅ GitHub CLI is authenticated"
    else
        echo ""
        echo "❌ GitHub CLI is not authenticated"
        echo "Run: gh auth login"
    fi
}
