#!/usr/bin/env bash

# logging-helpers.sh
# Provides consistent logging functions with colored output and timestamps

# Guard against multiple sourcing
[[ -n "${_LOGGING_HELPERS_LOADED:-}" ]] && return 0
readonly _LOGGING_HELPERS_LOADED=1

# Color codes
readonly LOG_COLOR_RESET='\033[0m'
readonly LOG_COLOR_RED='\033[0;31m'
readonly LOG_COLOR_GREEN='\033[0;32m'
readonly LOG_COLOR_YELLOW='\033[0;33m'
readonly LOG_COLOR_BLUE='\033[0;34m'
readonly LOG_COLOR_CYAN='\033[0;36m'
readonly LOG_COLOR_GRAY='\033[0;90m'

# Log levels
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# Default log level (can be overridden by setting LOG_LEVEL environment variable)
: "${LOG_LEVEL:=$LOG_LEVEL_INFO}"

# Enable/disable timestamps (can be overridden by setting LOG_TIMESTAMPS environment variable)
: "${LOG_TIMESTAMPS:=1}"

# Get timestamp if enabled
_log_timestamp() {
    if [[ "$LOG_TIMESTAMPS" == "1" ]]; then
        date "+%Y-%m-%d %H:%M:%S"
    fi
}

# Internal logging function
_log() {
    local level=$1
    local color=$2
    local label=$3
    shift 3
    local message="$*"
    
    local timestamp
    timestamp=$(_log_timestamp)
    
    if [[ -n "$timestamp" ]]; then
        echo -e "${LOG_COLOR_GRAY}[${timestamp}]${LOG_COLOR_RESET} ${color}[${label}]${LOG_COLOR_RESET} ${message}" >&2
    else
        echo -e "${color}[${label}]${LOG_COLOR_RESET} ${message}" >&2
    fi
}

# Log debug message
log_debug() {
    if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_DEBUG" ]]; then
        _log "$LOG_LEVEL_DEBUG" "$LOG_COLOR_GRAY" "DEBUG" "$@"
    fi
}

# Log info message
log_info() {
    if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_INFO" ]]; then
        _log "$LOG_LEVEL_INFO" "$LOG_COLOR_GREEN" "INFO" "$@"
    fi
}

# Log warning message
log_warn() {
    if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_WARN" ]]; then
        _log "$LOG_LEVEL_WARN" "$LOG_COLOR_YELLOW" "WARN" "$@"
    fi
}

# Log error message
log_error() {
    if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_ERROR" ]]; then
        _log "$LOG_LEVEL_ERROR" "$LOG_COLOR_RED" "ERROR" "$@"
    fi
}

# Log success message (always shown, same level as info)
log_success() {
    if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_INFO" ]]; then
        _log "$LOG_LEVEL_INFO" "$LOG_COLOR_GREEN" "SUCCESS" "$@"
    fi
}

# Log a step/section header
log_section() {
    if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_INFO" ]]; then
        echo "" >&2
        _log "$LOG_LEVEL_INFO" "$LOG_COLOR_CYAN" "======" "$@"
    fi
}

# Log and execute a command
log_exec() {
    log_debug "Executing: $*"
    "$@"
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Command failed with exit code $exit_code: $*"
    fi
    return $exit_code
}
