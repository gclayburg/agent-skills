format_duration() {
    local ms="$1"

    # Handle empty or invalid input
    if [[ -z "$ms" || "$ms" == "null" || ! "$ms" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    local total_seconds=$((ms / 1000))
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))

    if [[ $hours -gt 0 ]]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [[ $minutes -gt 0 ]]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

# Format stage duration from milliseconds to human-readable format
# Extends format_duration with sub-second handling for pipeline stages
# Usage: format_stage_duration 154000
# Returns: "2m 34s", "45s", "<1s", "1h 5m 30s", or "unknown"
# Spec: full-stage-print-spec.md, Section: Duration format
format_stage_duration() {
    local ms="$1"

    # Handle empty or invalid input
    if [[ -z "$ms" || "$ms" == "null" || ! "$ms" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    # For sub-second durations (< 1000ms), return "<1s"
    if [[ "$ms" -lt 1000 ]]; then
        echo "<1s"
        return
    fi

    # For durations >= 1 second, delegate to format_duration
    format_duration "$ms"
}

# Print a single stage line with appropriate color and format
# Usage: print_stage_line "stage-name" "status" [duration_ms] [indent] [agent_prefix] [parallel_marker]
# status: SUCCESS, FAILED, UNSTABLE, IN_PROGRESS, NOT_EXECUTED, ABORTED
# indent: string of spaces for nesting (e.g., "  " for depth 1)
# agent_prefix: "[agent-name] " prepended to stage name
# parallel_marker: "║ " for parallel branch stages (default empty)
# Output format: [HH:MM:SS] ℹ   Stage: <indent><parallel_marker>[agent] <name> (<duration>)
# Spec: full-stage-print-spec.md, Section: Stage Display Format
# Spec: nested-jobs-display-spec.md, Section: Nested Stage Line Format
# Spec: bug-parallel-stages-display-spec.md, Section: Visual Parallel Stage Indication
_format_agent_prefix() {
    local agent_prefix="${1:-}"
    local agent_name=""

    if [[ "$agent_prefix" =~ ^\[(.*)\][[:space:]]*$ ]]; then
        agent_name="${BASH_REMATCH[1]}"
    elif [[ "$agent_prefix" =~ ^\[(.*)\][[:space:]] ]]; then
        agent_name="${BASH_REMATCH[1]}"
    else
        echo "$agent_prefix"
        return
    fi

    if [[ ${#agent_name} -gt 14 ]]; then
        agent_name="${agent_name:0:14}"
    fi

    printf "[%-14s] " "$agent_name"
}

print_stage_line() {
    local stage_name="$1"
    local status="$2"
    local duration_ms="${3:-}"
    local indent="${4:-}"
    local agent_prefix="${5:-}"
    local parallel_marker="${6:-}"
    local output_fd="${BUILDGIT_SIDE_EFFECT_FD:-1}"

    local timestamp
    timestamp=$(_timestamp)

    local color=""
    local suffix=""
    local marker=""
    local formatted_agent_prefix
    formatted_agent_prefix=$(_format_agent_prefix "$agent_prefix")

    case "$status" in
        SUCCESS)
            color="${COLOR_GREEN}"
            suffix="$(format_stage_duration "$duration_ms")"
            ;;
        FAILED)
            color="${COLOR_RED}"
            suffix="$(format_stage_duration "$duration_ms")"
            marker="    ${COLOR_RED}← FAILED${COLOR_RESET}"
            ;;
        UNSTABLE)
            color="${COLOR_YELLOW}"
            suffix="$(format_stage_duration "$duration_ms")"
            ;;
        IN_PROGRESS)
            color="${COLOR_CYAN}"
            suffix="running"
            ;;
        NOT_EXECUTED)
            color="${COLOR_DIM}"
            suffix="not executed"
            ;;
        ABORTED)
            color="${COLOR_RED}"
            suffix="aborted"
            ;;
        *)
            # Unknown status - use default
            color=""
            suffix="$(format_stage_duration "$duration_ms")"
            ;;
    esac

    # Build and output the stage line
    # Format: [HH:MM:SS] ℹ   Stage: <indent><parallel_marker>[agent] <name> (<suffix>)
    echo "${color}[${timestamp}] ℹ   Stage: ${indent}${parallel_marker}${formatted_agent_prefix}${stage_name} (${suffix})${COLOR_RESET}${marker}" >&"${output_fd}"
}

