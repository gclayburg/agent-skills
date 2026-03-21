format_timestamp() {
    local epoch_ms="$1"

    # Handle empty or invalid input
    if [[ -z "$epoch_ms" || "$epoch_ms" == "null" || ! "$epoch_ms" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    local epoch_seconds=$((epoch_ms / 1000))

    # Use date command (macOS and Linux compatible)
    if [[ "$(uname)" == "Darwin" ]]; then
        date -r "$epoch_seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown"
    else
        date -d "@$epoch_seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown"
    fi
}

# Format ISO 8601 timestamp from epoch milliseconds (for JSON output)
# Usage: format_timestamp_iso 1705329125000
# Returns: "2024-01-15T14:32:05Z"
format_timestamp_iso() {
    local epoch_ms="$1"

    # Handle empty or invalid input
    if [[ -z "$epoch_ms" || "$epoch_ms" == "null" || ! "$epoch_ms" =~ ^[0-9]+$ ]]; then
        echo "null"
        return
    fi

    local epoch_seconds=$((epoch_ms / 1000))

    # Use date command (macOS and Linux compatible)
    if [[ "$(uname)" == "Darwin" ]]; then
        date -r "$epoch_seconds" -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null"
    else
        date -d "@$epoch_seconds" -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null"
    fi
}

# Format trigger type into display string
# Usage: _format_trigger_display "automated" "username"
# Returns: "SCM change", "Manual by username", "Timer", "Upstream", or "Unknown"
_format_trigger_display() {
    local trigger_type="$1"
    local trigger_user="$2"

    case "$trigger_type" in
        manual)
            if [[ -n "$trigger_user" && "$trigger_user" != "unknown" ]]; then
                echo "Manual by ${trigger_user}"
            else
                echo "Manual"
            fi
            ;;
        scm)
            echo "SCM change"
            ;;
        timer)
            echo "Timer"
            ;;
        upstream)
            echo "Upstream"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# Format commit SHA and message into display string
