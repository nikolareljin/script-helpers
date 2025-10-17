#!/usr/bin/env bash

# script-helpers.sh
# Main entry point for all script helper utilities
# Source this file in your scripts to get access to all helper functions

# Get the directory where this script is located
SCRIPT_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all helper modules
source "$SCRIPT_HELPERS_DIR/lib/logging-helpers.sh"
source "$SCRIPT_HELPERS_DIR/lib/dialog-helpers.sh"
source "$SCRIPT_HELPERS_DIR/lib/git-helpers.sh"
source "$SCRIPT_HELPERS_DIR/lib/docker-helpers.sh"

# Export the directory for use in other scripts
export SCRIPT_HELPERS_DIR

# Print welcome message if running directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Script Helpers Library"
    echo "====================="
    echo ""
    echo "This library provides helper functions for:"
    echo "  - Logging (with colors and timestamps)"
    echo "  - Dialog interfaces (using the dialog CLI tool)"
    echo "  - Git operations (branch management, PR creation, etc.)"
    echo "  - Docker operations (container and image management)"
    echo ""
    echo "To use in your scripts, source this file:"
    echo "  source /path/to/script-helpers.sh"
    echo ""
    echo "See README.md for detailed usage examples."
fi
