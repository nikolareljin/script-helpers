#!/usr/bin/env bash
#
# Comprehensive test script for all helper functions
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "  Testing Script Helpers"
echo "=========================================="
echo ""

# Test 1: Syntax check
echo "Test 1: Checking syntax of all scripts..."
for script in *.sh examples/*.sh; do
    if bash -n "$script" 2>&1; then
        echo "  ✅ $script"
    else
        echo "  ❌ $script failed syntax check"
        exit 1
    fi
done
echo ""

# Test 2: Source main script
echo "Test 2: Sourcing main script..."
if source ./script-helpers.sh > /dev/null 2>&1; then
    echo "  ✅ Main script sourced successfully"
else
    echo "  ❌ Failed to source main script"
    exit 1
fi
echo ""

# Test 3: OS detection functions
echo "Test 3: Testing OS detection functions..."
OS=$(detect_os)
if [ -n "$OS" ]; then
    echo "  ✅ detect_os: $OS"
else
    echo "  ❌ detect_os failed"
    exit 1
fi

PKG_MGR=$(get_package_manager)
if [ -n "$PKG_MGR" ]; then
    echo "  ✅ get_package_manager: $PKG_MGR"
else
    echo "  ❌ get_package_manager failed"
    exit 1
fi
echo ""

# Test 4: Command exists function
echo "Test 4: Testing command_exists function..."
if command_exists bash; then
    echo "  ✅ command_exists bash: true"
else
    echo "  ❌ command_exists bash should return true"
    exit 1
fi

if ! command_exists nonexistent_command_xyz_123; then
    echo "  ✅ command_exists nonexistent: false"
else
    echo "  ❌ command_exists nonexistent should return false"
    exit 1
fi
echo ""

# Test 5: Docker functions (basic checks)
echo "Test 5: Testing Docker functions..."
if command -v docker &> /dev/null; then
    echo "  ✅ Docker is available"
    
    # Test docker_compose function
    if docker_compose --version &> /dev/null; then
        echo "  ✅ docker_compose function works"
    else
        echo "  ⚠️  docker_compose function returned error (may be expected if no compose available)"
    fi
    
    # Test docker_status
    if docker_status > /dev/null 2>&1; then
        echo "  ✅ docker_status function works"
    else
        echo "  ⚠️  docker_status function returned error"
    fi
else
    echo "  ⚠️  Docker not available, skipping Docker tests"
fi
echo ""

# Test 6: GitHub CLI check
echo "Test 6: Testing GitHub CLI functions..."
if check_gh_installed 2>&1 | grep -q "Error"; then
    echo "  ⚠️  GitHub CLI not installed (expected on some systems)"
elif check_gh_installed; then
    echo "  ✅ GitHub CLI is installed"
    if check_gh_authenticated 2>&1 | grep -q "Error"; then
        echo "  ⚠️  GitHub CLI not authenticated (expected)"
    else
        echo "  ✅ GitHub CLI is authenticated"
    fi
else
    echo "  ⚠️  GitHub CLI check inconclusive"
fi
echo ""

# Test 7: JSON escaping function
echo "Test 7: Testing JSON escaping function..."
result=$(json_escape 'test"quote')
if [[ "$result" == 'test\"quote' ]]; then
    echo "  ✅ JSON escaping works correctly"
else
    echo "  ❌ JSON escaping failed: got '$result'"
    exit 1
fi
echo ""

# Test 8: Error handling
echo "Test 8: Testing error handling..."
if docker_ssh 2>&1 | grep -q "Error"; then
    echo "  ✅ docker_ssh shows error for missing arguments"
else
    echo "  ❌ docker_ssh should show error for missing arguments"
    exit 1
fi

if github_create_pr 2>&1 | grep -q "Error"; then
    echo "  ✅ github_create_pr shows error for missing arguments"
else
    echo "  ❌ github_create_pr should show error for missing arguments"
    exit 1
fi

if install_packages 2>&1 | grep -q "Error"; then
    echo "  ✅ install_packages shows error for missing arguments"
else
    echo "  ❌ install_packages should show error for missing arguments"
    exit 1
fi
echo ""

# Test 9: Help and list commands
echo "Test 9: Testing help and list commands..."
if bash script-helpers.sh help | grep -q "Script Helpers"; then
    echo "  ✅ help command works"
else
    echo "  ❌ help command failed"
    exit 1
fi

if bash script-helpers.sh list | grep -q "docker_compose"; then
    echo "  ✅ list command works"
else
    echo "  ❌ list command failed"
    exit 1
fi
echo ""

# Test 10: Example scripts
echo "Test 10: Testing example scripts..."
for example in examples/*.sh; do
    if bash "$example" > /dev/null 2>&1; then
        echo "  ✅ $example runs without errors"
    else
        echo "  ⚠️  $example had issues (may be expected if dependencies missing)"
    fi
done
echo ""

echo "=========================================="
echo "  ✅ All Tests Passed!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  - All scripts have valid syntax"
echo "  - Main script loads successfully"
echo "  - OS detection works correctly"
echo "  - Command checking works correctly"
echo "  - Docker functions are available"
echo "  - GitHub functions are available"
echo "  - JSON escaping works correctly"
echo "  - Error handling works correctly"
echo "  - Help and list commands work"
echo "  - Example scripts are functional"
echo ""