# Usage: _format_commit_display "abc1234..." "commit message"
# Returns: "abc1234  commit message" or "abc1234" or "unknown"
_format_commit_display() {
    local commit_sha="$1"
    local commit_msg="$2"
    local max_value_width=100

    if [[ -n "$commit_sha" && "$commit_sha" != "unknown" ]]; then
        local short_sha="${commit_sha:0:7}"
        if [[ -n "$commit_msg" && "$commit_msg" != "unknown" ]]; then
            local subject
            local max_msg_len
            subject=$(printf '%s\n' "$commit_msg" | sed -n '1{s/\r$//;p;}')
            max_msg_len=$((max_value_width - ${#short_sha} - 2))
            if [[ "$max_msg_len" -lt 1 ]]; then
                echo "${short_sha}"
                return
            fi
            if [[ ${#subject} -gt $max_msg_len ]]; then
                if [[ "$max_msg_len" -gt 3 ]]; then
                    subject="${subject:0:$((max_msg_len - 3))}..."
                else
                    subject="${subject:0:$max_msg_len}"
                fi
            fi
            echo "${short_sha}  ${subject}"
        else
            echo "${short_sha}"
        fi
    else
        echo "unknown"
    fi
}

# Format correlation status into colored display components
# Usage: _format_correlation_display "correlation_status"
# Sets: _CORRELATION_SYMBOL, _CORRELATION_DESC, _CORRELATION_COLOR
_format_correlation_display() {
    local correlation_status="$1"

    _CORRELATION_SYMBOL=$(get_correlation_symbol "$correlation_status")
    _CORRELATION_DESC=$(describe_commit_correlation "$correlation_status")
    if [[ "$correlation_status" == "your_commit" || "$correlation_status" == "in_history" ]]; then
        _CORRELATION_COLOR="${COLOR_GREEN}"
    else
        _CORRELATION_COLOR="${COLOR_RED}"
    fi
}

_print_build_header() {
    local job_name="$1"
    local build_number="$2"
    local status_display="$3"
    local trigger_type="$4"
    local trigger_user="$5"
    local commit_sha="$6"
    local commit_msg="$7"
    local correlation_status="$8"
    local timestamp="$9"
    local agent="${10:-}"
    local url="${11:-}"
    local trigger_display commit_display

    trigger_display=$(_format_trigger_display "$trigger_type" "$trigger_user")

    echo "Job:        ${job_name}"
    echo "Build:      #${build_number}"
    echo "Status:     ${status_display}"
    echo "Trigger:    ${trigger_display}"

    if [[ -n "$commit_sha" && "$commit_sha" != "unknown" ]]; then
        commit_display=$(_format_commit_display "$commit_sha" "$commit_msg")
        _format_correlation_display "$correlation_status"
        echo "Commit:     ${commit_display}"
        echo "            ${_CORRELATION_COLOR}${_CORRELATION_SYMBOL} ${_CORRELATION_DESC}${COLOR_RESET}"
    fi

    echo "Started:    $(format_timestamp "$timestamp")"
    if [[ -n "$agent" ]]; then
        echo "Agent:      ${agent}"
    fi
    if [[ -n "$url" ]]; then
        echo "Console:    ${url}console"
    fi
}

# Display successful build output
# Usage: display_success_output "job_name" "build_number" "build_json" "trigger_type" "trigger_user" "commit_sha" "commit_msg" "correlation_status"
display_success_output() {
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
    local duration timestamp url
    duration=$(echo "$build_json" | jq -r '.duration // 0')
    timestamp=$(echo "$build_json" | jq -r '.timestamp // 0')
    url=$(echo "$build_json" | jq -r '.url // empty')

    # Format display components
    local agent=""
    if [[ -n "$console_output" ]]; then
        _parse_build_metadata "$console_output"
        agent="${_META_AGENT:-}"
    fi

    # Display banner
    log_banner "success"

    _print_build_header "$job_name" "$build_number" "${COLOR_GREEN}SUCCESS${COLOR_RESET}" \
        "$trigger_type" "$trigger_user" "$commit_sha" "$commit_msg" "$correlation_status" \
        "$timestamp" "$agent" "$url"

    # Display all stages
    # Spec: full-stage-print-spec.md, Section: Display Functions
    echo ""
    _display_stages "$job_name" "$build_number"

    # Display test results for SUCCESS builds
    # Spec: show-test-results-always-spec.md, Section 1.1
    local test_results_console_output collected_results collected_rc=0
    test_results_console_output="$console_output"
    if [[ -z "$test_results_console_output" ]]; then
        test_results_console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null || true)
    fi
    if collected_results=$(collect_downstream_test_results "$job_name" "$build_number" "$test_results_console_output"); then
        collected_rc=0
    else
        collected_rc=$?
        collected_results=""
    fi
    if [[ "$collected_rc" -eq 2 ]]; then
        _note_test_results_comm_failure "$job_name" "$build_number"
        display_test_results_comm_error
    else
        display_hierarchical_test_results "$collected_results"
    fi

    # Finished line and duration
    echo ""
    print_finished_line "SUCCESS"
    if [[ "$duration" != "0" && "$duration" =~ ^[0-9]+$ ]]; then
        log_info "Duration: $(format_duration "$duration")"
    fi
}

# Display failed build output
# Usage: display_failure_output "job_name" "build_number" "build_json" "trigger_type" "trigger_user" "commit_sha" "commit_msg" "correlation_status" "console_output"
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

    # Format display components
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

# Display failed jobs tree for failure output
# Usage: _display_failed_jobs_tree "job_name" "build_number" "console_output"
_display_failed_jobs_tree() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"

    echo ""
    echo "${COLOR_YELLOW}=== Failed Jobs ===${COLOR_RESET}"

    # Get failed stage for the root job
    local failed_stage
    failed_stage=$(get_failed_stage "$job_name" "$build_number")

    local stage_suffix=""
    if [[ -n "$failed_stage" ]]; then
        stage_suffix=" (stage: ${failed_stage})"
    fi

    # Find downstream builds
    local downstream_builds
    downstream_builds=$(detect_all_downstream_builds "$console_output")

    if [[ -z "$downstream_builds" ]]; then
        # No downstream builds - root job failed directly
        echo "  → ${job_name}${stage_suffix}  ${COLOR_RED}← FAILED${COLOR_RESET}"
    else
        # Has downstream builds - find the failed one
        local failed_downstream
        failed_downstream=$(find_failed_downstream_build "$console_output")

        echo "  → ${job_name}${stage_suffix}"

        # Display downstream builds with indentation
        local indent="    "
        while IFS=' ' read -r ds_job ds_build; do
            if [[ -n "$ds_job" && -n "$ds_build" ]]; then
                if check_build_failed "$ds_job" "$ds_build"; then
                    # Check if this failed job has its own downstream builds
                    local ds_console
                    ds_console=$(get_console_output "$ds_job" "$ds_build")
                    local ds_downstream
                    ds_downstream=$(detect_all_downstream_builds "$ds_console")

                    if [[ -n "$ds_downstream" ]]; then
                        echo "${indent}→ ${ds_job}"
                        # Recursively show nested downstream
                        _display_nested_downstream "$ds_job" "$ds_build" "$ds_console" "${indent}  "
                    else
                        echo "${indent}→ ${ds_job}  ${COLOR_RED}← FAILED${COLOR_RESET}"
                    fi
                else
                    echo "${indent}→ ${ds_job}  ✓"
                fi
            fi
        done <<< "$downstream_builds"
    fi

    echo "${COLOR_YELLOW}====================${COLOR_RESET}"
}

# Helper to display nested downstream builds recursively
# Usage: _display_nested_downstream "job_name" "build_number" "console_output" "indent"
_display_nested_downstream() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"
    local indent="$4"

    local downstream_builds
    downstream_builds=$(detect_all_downstream_builds "$console_output")

    while IFS=' ' read -r ds_job ds_build; do
        if [[ -n "$ds_job" && -n "$ds_build" ]]; then
            if check_build_failed "$ds_job" "$ds_build"; then
                local ds_console
                ds_console=$(get_console_output "$ds_job" "$ds_build")
                local ds_downstream
                ds_downstream=$(detect_all_downstream_builds "$ds_console")

                if [[ -n "$ds_downstream" ]]; then
                    echo "${indent}→ ${ds_job}"
                    _display_nested_downstream "$ds_job" "$ds_build" "$ds_console" "${indent}  "
                else
                    echo "${indent}→ ${ds_job}  ${COLOR_RED}← FAILED${COLOR_RESET}"
                fi
            else
                echo "${indent}→ ${ds_job}  ✓"
            fi
        fi
    done <<< "$downstream_builds"
}

# Display full console output for early build failures (no stages ran)
# Usage: _display_early_failure_console "job_name" "build_number" "console_output"
# Returns: 0 if early failure detected and console displayed, 1 if stages exist (caller should use existing logic)
# Spec: buildgit-early-build-failure-spec.md
_display_early_failure_console() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"

    local stages
    stages=$(get_all_stages "$job_name" "$build_number")

    # Check if stages array is empty (no pipeline stages executed)
    local stage_count
    stage_count=$(echo "$stages" | jq 'length' 2>/dev/null) || stage_count=0

    if [[ "$stage_count" -gt 0 ]]; then
        return 1  # Stages exist, caller should use existing logic
    fi

    # Early failure - display full console output
    echo ""
    echo "${COLOR_YELLOW}=== Console Output ===${COLOR_RESET}"
    if [[ -n "$console_output" ]]; then
        echo "$console_output"
    fi
    echo "${COLOR_YELLOW}======================${COLOR_RESET}"
    return 0
}

# Constants for fallback behavior
# Spec: bug1-jenkins-log-truncated-spec.md, Section: Fallback Behavior
STAGE_LOG_MIN_LINES=5        # Minimum lines for extraction to be considered sufficient
STAGE_LOG_FALLBACK_LINES=50  # Lines to show in fallback mode

# Shared error log display decision logic
# Decides whether and how to show error logs based on test failure presence and CONSOLE_MODE.
# Used by both _handle_build_completion (monitoring path) and display_failure_output (snapshot path).
# Usage: _display_error_log_section "job_name" "build_number" "console_output" "test_results_json"
# Spec: bug2026-02-12-phandlemono-no-logs-spec.md, Section: Shared error log display logic
_display_error_log_section() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"
    local test_results_json="${4:-}"

    local has_test_failures=false
    if [[ -n "$test_results_json" ]]; then
        local fail_count
        fail_count=$(echo "$test_results_json" | jq -r '.failCount // 0') || fail_count=0
        if [[ "$fail_count" -gt 0 ]]; then
            has_test_failures=true
        fi
    fi

    if [[ "$has_test_failures" == "true" && -z "${CONSOLE_MODE:-}" ]]; then
        # Suppress error logs: test results section is sufficient
        :
    elif [[ "${CONSOLE_MODE:-}" =~ ^[0-9]+$ ]]; then
        # Show last N lines of raw console output
        echo ""
        echo "${COLOR_YELLOW}=== Console Log (last ${CONSOLE_MODE} lines) ===${COLOR_RESET}"
        echo "$console_output" | tail -"${CONSOLE_MODE}"
        echo "${COLOR_YELLOW}================================================${COLOR_RESET}"
    else
        # Default for non-SUCCESS without test failures, or --console auto
        _display_error_logs "$job_name" "$build_number" "$console_output"
    fi
}

# Display error logs section for failure output
# Usage: _display_error_logs "job_name" "build_number" "console_output"
#
# Implements fallback behavior when stage extraction produces insufficient output:
# - If extracted logs have fewer than STAGE_LOG_MIN_LINES lines, triggers fallback
# - Fallback shows last STAGE_LOG_FALLBACK_LINES lines with explanatory message
# Spec: bug1-jenkins-log-truncated-spec.md, Section: Fallback Behavior
_display_error_logs() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"

    # Check for early failure (no stages ran) - show full console instead of error extraction
    # Spec: buildgit-early-build-failure-spec.md
    if _display_early_failure_console "$job_name" "$build_number" "$console_output"; then
        return 0
    fi

    echo ""
    echo "${COLOR_YELLOW}=== Error Logs ===${COLOR_RESET}"

    # Check for downstream build failure first
    local downstream
    downstream=$(find_failed_downstream_build "$console_output")

    if [[ -n "$downstream" ]]; then
        local ds_job ds_build
        ds_job=$(echo "$downstream" | cut -d' ' -f1)
        ds_build=$(echo "$downstream" | cut -d' ' -f2)

        local ds_console
        ds_console=$(get_console_output "$ds_job" "$ds_build")

        if [[ -n "$ds_console" ]]; then
            extract_error_lines "$ds_console" 30
        else
            extract_error_lines "$console_output" 30
        fi
    else
        # No downstream - try to get stage-specific logs
        local failed_stage
        failed_stage=$(get_failed_stage "$job_name" "$build_number")

        if [[ -n "$failed_stage" ]]; then
            local stage_logs
            stage_logs=$(extract_stage_logs "$console_output" "$failed_stage")

            # Check if extraction produced sufficient output
            # Spec: bug1-jenkins-log-truncated-spec.md, Section: Fallback Behavior
            local line_count
            line_count=$(echo "$stage_logs" | wc -l | tr -d ' ')

            if [[ -n "$stage_logs" ]] && [[ "$line_count" -ge "$STAGE_LOG_MIN_LINES" ]]; then
                extract_error_lines "$stage_logs" 30
            else
                # Fallback: extraction empty or insufficient
                echo "${COLOR_YELLOW}Stage log extraction may be incomplete. Showing last ${STAGE_LOG_FALLBACK_LINES} lines:${COLOR_RESET}"
                echo ""
                echo "$console_output" | tail -"$STAGE_LOG_FALLBACK_LINES"
            fi
        else
            extract_error_lines "$console_output" 30
        fi
    fi

    echo "${COLOR_YELLOW}==================${COLOR_RESET}"
}