# Display stages from a build (with nested downstream stage expansion)
# Usage: _display_stages "job-name" "build-number" [--completed-only]
# When --completed-only: skips IN_PROGRESS/NOT_EXECUTED, saves state to _BANNER_STAGES_JSON
# Outputs: Stage lines to stdout in execution order
# Spec: full-stage-print-spec.md, Section: Display Functions
# Spec: bug-show-all-stages.md - never show "(running)" in initial display
# Spec: nested-jobs-display-spec.md - inline nested stage display
_display_stages() {
    local job_name="$1"
    local build_number="$2"
    local completed_only=false
    if [[ "${3:-}" == "--completed-only" ]]; then
        completed_only=true
    fi

    if [[ "$completed_only" == "true" ]]; then
        local build_info_json current_building
        build_info_json=$(get_build_info "$job_name" "$build_number" 2>/dev/null) || build_info_json=""
        current_building=$(echo "$build_info_json" | jq -r '.building // false' 2>/dev/null) || current_building="false"
        [[ -z "$current_building" || "$current_building" == "null" ]] && current_building="false"
        if [[ "$current_building" == "true" ]]; then
            local tracking_state tracking_log_file tracking_state_file
            tracking_log_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-banner-stage-log.XXXXXX")"
            tracking_state_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-banner-stage-state.XXXXXX")"
            BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "[]" "false" 3>"$tracking_log_file" >"$tracking_state_file" || true
            tracking_state=$(cat "$tracking_state_file" 2>/dev/null) || tracking_state="[]"
            if [[ -s "$tracking_log_file" ]]; then
                cat "$tracking_log_file"
            fi
            rm -f "$tracking_log_file" 2>/dev/null || true
            rm -f "$tracking_state_file" 2>/dev/null || true
            _BANNER_STAGES_JSON="${tracking_state:-[]}"
            return 0
        fi
    fi

    # Get nested stages (includes downstream expansion)
    local nested_stages_json
    nested_stages_json=$(_get_nested_stages "$job_name" "$build_number" 2>/dev/null) || nested_stages_json="[]"

    # Fallback to flat stages if nested fetch fails
    if [[ -z "$nested_stages_json" || "$nested_stages_json" == "[]" || "$nested_stages_json" == "null" ]]; then
        local stages_json
        stages_json=$(get_all_stages "$job_name" "$build_number")

        # Save composite tracking state for monitor initialization when in
        # completed-only mode (never seed flat parent stages — that marks
        # parallel branch summaries printed before monitoring emits them).
        if [[ "$completed_only" == "true" ]]; then
            local tracking_state tracking_log_file tracking_state_file
            tracking_log_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-banner-stage-log.XXXXXX")"
            tracking_state_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-banner-stage-state.XXXXXX")"
            BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "[]" "false" 3>"$tracking_log_file" >"$tracking_state_file" || true
            tracking_state=$(cat "$tracking_state_file" 2>/dev/null) || tracking_state="[]"
            rm -f "$tracking_log_file" 2>/dev/null || true
            rm -f "$tracking_state_file" 2>/dev/null || true
            _BANNER_STAGES_JSON="${tracking_state:-[]}"
        fi

        if [[ -z "$stages_json" || "$stages_json" == "[]" || "$stages_json" == "null" ]]; then
            return 0
        fi

        # Display flat stages (backward compatible)
        local stage_count
        stage_count=$(echo "$stages_json" | jq 'length')
        local i=0
        while [[ $i -lt $stage_count ]]; do
            local stage_name status duration_ms
            stage_name=$(echo "$stages_json" | jq -r ".[$i].name")
            status=$(echo "$stages_json" | jq -r ".[$i].status")
            duration_ms=$(echo "$stages_json" | jq -r ".[$i].durationMillis")

            if [[ "$completed_only" == "true" ]]; then
                case "$status" in
                    SUCCESS|FAILED|UNSTABLE|ABORTED)
                        print_stage_line "$stage_name" "$status" "$duration_ms"
                        ;;
                esac
            else
                print_stage_line "$stage_name" "$status" "$duration_ms"
            fi
            i=$((i + 1))
        done
        return 0
    fi

    # Save composite tracking state for monitor initialization when in
    # completed-only mode (must match nested display, not flat parent stages).
    if [[ "$completed_only" == "true" ]]; then
        local tracking_state tracking_log_file tracking_state_file
        tracking_log_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-banner-stage-log.XXXXXX")"
        tracking_state_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-banner-stage-state.XXXXXX")"
        BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "[]" "false" 3>"$tracking_log_file" >"$tracking_state_file" || true
        tracking_state=$(cat "$tracking_state_file" 2>/dev/null) || tracking_state="[]"
        rm -f "$tracking_log_file" 2>/dev/null || true
        rm -f "$tracking_state_file" 2>/dev/null || true
        _BANNER_STAGES_JSON="${tracking_state:-[]}"
    fi

    # Display nested stages with proper indentation and agent prefixes
    _display_nested_stages_json "$nested_stages_json" "$completed_only"
}

