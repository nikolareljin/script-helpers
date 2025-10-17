#!/usr/bin/env bash
#
# GitHub Helpers - Example Usage
#

# Source the script helpers
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
source "${SCRIPT_DIR}/script-helpers.sh"

echo "=== GitHub Helpers Example Usage ==="
echo ""

# Check GitHub CLI status
echo "1. Checking GitHub CLI status..."
github_status
echo ""

# Examples of GitHub operations (most are commented out to avoid actual changes)

# List pull requests in current repo
echo "2. Listing pull requests..."
echo "   Command: github_list_prs"
echo "   (Commented out - requires a git repository with GitHub remote)"
# github_list_prs
echo ""

# List issues
echo "3. Listing issues..."
echo "   Command: github_list_issues"
echo "   (Commented out - requires a git repository with GitHub remote)"
# github_list_issues
echo ""

# Example: Create a pull request
echo "4. Create a pull request example..."
echo "   Command: github_create_pr main feature-branch 'Add new feature' 'Description'"
echo "   (Commented out to avoid creating actual PR)"
# github_create_pr main feature-branch "Add new feature" "This PR adds a new feature"
echo ""

# Example: Add a webhook to a repository
echo "5. Add webhook to repository example..."
echo "   Command: github_add_webhook owner/repo https://example.com/webhook"
echo "   (Commented out to avoid creating actual webhook)"
# github_add_webhook myorg/myrepo https://example.com/webhook push,pull_request
echo ""

# Example: Add a team to a repository
echo "6. Add team to repository example..."
echo "   Command: github_add_team owner/repo my-team push"
echo "   (Commented out to avoid making actual changes)"
# github_add_team myorg/myrepo my-team push
echo ""

# Example: Create a GitHub Actions workflow
echo "7. Create GitHub Actions workflow example..."
echo "   Command: github_create_workflow 'CI Pipeline' ci.yml"
echo "   (Commented out to avoid creating files)"
# github_create_workflow "CI Pipeline" ci.yml
echo ""

# Example: Clone a repository
echo "8. Clone repository example..."
echo "   Command: github_clone owner/repo [directory]"
echo "   (Commented out to avoid cloning)"
# github_clone torvalds/linux linux-kernel
echo ""

# Example: Create an issue
echo "9. Create issue example..."
echo "   Command: github_create_issue 'Bug: Something is broken' 'Details...'"
echo "   (Commented out to avoid creating actual issue)"
# github_create_issue "Bug: Something is broken" "Detailed description of the bug"
echo ""

# Example: View repository information
echo "10. View repository information..."
echo "    Command: github_repo_info [owner/repo]"
echo "    (Commented out - requires a git repository)"
# github_repo_info
echo ""

echo "=== Example completed ==="
echo ""
echo "To use these functions in your own scripts:"
echo "  source ${SCRIPT_DIR}/script-helpers.sh"
echo ""
echo "  # Make sure GitHub CLI is authenticated first:"
echo "  gh auth login"
echo ""
echo "  # Then use the helper functions:"
echo "  github_create_pr main feature 'My Feature' 'Description'"
echo "  github_add_webhook owner/repo https://example.com/hook"
echo "  github_add_team owner/repo my-team push"
echo "  github_create_issue 'Bug title' 'Bug description'"