# Display all failure diagnostic sections for human-readable output
# This is the single entry point for failure diagnostics, called by both
# display_failure_output (snapshot path) and _handle_build_completion (monitoring path).
# Usage: _display_failure_diagnostics "job_name" "build_number" "console_output"
# Spec: refactor-shared-failure-diagnostics-spec.md
_display_failure_diagnostics() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"

    # 1. Early failure (no stages ran) → show full console, return
    if _display_early_failure_console "$job_name" "$build_number" "$console_output"; then
        return 0
    fi

    # 2. Failed jobs tree (with downstream detection)
    _display_failed_jobs_tree "$job_name" "$build_number" "$console_output"

    # 3. Test results (always shown, placeholder if no report)
    # Spec: show-test-results-always-spec.md, Section 1
    local collected_results collected_rc=0 parent_test_json=""
    if collected_results=$(collect_downstream_test_results "$job_name" "$build_number" "$console_output"); then
        collected_rc=0
        parent_test_json=$(echo "$collected_results" | jq -r '.[0].test_json // empty')
    else
        collected_rc=$?
        collected_results=""
    fi
    if [[ "$collected_rc" -eq 2 ]]; then
        _note_test_results_comm_failure "$job_name" "$build_number"
        display_test_results_comm_error
    else
        display_hierarchical_test_results "$collected_results"
    fi

    # 4. Error log section (respects --console and test failure suppression)
    _display_error_log_section "$job_name" "$build_number" "$console_output" "$parent_test_json"
}