# Display nested stages from a pre-built JSON array
# Usage: _display_nested_stages_json "$nested_stages_json" "$completed_only"
# Spec: bug-parallel-stages-display-spec.md, Section: Visual Parallel Stage Indication
_display_nested_stages_json() {
    local nested_stages_json="$1"
    local completed_only="${2:-false}"

    local stage_count
    stage_count=$(echo "$nested_stages_json" | jq 'length')

    local i=0
    while [[ $i -lt $stage_count ]]; do
        local stage_name status duration_ms agent nesting_depth
        stage_name=$(echo "$nested_stages_json" | jq -r ".[$i].name")
        status=$(echo "$nested_stages_json" | jq -r ".[$i].status")
        duration_ms=$(echo "$nested_stages_json" | jq -r ".[$i].durationMillis")
        agent=$(echo "$nested_stages_json" | jq -r ".[$i].agent // empty")
        nesting_depth=$(echo "$nested_stages_json" | jq -r ".[$i].nesting_depth // 0")

        # Check for parallel branch/path annotations
        local parallel_branch
        parallel_branch=$(echo "$nested_stages_json" | jq -r ".[$i].parallel_branch // empty")
        local parallel_path
        parallel_path=$(echo "$nested_stages_json" | jq -r ".[$i].parallel_path // empty")

        # Build indentation (2 spaces per nesting level)
        local indent=""
        local d=0
        while [[ $d -lt $nesting_depth ]]; do
            indent="${indent}  "
            d=$((d + 1))
        done

        # Determine parallel marker
        local parallel_marker=""
        if [[ -n "$parallel_path" ]]; then
            parallel_marker="║${parallel_path} "
            # For parallel branches at depth 0, add indent
            if [[ $nesting_depth -eq 0 ]]; then
                indent="  "
            fi
        elif [[ -n "$parallel_branch" ]]; then
            parallel_marker="║ "
            if [[ $nesting_depth -eq 0 ]]; then
                indent="  "
            fi
        fi

        # Build agent prefix
        local agent_prefix=""
        if [[ -n "$agent" ]]; then
            agent_prefix="[${agent}] "
        fi

        if [[ "$completed_only" == "true" ]]; then
            case "$status" in
                SUCCESS|FAILED|UNSTABLE|ABORTED)
                    print_stage_line "$stage_name" "$status" "$duration_ms" "$indent" "$agent_prefix" "$parallel_marker"
                    ;;
            esac
        else
            print_stage_line "$stage_name" "$status" "$duration_ms" "$indent" "$agent_prefix" "$parallel_marker"
        fi

        i=$((i + 1))
    done
}

# Convenience aliases for backward compatibility in callers
_display_all_stages() {
    _display_stages "$1" "$2"
}

_display_completed_stages() {
    _display_stages "$1" "$2" --completed-only
}

# Track stage state changes and print completed stages
# Usage: new_state=$(track_stage_changes "job-name" "build-number" "$previous_state" "$verbose")
# Returns: Current stages JSON on stdout (capture for next iteration)
# Side effect: Prints completed/running stage lines to stderr
# Spec: full-stage-print-spec.md, Section: Stage Tracking
track_stage_changes() {
    local job_name="$1"
    local build_number="$2"
    local previous_stages_json="${3:-[]}"
    local verbose="${4:-false}"

    # Fetch current stages
    local current_stages_json
    current_stages_json=$(get_all_stages "$job_name" "$build_number")

    # Handle empty or invalid previous state
    if [[ -z "$previous_stages_json" || "$previous_stages_json" == "null" ]]; then
        previous_stages_json="[]"
    fi

    # Handle empty current stages - just return previous state unchanged
    if [[ "$current_stages_json" == "[]" ]]; then
        echo "$previous_stages_json"
        return 0
    fi

    # Process each stage and detect transitions
    local stage_count
    stage_count=$(echo "$current_stages_json" | jq 'length')

    # Check if this is the first poll (previous state was empty)
    local prev_count
    prev_count=$(echo "$previous_stages_json" | jq 'length')

    local i=0

    while [[ $i -lt $stage_count ]]; do
        local stage_name current_status duration_ms
        stage_name=$(echo "$current_stages_json" | jq -r ".[$i].name")
        current_status=$(echo "$current_stages_json" | jq -r ".[$i].status")
        duration_ms=$(echo "$current_stages_json" | jq -r ".[$i].durationMillis")

        # Get previous status for this stage (by name)
        local previous_status
        previous_status=$(echo "$previous_stages_json" | jq -r --arg name "$stage_name" \
            '.[] | select(.name == $name) | .status // "NOT_EXECUTED"')

        # Default to NOT_EXECUTED if stage wasn't in previous state
        if [[ -z "$previous_status" ]]; then
            previous_status="NOT_EXECUTED"
        fi

        # Detect transitions and print completed stages
        case "$current_status" in
            SUCCESS|FAILED|UNSTABLE|ABORTED)
                # Print if stage transitioned from IN_PROGRESS or appeared already completed
                # The NOT_EXECUTED case catches fast stages that complete between polls
                # Spec: bug-show-all-stages.md - all stages must be shown
                if [[ "$previous_status" == "IN_PROGRESS" || "$previous_status" == "NOT_EXECUTED" ]]; then
                    print_stage_line "$stage_name" "$current_status" "$duration_ms"
                fi
                ;;
            IN_PROGRESS)
                # Only print running stage in verbose mode, and only once when it first starts
                # Non-verbose mode: no "(running)" output - only print when stages complete
                if [[ "$verbose" == "true" && "$previous_status" == "NOT_EXECUTED" ]]; then
                    print_stage_line "$stage_name" "IN_PROGRESS"
                fi
                ;;
        esac

        i=$((i + 1))
    done

    # Return current state for next iteration
    echo "$current_stages_json"
}

