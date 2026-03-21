#!/usr/bin/env bash
#
# jenkins-common.sh - Shared library for Jenkins build tools
#
# This library provides common functionality shared between pushmon.sh and checkbuild.sh
# to avoid code duplication.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/jenkins-common.sh"
#

# Prevent multiple sourcing
if [[ -n "${_JENKINS_COMMON_LOADED:-}" ]]; then
    return 0
fi
_JENKINS_COMMON_LOADED=1

# =============================================================================
# Color Support
# =============================================================================
# Check if stdout is a terminal and supports colors
# Colors are disabled if:
#   - stdout is not a TTY
#   - tput is not available
#   - terminal reports < 8 colors
#   - TERM is "dumb"
#   - NO_COLOR environment variable is set

_init_colors() {
    if [[ -t 1 ]] && \
       [[ "${TERM:-}" != "dumb" ]] && \
       [[ -z "${NO_COLOR:-}" ]] && \
       command -v tput &>/dev/null && \
       [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
        COLOR_RESET=$(tput sgr0)
        COLOR_BLUE=$(tput setaf 4)
        COLOR_GREEN=$(tput setaf 2)
        COLOR_YELLOW=$(tput setaf 3)
        COLOR_RED=$(tput setaf 1)
        COLOR_CYAN=$(tput setaf 6)
        COLOR_BOLD=$(tput bold)
        COLOR_DIM=$(tput dim 2>/dev/null || echo "")
    else
        COLOR_RESET=""
        COLOR_BLUE=""
        COLOR_GREEN=""
        COLOR_YELLOW=""
        COLOR_RED=""
        COLOR_CYAN=""
        COLOR_BOLD=""
        COLOR_DIM=""
    fi
}

# Initialize colors on source
_init_colors

# =============================================================================
# Test Results Configuration
# =============================================================================
# Configuration for test failure display (can be overridden via environment)
# Spec: test-failure-display-spec.md, Section: Configuration

: "${MAX_FAILED_TESTS_DISPLAY:=10}"  # Maximum failed tests to show in detail
: "${MAX_ERROR_LINES:=5}"             # Maximum lines per error stack trace
: "${MAX_ERROR_LENGTH:=500}"          # Maximum characters per error message

# =============================================================================
# Timestamp Function
# =============================================================================

# Get timestamp in HH:MM:SS format
_timestamp() {
    date "+%H:%M:%S"
}

# =============================================================================
# Logging Functions
# =============================================================================

# =============================================================================
# Verbosity-Aware Logging Functions
# =============================================================================
# These wrappers respect the VERBOSE_MODE setting.
# - Informational messages (info, success) are suppressed in quiet mode (default)
# - Warnings, errors, and essential output are always shown
# Spec reference: buildgit-spec.md, Verbosity Behavior

# INFO level - Only output if VERBOSE_MODE=true
# Use for: "Verifying Jenkins connectivity...", "Found job name", etc.
bg_log_info() {
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        log_info "$@"
    fi
}

# SUCCESS level - Only output if VERBOSE_MODE=true
# Use for: "Connected to Jenkins", "Job found", etc.
bg_log_success() {
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        log_success "$@"
    fi
}

# WARNING level - Always output (warnings are important)
bg_log_warning() {
    log_warning "$@"
}

# ERROR level - Always output (errors are critical)
bg_log_error() {
    log_error "$@"
}

# ESSENTIAL level - Always output regardless of verbosity
# Use for: git command output, build results, test failures, final status
bg_log_essential() {
    echo "$@"
}

# PROGRESS level - Always output for real-time monitoring feedback
# Use for: stage completions, elapsed time updates during monitoring
bg_log_progress() {
    log_info "$@"
}

# PROGRESS_SUCCESS level - Always output for stage completion messages
# Use for: stage completion messages with checkmark formatting
bg_log_progress_success() {
    log_success "$@"
}

# INFO level - General status updates (blue indicator)
log_info() {
    echo "${COLOR_BLUE}[$(_timestamp)] ℹ${COLOR_RESET} $*"
}

# SUCCESS level - Successful operations (green checkmark)
log_success() {
    echo "${COLOR_GREEN}[$(_timestamp)] ✓${COLOR_RESET} $*"
}

# WARNING level - Non-fatal issues (yellow warning)
log_warning() {
    echo "${COLOR_YELLOW}[$(_timestamp)] ⚠${COLOR_RESET} $*"
}

# ERROR level - Fatal errors (red X, output to stderr)
log_error() {
    echo "${COLOR_RED}[$(_timestamp)] ✗${COLOR_RESET} $*" >&2
}

# Banner for major status changes
# Usage: log_banner "success" [message]
#        log_banner "failure" [message]
#        log_banner "building" [message]
log_banner() {
    local status="$1"
    local message="${2:-}"
    echo ""
    case "$status" in
        success)
            echo "${COLOR_GREEN}${COLOR_BOLD}╔════════════════════════════════════════╗${COLOR_RESET}"
            echo "${COLOR_GREEN}${COLOR_BOLD}║           BUILD SUCCESSFUL             ║${COLOR_RESET}"
            echo "${COLOR_GREEN}${COLOR_BOLD}╚════════════════════════════════════════╝${COLOR_RESET}"
            ;;
        failure)
            echo "${COLOR_RED}${COLOR_BOLD}╔════════════════════════════════════════╗${COLOR_RESET}"
            echo "${COLOR_RED}${COLOR_BOLD}║             BUILD FAILED               ║${COLOR_RESET}"
            echo "${COLOR_RED}${COLOR_BOLD}╚════════════════════════════════════════╝${COLOR_RESET}"
            ;;
        building|in_progress)
            echo "${COLOR_YELLOW}${COLOR_BOLD}╔════════════════════════════════════════╗${COLOR_RESET}"
            echo "${COLOR_YELLOW}${COLOR_BOLD}║          BUILD IN PROGRESS             ║${COLOR_RESET}"
            echo "${COLOR_YELLOW}${COLOR_BOLD}╚════════════════════════════════════════╝${COLOR_RESET}"
            ;;
        *)
            # Generic banner with custom status text
            local status_upper
            status_upper=$(echo "$status" | tr '[:lower:]' '[:upper:]')
            local padded
            # Center the status text in a 40-char wide box (38 chars inside borders)
            local status_len=${#status_upper}
            local total_pad=$((38 - status_len - 14))  # "BUILD STATUS: " is 14 chars
            local left_pad=$((total_pad / 2))
            local right_pad=$((total_pad - left_pad))
            padded=$(printf "%*s%s%*s" $left_pad "" "BUILD STATUS: ${status_upper}" $right_pad "")
            echo "${COLOR_CYAN}${COLOR_BOLD}╔════════════════════════════════════════╗${COLOR_RESET}"
            echo "${COLOR_CYAN}${COLOR_BOLD}║${padded}║${COLOR_RESET}"
            echo "${COLOR_CYAN}${COLOR_BOLD}╚════════════════════════════════════════╝${COLOR_RESET}"
            ;;
    esac
    echo ""
}

