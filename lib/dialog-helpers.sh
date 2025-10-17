#!/usr/bin/env bash

# dialog-helpers.sh
# Provides flexible dialog GUI helpers with automatic sizing based on terminal dimensions

# Guard against multiple sourcing
[[ -n "${_DIALOG_HELPERS_LOADED:-}" ]] && return 0
readonly _DIALOG_HELPERS_LOADED=1

# Source logging helpers if available
if [[ -f "${BASH_SOURCE%/*}/logging-helpers.sh" ]]; then
    source "${BASH_SOURCE%/*}/logging-helpers.sh"
else
    log_error() { echo "ERROR: $*" >&2; }
    log_warn() { echo "WARN: $*" >&2; }
    log_debug() { echo "DEBUG: $*" >&2; }
fi

# Check if dialog is installed
check_dialog_installed() {
    if ! command -v dialog &> /dev/null; then
        log_error "dialog command not found. Please install it:"
        log_error "  Ubuntu/Debian: sudo apt-get install dialog"
        log_error "  CentOS/RHEL: sudo yum install dialog"
        log_error "  macOS: brew install dialog"
        return 1
    fi
    return 0
}

# Get terminal dimensions
get_terminal_size() {
    local size
    size=$(stty size 2>/dev/null)
    if [[ -z "$size" ]]; then
        # Fallback to tput if stty fails
        local rows cols
        rows=$(tput lines 2>/dev/null || echo "24")
        cols=$(tput cols 2>/dev/null || echo "80")
        echo "$rows $cols"
    else
        echo "$size"
    fi
}

# Calculate dialog dimensions (85% of terminal size)
calculate_dialog_size() {
    local size percentage
    percentage=${1:-85}  # Default to 85%
    
    size=$(get_terminal_size)
    local term_height term_width
    read -r term_height term_width <<< "$size"
    
    # Calculate 85% of dimensions
    local dialog_height dialog_width
    dialog_height=$((term_height * percentage / 100))
    dialog_width=$((term_width * percentage / 100))
    
    # Ensure minimum sizes
    [[ $dialog_height -lt 10 ]] && dialog_height=10
    [[ $dialog_width -lt 40 ]] && dialog_width=40
    
    echo "$dialog_height $dialog_width"
}

# Show a message box
dialog_msgbox() {
    local title="$1"
    local message="$2"
    local percentage="${3:-85}"
    
    check_dialog_installed || return 1
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    dialog --title "$title" \
           --msgbox "$message" \
           "$height" "$width"
}

# Show a yes/no dialog
dialog_yesno() {
    local title="$1"
    local message="$2"
    local percentage="${3:-85}"
    
    check_dialog_installed || return 1
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    dialog --title "$title" \
           --yesno "$message" \
           "$height" "$width"
}

# Show an input box
dialog_inputbox() {
    local title="$1"
    local message="$2"
    local default="${3:-}"
    local percentage="${4:-85}"
    
    check_dialog_installed || return 1
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    local result
    result=$(dialog --title "$title" \
                    --inputbox "$message" \
                    "$height" "$width" \
                    "$default" \
                    3>&1 1>&2 2>&3 3>&-)
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo "$result"
        return 0
    else
        return $exit_code
    fi
}

# Show a password input box
dialog_passwordbox() {
    local title="$1"
    local message="$2"
    local percentage="${3:-85}"
    
    check_dialog_installed || return 1
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    local result
    result=$(dialog --title "$title" \
                    --insecure \
                    --passwordbox "$message" \
                    "$height" "$width" \
                    3>&1 1>&2 2>&3 3>&-)
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo "$result"
        return 0
    else
        return $exit_code
    fi
}

# Show a menu with multiple choices
dialog_menu() {
    local title="$1"
    local message="$2"
    shift 2
    local percentage="${1:-85}"
    
    # Check if percentage is a number, otherwise it's part of menu items
    if [[ "$percentage" =~ ^[0-9]+$ ]]; then
        shift
    else
        percentage=85
    fi
    
    check_dialog_installed || return 1
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    # Calculate menu height (leave space for borders and message)
    local menu_height=$((height - 7))
    [[ $menu_height -lt 5 ]] && menu_height=5
    
    local result
    result=$(dialog --title "$title" \
                    --menu "$message" \
                    "$height" "$width" "$menu_height" \
                    "$@" \
                    3>&1 1>&2 2>&3 3>&-)
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo "$result"
        return 0
    else
        return $exit_code
    fi
}

# Show a checklist with multiple selections
dialog_checklist() {
    local title="$1"
    local message="$2"
    shift 2
    local percentage="${1:-85}"
    
    # Check if percentage is a number, otherwise it's part of menu items
    if [[ "$percentage" =~ ^[0-9]+$ ]]; then
        shift
    else
        percentage=85
    fi
    
    check_dialog_installed || return 1
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    # Calculate menu height (leave space for borders and message)
    local menu_height=$((height - 7))
    [[ $menu_height -lt 5 ]] && menu_height=5
    
    local result
    result=$(dialog --title "$title" \
                    --checklist "$message" \
                    "$height" "$width" "$menu_height" \
                    "$@" \
                    3>&1 1>&2 2>&3 3>&-)
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo "$result"
        return 0
    else
        return $exit_code
    fi
}

# Show a radio list (single selection from list)
dialog_radiolist() {
    local title="$1"
    local message="$2"
    shift 2
    local percentage="${1:-85}"
    
    # Check if percentage is a number, otherwise it's part of menu items
    if [[ "$percentage" =~ ^[0-9]+$ ]]; then
        shift
    else
        percentage=85
    fi
    
    check_dialog_installed || return 1
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    # Calculate menu height (leave space for borders and message)
    local menu_height=$((height - 7))
    [[ $menu_height -lt 5 ]] && menu_height=5
    
    local result
    result=$(dialog --title "$title" \
                    --radiolist "$message" \
                    "$height" "$width" "$menu_height" \
                    "$@" \
                    3>&1 1>&2 2>&3 3>&-)
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo "$result"
        return 0
    else
        return $exit_code
    fi
}

# Show a progress gauge
dialog_gauge() {
    local title="$1"
    local message="$2"
    local percentage="${3:-85}"
    
    check_dialog_installed || return 1
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    dialog --title "$title" \
           --gauge "$message" \
           "$height" "$width"
}

# Show a text file in a dialog
dialog_textbox() {
    local title="$1"
    local file="$2"
    local percentage="${3:-85}"
    
    check_dialog_installed || return 1
    
    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi
    
    local size
    size=$(calculate_dialog_size "$percentage")
    local height width
    read -r height width <<< "$size"
    
    dialog --title "$title" \
           --textbox "$file" \
           "$height" "$width"
}
