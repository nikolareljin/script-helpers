#!/usr/bin/env bash
#
# OS Helpers - Example Usage
#

# Source the script helpers
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
source "${SCRIPT_DIR}/script-helpers.sh"

echo "=== OS Helpers Example Usage ==="
echo ""

# Display system information
echo "1. System Information..."
system_info
echo ""

# Detect OS
echo "2. Detecting operating system..."
OS=$(detect_os)
echo "   Detected OS: $OS"
echo ""

# Detect package manager
echo "3. Detecting package manager..."
PKG_MGR=$(get_package_manager)
echo "   Package Manager: $PKG_MGR"
echo ""

# Check if specific commands exist
echo "4. Checking for common commands..."
commands=("git" "docker" "curl" "wget" "python3")
for cmd in "${commands[@]}"; do
    if command_exists "$cmd"; then
        echo "   ✅ $cmd is installed"
    else
        echo "   ❌ $cmd is not installed"
    fi
done
echo ""

# Example: Smart package installation (commented out to avoid actual installation)
# echo "5. Smart package installation example..."
# echo "   This will detect your OS and use the appropriate package manager"
# install_packages git curl wget
# echo ""

# Example: OS-specific installation (commented out)
# case "$OS" in
#     macos)
#         echo "   Installing on macOS..."
#         install_macos node npm
#         ;;
#     linux)
#         echo "   Installing on Linux..."
#         install_packages nodejs npm
#         ;;
# esac

echo "=== Example completed ==="
echo ""
echo "To use these functions in your own scripts:"
echo "  source ${SCRIPT_DIR}/script-helpers.sh"
echo "  OS=\$(detect_os)"
echo "  install_packages git curl wget"
echo "  system_info"