# Print the final build status line with color
# Usage: print_finished_line "SUCCESS"
# Output: "Finished: SUCCESS" in green (or appropriate color per status)
# Spec: unify-follow-log-spec.md, Section 4 (Build Completion)
print_finished_line() {
    local result="$1"
    local color=""

    case "$result" in
        SUCCESS)   color="${COLOR_GREEN}" ;;
        FAILURE)   color="${COLOR_RED}" ;;
        NOT_BUILT) color="${COLOR_RED}" ;;
        UNSTABLE)  color="${COLOR_YELLOW}" ;;
        ABORTED)   color="${COLOR_DIM}" ;;
        *)         color="${COLOR_RED}" ;;  # Default non-SUCCESS to red
    esac

    if [[ -n "$color" ]]; then
        echo "${color}Finished: ${result}${COLOR_RESET}"
    else
        echo "Finished: ${result}"
    fi
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate required environment variables
# Checks: JENKINS_URL, JENKINS_USER_ID, JENKINS_API_TOKEN
# Exits with error if any are missing or malformed
validate_environment() {
    local missing=()

    if [[ -z "${JENKINS_URL:-}" ]]; then
        missing+=("JENKINS_URL")
    fi
    if [[ -z "${JENKINS_USER_ID:-}" ]]; then
        missing+=("JENKINS_USER_ID")
    fi
    if [[ -z "${JENKINS_API_TOKEN:-}" ]]; then
        missing+=("JENKINS_API_TOKEN")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing[*]}"
        log_info "Please set the following environment variables:"
        for var in "${missing[@]}"; do
            log_info "  - $var"
        done
        return 1
    fi

    # Validate JENKINS_URL format
    if [[ ! "$JENKINS_URL" =~ ^https?:// ]]; then
        log_error "JENKINS_URL must begin with http:// or https://"
        log_error "Current value: $JENKINS_URL"
        return 1
    fi

    # Normalize trailing slashes
    JENKINS_URL="${JENKINS_URL%/}"
    return 0
}

# Validate required external dependencies
# Checks: jq, curl
# Exits with error if any are missing
validate_dependencies() {
    local missing=()

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        for dep in "${missing[@]}"; do
            case "$dep" in
                jq)
                    log_info "Install jq: brew install jq (macOS) or apt-get install jq (Linux)"
                    ;;
                curl)
                    log_info "Install curl: brew install curl (macOS) or apt-get install curl (Linux)"
                    ;;
            esac
        done
        return 1
    fi

    return 0
}

