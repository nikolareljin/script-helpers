#!/usr/bin/env bash
#
# OS-Specific Helper Functions
# Collection of helper functions for OS detection and package management
#

# Detect the operating system
# Returns: "macos", "linux", "windows", or "unknown"
detect_os() {
    local os_name=""
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        os_name="macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        os_name="linux"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
        os_name="windows"
    else
        os_name="unknown"
    fi
    
    echo "$os_name"
}

# Detect Linux distribution
# Returns: "ubuntu", "debian", "fedora", "centos", "arch", "alpine", or "unknown"
detect_linux_distro() {
    if [ ! -f /etc/os-release ]; then
        echo "unknown"
        return
    fi
    
    # Source the os-release file
    . /etc/os-release
    
    case "$ID" in
        ubuntu)
            echo "ubuntu"
            ;;
        debian)
            echo "debian"
            ;;
        fedora)
            echo "fedora"
            ;;
        centos|rhel)
            echo "centos"
            ;;
        arch|manjaro)
            echo "arch"
            ;;
        alpine)
            echo "alpine"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Get the package manager for the current OS
# Returns: "brew", "apt", "yum", "dnf", "pacman", "apk", "choco", or "unknown"
get_package_manager() {
    local os=$(detect_os)
    
    case "$os" in
        macos)
            if command -v brew &> /dev/null; then
                echo "brew"
            else
                echo "unknown"
            fi
            ;;
        linux)
            if command -v apt-get &> /dev/null; then
                echo "apt"
            elif command -v dnf &> /dev/null; then
                echo "dnf"
            elif command -v yum &> /dev/null; then
                echo "yum"
            elif command -v pacman &> /dev/null; then
                echo "pacman"
            elif command -v apk &> /dev/null; then
                echo "apk"
            else
                echo "unknown"
            fi
            ;;
        windows)
            if command -v choco &> /dev/null; then
                echo "choco"
            elif command -v winget &> /dev/null; then
                echo "winget"
            else
                echo "unknown"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Install packages on macOS
# Usage: install_macos <package1> [package2] [package3] ...
install_macos() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_macos <package1> [package2] ..." >&2
        return 1
    fi
    
    # Check if Homebrew is installed
    if ! command -v brew &> /dev/null; then
        echo "Homebrew is not installed. Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install Homebrew" >&2
            return 1
        fi
    fi
    
    echo "Installing packages on macOS: $@"
    brew install "$@"
}

# Install packages on Linux (Ubuntu/Debian)
# Usage: install_linux_apt <package1> [package2] [package3] ...
install_linux_apt() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_linux_apt <package1> [package2] ..." >&2
        return 1
    fi
    
    echo "Installing packages on Linux (apt): $@"
    sudo apt-get update
    sudo apt-get install -y "$@"
}

# Install packages on Linux (Fedora/RHEL/CentOS with dnf)
# Usage: install_linux_dnf <package1> [package2] [package3] ...
install_linux_dnf() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_linux_dnf <package1> [package2] ..." >&2
        return 1
    fi
    
    echo "Installing packages on Linux (dnf): $@"
    sudo dnf install -y "$@"
}

# Install packages on Linux (CentOS/RHEL with yum)
# Usage: install_linux_yum <package1> [package2] [package3] ...
install_linux_yum() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_linux_yum <package1> [package2] ..." >&2
        return 1
    fi
    
    echo "Installing packages on Linux (yum): $@"
    sudo yum install -y "$@"
}

# Install packages on Linux (Arch with pacman)
# Usage: install_linux_pacman <package1> [package2] [package3] ...
install_linux_pacman() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_linux_pacman <package1> [package2] ..." >&2
        return 1
    fi
    
    echo "Installing packages on Linux (pacman): $@"
    sudo pacman -S --noconfirm "$@"
}

# Install packages on Linux (Alpine with apk)
# Usage: install_linux_apk <package1> [package2] [package3] ...
install_linux_apk() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_linux_apk <package1> [package2] ..." >&2
        return 1
    fi
    
    echo "Installing packages on Linux (apk): $@"
    sudo apk add "$@"
}

# Install packages on Windows (using Chocolatey)
# Usage: install_windows_choco <package1> [package2] [package3] ...
install_windows_choco() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_windows_choco <package1> [package2] ..." >&2
        return 1
    fi
    
    # Check if Chocolatey is installed
    if ! command -v choco &> /dev/null; then
        echo "Chocolatey is not installed. Please install it from: https://chocolatey.org/install" >&2
        return 1
    fi
    
    echo "Installing packages on Windows (Chocolatey): $@"
    choco install -y "$@"
}