# Display in-progress build output (unified header format)
# Usage: display_building_output "job_name" "build_number" "build_json" "trigger_type" "trigger_user" "commit_sha" "commit_msg" "correlation_status" "current_stage" "console_output" "running_msg"
# Spec: unify-follow-log-spec.md, Section 2 (Build Header)
display_building_output() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"
    local trigger_type="$4"
    local trigger_user="$5"
    local commit_sha="$6"
    local commit_msg="$7"
    local correlation_status="$8"
    local current_stage="${9:-}"
    local console_output="${10:-}"
    local running_msg="${11:-}"

    # Extract values from build JSON
    local timestamp url
    timestamp=$(echo "$build_json" | jq -r '.timestamp // 0')
    url=$(echo "$build_json" | jq -r '.url // empty')

    # Format display components
    local agent=""
    if [[ -n "$console_output" ]]; then
        _parse_build_metadata "$console_output"
        agent="${_META_AGENT:-}"
    fi

    # Display banner
    log_banner "building"

    # Display running-time message if provided (status -f joining in-progress build)
    if [[ -n "$running_msg" ]]; then
        echo "$running_msg"
        echo ""
    fi

    local header_url=""
    if [[ -n "$commit_sha" && "$commit_sha" != "unknown" && -n "$agent" ]]; then
        header_url="$url"
    fi

    _print_build_header "$job_name" "$build_number" "${COLOR_YELLOW}BUILDING${COLOR_RESET}" \
        "$trigger_type" "$trigger_user" "$commit_sha" "$commit_msg" "$correlation_status" \
        "$timestamp" "$agent" "$header_url"
}