# Validate we're in a git repository with an origin remote
# Exits with error if not in a git repo or no origin remote
validate_git_repository() {
    if ! git rev-parse --git-dir &>/dev/null; then
        log_error "Not a git repository"
        log_info "Run this command from within a git repository"
        return 1
    fi

    if ! git remote get-url origin &>/dev/null; then
        log_error "No 'origin' remote found"
        log_info "This repository must have an 'origin' remote configured"
        return 1
    fi

    return 0
}


# Resolve the real skill lib directory so this library can be sourced through
# project-root symlinks and from copied test wrappers.
_resolve_buildgit_realpath() {
    local source_path="$1"
    while [[ -L "$source_path" ]]; do
        local source_dir target_path
        source_dir="$(cd "$(dirname "$source_path")" && pwd -P)"
        target_path="$(readlink "$source_path")"
        if [[ "$target_path" != /* ]]; then
            source_path="${source_dir}/${target_path}"
        else
            source_path="$target_path"
        fi
    done
    echo "$(cd "$(dirname "$source_path")" && pwd -P)"
}

BUILDGIT_SKILL_LIB_DIR="$(_resolve_buildgit_realpath "${BASH_SOURCE[0]}")"

source "${BUILDGIT_SKILL_LIB_DIR}/jenkins-common/job_discovery.sh"
source "${BUILDGIT_SKILL_LIB_DIR}/jenkins-common/api_test_results.sh"
source "${BUILDGIT_SKILL_LIB_DIR}/jenkins-common/stage_test_correlation.sh"
source "${BUILDGIT_SKILL_LIB_DIR}/jenkins-common/failure_analysis.sh"
source "${BUILDGIT_SKILL_LIB_DIR}/jenkins-common/stage_display.sh"
source "${BUILDGIT_SKILL_LIB_DIR}/jenkins-common/output_render.sh"
source "${BUILDGIT_SKILL_LIB_DIR}/jenkins-common/json_output.sh"

display_failure_output() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"
    local trigger_type="$4"
    local trigger_user="$5"
    local commit_sha="$6"
    local commit_msg="$7"
    local correlation_status="$8"
    local console_output="${9:-}"

    # Extract values from build JSON
    local result duration timestamp url
    result=$(echo "$build_json" | jq -r '.result // "FAILURE"')
    duration=$(echo "$build_json" | jq -r '.duration // 0')
    timestamp=$(echo "$build_json" | jq -r '.timestamp // 0')
    url=$(echo "$build_json" | jq -r '.url // empty')

    local agent=""
    if [[ -n "$console_output" ]]; then
        _parse_build_metadata "$console_output"
        agent="${_META_AGENT:-}"
    fi

    # Display banner
    log_banner "failure"

    _print_build_header "$job_name" "$build_number" "${COLOR_RED}${result}${COLOR_RESET}" \
        "$trigger_type" "$trigger_user" "$commit_sha" "$commit_msg" "$correlation_status" \
        "$timestamp" "$agent" "$url"

    # Display all stages (includes not-executed stages for failed builds)
    # Spec: full-stage-print-spec.md, Section: Display Functions
    echo ""
    _display_stages "$job_name" "$build_number"

    # Failure diagnostics (shared)
    # Spec: refactor-shared-failure-diagnostics-spec.md
    _display_failure_diagnostics "$job_name" "$build_number" "$console_output"

    # Finished line and duration
    echo ""
    print_finished_line "$result"
    if [[ "$duration" != "0" && "$duration" =~ ^[0-9]+$ ]]; then
        log_info "Duration: $(format_duration "$duration")"
    fi
}