# Install packages on Windows (using winget)
# Usage: install_windows_winget <package1> [package2] [package3] ...
install_windows_winget() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_windows_winget <package1> [package2] ..." >&2
        return 1
    fi
    
    # Check if winget is installed
    if ! command -v winget &> /dev/null; then
        echo "winget is not installed. Please install it from Microsoft Store or Windows Package Manager" >&2
        return 1
    fi
    
    echo "Installing packages on Windows (winget): $@"
    for package in "$@"; do
        winget install --id "$package" --silent --accept-package-agreements --accept-source-agreements
    done
}

# Smart package installer - automatically detects OS and uses appropriate package manager
# Usage: install_packages <package1> [package2] [package3] ...
install_packages() {
    if [ $# -eq 0 ]; then
        echo "Error: No packages specified" >&2
        echo "Usage: install_packages <package1> [package2] ..." >&2
        return 1
    fi
    
    local os=$(detect_os)
    local pkg_manager=$(get_package_manager)
    
    echo "Detected OS: $os"
    echo "Package manager: $pkg_manager"
    echo ""
    
    case "$pkg_manager" in
        brew)
            install_macos "$@"
            ;;
        apt)
            install_linux_apt "$@"
            ;;
        dnf)
            install_linux_dnf "$@"
            ;;
        yum)
            install_linux_yum "$@"
            ;;
        pacman)
            install_linux_pacman "$@"
            ;;
        apk)
            install_linux_apk "$@"
            ;;
        choco)
            install_windows_choco "$@"
            ;;
        winget)
            install_windows_winget "$@"
            ;;
        *)
            echo "Error: Could not detect package manager for OS: $os" >&2
            echo "Please install packages manually or specify the package manager" >&2
            return 1
            ;;
    esac
}

# Display system information
# Usage: system_info
system_info() {
    echo "=== System Information ==="
    echo ""
    
    local os=$(detect_os)
    echo "Operating System: $os"
    
    if [ "$os" = "linux" ]; then
        local distro=$(detect_linux_distro)
        echo "Linux Distribution: $distro"
        
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "Version: $VERSION"
        fi
    elif [ "$os" = "macos" ]; then
        echo "macOS Version: $(sw_vers -productVersion)"
    fi
    
    echo "Package Manager: $(get_package_manager)"
    echo ""
    
    echo "--- Hardware ---"
    echo "Architecture: $(uname -m)"
    echo "Kernel: $(uname -s) $(uname -r)"
    
    if command -v nproc &> /dev/null; then
        echo "CPU Cores: $(nproc)"
    fi
    
    if command -v free &> /dev/null; then
        echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    fi
    
    echo ""
    echo "--- Shell ---"
    echo "Current Shell: $SHELL"
    echo "Bash Version: $BASH_VERSION"
}

# Check if a command exists
# Usage: command_exists <command>
# Returns: 0 if command exists, 1 otherwise
command_exists() {
    command -v "$1" &> /dev/null
}

# Install common development tools
# Usage: install_dev_tools
install_dev_tools() {
    echo "Installing common development tools..."
    
    local os=$(detect_os)
    
    case "$os" in
        macos)
            install_macos git curl wget vim make gcc
            ;;
        linux)
            local pkg_manager=$(get_package_manager)
            case "$pkg_manager" in
                apt)
                    install_linux_apt git curl wget vim make build-essential
                    ;;
                dnf|yum)
                    if [ "$pkg_manager" = "dnf" ]; then
                        install_linux_dnf git curl wget vim make gcc gcc-c++
                    else
                        install_linux_yum git curl wget vim make gcc gcc-c++
                    fi
                    ;;
                pacman)
                    install_linux_pacman git curl wget vim make gcc
                    ;;
                apk)
                    install_linux_apk git curl wget vim make gcc g++
                    ;;
            esac
            ;;
        windows)
            local pkg_manager=$(get_package_manager)
            if [ "$pkg_manager" = "choco" ]; then
                install_windows_choco git curl wget vim
            elif [ "$pkg_manager" = "winget" ]; then
                install_windows_winget Git.Git cURL.cURL vim.vim
            fi
            ;;
        *)
            echo "Error: Unsupported OS for automatic dev tools installation" >&2
            return 1
            ;;
    esac
    
    echo "Development tools installation complete"
}