# =============================================================================
# Git Commit Correlation Functions
# =============================================================================

# Correlate a commit SHA with the local git history
# Usage: correlate_commit "sha"
# Returns: Outputs a single line with the correlation status:
#   - "your_commit" - SHA matches current HEAD
#   - "in_history" - SHA is an ancestor of HEAD (in your history)
#   - "not_in_history" - SHA exists locally but not reachable from HEAD
#   - "unknown" - SHA not found in local repository
# Always returns 0; outputs 'unknown' for invalid/malformed SHA or git failures
correlate_commit() {
    local sha="$1"

    # Validate input
    if [[ -z "$sha" || "$sha" == "unknown" ]]; then
        echo "unknown"
        return 0
    fi

    # Validate SHA format (7-40 hex characters)
    if [[ ! "$sha" =~ ^[a-fA-F0-9]{7,40}$ ]]; then
        echo "unknown"
        return 0
    fi

    # Get current HEAD SHA for comparison
    local head_sha
    head_sha=$(git rev-parse HEAD 2>/dev/null) || {
        echo "unknown"
        return 0
    }

    # Normalize the input SHA to full form if it exists
    local full_sha
    full_sha=$(git rev-parse "$sha" 2>/dev/null) || true

    # Check 1: Does the commit exist locally?
    if ! git cat-file -t "$sha" &>/dev/null; then
        echo "unknown"
        return 0
    fi

    # Check 2: Is it exactly HEAD?
    # Compare the full SHA forms
    if [[ -n "$full_sha" && "$full_sha" == "$head_sha" ]]; then
        echo "your_commit"
        return 0
    fi

    # Check 3: Is it reachable from HEAD (an ancestor)?
    if git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        echo "in_history"
        return 0
    fi

    # Commit exists but is not reachable from HEAD
    echo "not_in_history"
    return 0
}

# Get human-readable description of commit correlation status
# Usage: describe_commit_correlation "status"
# Returns: Human-readable description string
describe_commit_correlation() {
    local status="$1"

    case "$status" in
        your_commit)
            echo "Your commit (HEAD)"
            ;;
        in_history)
            echo "In your history (reachable from HEAD)"
            ;;
        not_in_history)
            echo "Not in your history"
            ;;
        unknown|*)
            echo "Unknown commit"
            ;;
    esac
}

# Get symbol for commit correlation status (for display)
# Usage: get_correlation_symbol "status"
# Returns: Symbol (checkmark or X)
get_correlation_symbol() {
    local status="$1"

    case "$status" in
        your_commit|in_history)
            echo "✓"
            ;;
        not_in_history|unknown|*)
            echo "✗"
            ;;
    esac
}

# =============================================================================
# JSON Output Functions
# =============================================================================

# Global flag for JSON output mode
JSON_OUTPUT_MODE="${JSON_OUTPUT_MODE:-false}"

# Output build status as JSON
# Usage: output_json "job_name" "build_number" "build_json" "trigger_type" "trigger_user" "commit_sha" "commit_msg" "correlation_status" ["console_output"]
# For failed builds, also extracts failure info from console_output
