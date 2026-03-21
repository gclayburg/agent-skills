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

        # Save full stages JSON for monitor initialization when in completed-only mode
        if [[ "$completed_only" == "true" ]]; then
            _BANNER_STAGES_JSON="${stages_json:-[]}"
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

    # Save full stages JSON for monitor initialization when in completed-only mode
    # We save just the parent build's stages for tracking state
    if [[ "$completed_only" == "true" ]]; then
        _BANNER_STAGES_JSON=$(get_all_stages "$job_name" "$build_number") || _BANNER_STAGES_JSON="[]"
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

# Return success when the provided stage status is terminal.
_stage_status_is_terminal() {
    case "${1:-}" in
        SUCCESS|FAILED|UNSTABLE|ABORTED) return 0 ;;
        *) return 1 ;;
    esac
}

_print_nested_stage_entry() {
    local stage_entry="$1"

    local stage_name status duration_ms agent nesting_depth parallel_path parallel_branch
    stage_name=$(echo "$stage_entry" | jq -r '.name')
    status=$(echo "$stage_entry" | jq -r '.status')
    duration_ms=$(echo "$stage_entry" | jq -r '.durationMillis')
    agent=$(echo "$stage_entry" | jq -r '.agent // empty')
    nesting_depth=$(echo "$stage_entry" | jq -r '.nesting_depth // 0')
    parallel_path=$(echo "$stage_entry" | jq -r '.parallel_path // empty')
    parallel_branch=$(echo "$stage_entry" | jq -r '.parallel_branch // empty')

    local indent=""
    local d=0
    while [[ $d -lt $nesting_depth ]]; do
        indent="${indent}  "
        d=$((d + 1))
    done

    local parallel_marker=""
    if [[ -n "$parallel_path" ]]; then
        parallel_marker="║${parallel_path} "
        if [[ $nesting_depth -eq 0 ]]; then
            indent="  "
        fi
    elif [[ -n "$parallel_branch" ]]; then
        parallel_marker="║ "
        if [[ $nesting_depth -eq 0 ]]; then
            indent="  "
        fi
    fi

    local agent_prefix=""
    if [[ -n "$agent" ]]; then
        agent_prefix="[${agent}] "
    fi

    print_stage_line "$stage_name" "$status" "$duration_ms" "$indent" "$agent_prefix" "$parallel_marker"
}

_build_parallel_tracking_state() {
    local current_nested="$1"
    local previous_parallel_state="${2:-{}}"
    local build_info_json current_building="true"
    build_info_json=$(get_build_info "$job_name" "$build_number" 2>/dev/null) || true
    if [[ -n "$build_info_json" ]]; then
        current_building=$(echo "$build_info_json" | jq -r '.building // true' 2>/dev/null)
        [[ -z "$current_building" || "$current_building" == "null" ]] && current_building="true"
    fi

    local result="{}"
    local wrapper_names
    wrapper_names=$(echo "$current_nested" | jq -r '.[] | select(.is_parallel_wrapper == true) | .name' 2>/dev/null) || true

    while IFS= read -r wrapper_name; do
        [[ -z "$wrapper_name" ]] && continue

        local wrapper_idx wrapper_depth branch_depth declared_branches known_branches first_known_idx prev_first_idx scan_start
        wrapper_idx=$(echo "$current_nested" | jq -r --arg w "$wrapper_name" 'to_entries[] | select(.value.name == $w) | .key' | head -1)
        wrapper_depth=$(echo "$current_nested" | jq -r --arg w "$wrapper_name" '.[] | select(.name == $w) | .nesting_depth // 0' | head -1)
        branch_depth="$wrapper_depth"
        declared_branches=$(echo "$current_nested" | jq -c --arg w "$wrapper_name" '.[] | select(.name == $w) | (.parallel_branches // [])' | head -1)
        known_branches=$(echo "$current_nested" | jq -c --arg w "$wrapper_name" --argjson declared "${declared_branches:-[]}" '
            [to_entries[] as $e
             | select((($e.value.parallel_wrapper // "") == $w) or any($declared[]?; . == $e.value.name))
             | {idx: $e.key, name: $e.value.name, path: ($e.value.parallel_path // ""), depth: ($e.value.nesting_depth // 0)}
            ]
        ' 2>/dev/null)
        [[ -z "$known_branches" || "$known_branches" == "null" ]] && known_branches="[]"
        known_branches=$(echo "$known_branches" | jq -c 'sort_by(.idx)' 2>/dev/null)
        branch_depth=$(echo "$known_branches" | jq -r 'if length > 0 then (.[0].depth // empty) else empty end' 2>/dev/null)
        [[ -z "$branch_depth" ]] && branch_depth="$wrapper_depth"
        first_known_idx=$(echo "$known_branches" | jq -r 'if length > 0 then .[0].idx else "" end' 2>/dev/null)
        prev_first_idx=$(echo "$previous_parallel_state" | jq -r --arg w "$wrapper_name" '.[$w].first_idx // empty' 2>/dev/null)

        scan_start=""
        if [[ -n "$first_known_idx" ]]; then
            scan_start="$first_known_idx"
        elif [[ -n "$prev_first_idx" ]]; then
            scan_start="$prev_first_idx"
        fi
        [[ -z "$scan_start" ]] && continue

        local branch_entries
        branch_entries=$(echo "$current_nested" | jq -c \
            --argjson start "$scan_start" \
            --argjson end "$wrapper_idx" \
            --argjson depth "$branch_depth" \
            '[to_entries[]
              | select(.key >= $start and .key < $end)
              | .value + {__idx: .key}
              | select((.nesting_depth // 0) == $depth and (.is_parallel_wrapper // false) != true)
             ]' 2>/dev/null)
        [[ -z "$branch_entries" || "$branch_entries" == "null" ]] && branch_entries="[]"

        local observed_count prev_observed_count stable_polls path_prefix
        observed_count=$(echo "$branch_entries" | jq 'length' 2>/dev/null) || observed_count=0
        prev_observed_count=$(echo "$previous_parallel_state" | jq -r --arg w "$wrapper_name" '.[$w].observed_count // -1' 2>/dev/null)
        if [[ "$prev_observed_count" == "$observed_count" ]]; then
            stable_polls=$(echo "$previous_parallel_state" | jq -r --arg w "$wrapper_name" '(.[$w].stable_polls // 0) + 1' 2>/dev/null)
        else
            stable_polls=1
        fi

        path_prefix=$(echo "$known_branches" | jq -r '
            if length == 0 then ""
            else
                .[0].path
                | if . == "" then ""
                  elif contains(".") then sub("\\.[^.]+$"; "")
                  else ""
                  end
            end' 2>/dev/null)

        local all_terminal="true"
        local all_ready="true"
        local branch_state="{}"
        local wrapper_status wrapper_duration wrapper_terminal=false
        wrapper_status=$(echo "$current_nested" | jq -r --arg w "$wrapper_name" '.[] | select(.name == $w) | .status' | head -1)
        wrapper_duration=$(echo "$current_nested" | jq -r --arg w "$wrapper_name" '.[] | select(.name == $w) | .durationMillis' | head -1)
        if _stage_status_is_terminal "$wrapper_status"; then
            wrapper_terminal=true
        fi
        local branch_index=0
        while [[ $branch_index -lt $observed_count ]]; do
            local branch_name branch_status branch_duration branch_fingerprint prev_branch_fingerprint prev_branch_status branch_stable_polls branch_ready
            branch_name=$(echo "$branch_entries" | jq -r ".[$branch_index].name")
            branch_status=$(echo "$branch_entries" | jq -r ".[$branch_index].status")
            branch_duration=$(echo "$branch_entries" | jq -r ".[$branch_index].durationMillis")
            branch_fingerprint=$(echo "$branch_entries" | jq -c ".[$branch_index] | {status, durationMillis}" 2>/dev/null)
            prev_branch_fingerprint=$(echo "$previous_parallel_state" | jq -c --arg w "$wrapper_name" --arg b "$branch_name" '.[$w].branch_state[$b].fingerprint // {}' 2>/dev/null)
            prev_branch_status=$(echo "$previous_parallel_state" | jq -r --arg w "$wrapper_name" --arg b "$branch_name" '.[$w].branch_state[$b].fingerprint.status // empty' 2>/dev/null)
            if [[ -n "$branch_fingerprint" && "$branch_fingerprint" == "$prev_branch_fingerprint" ]]; then
                branch_stable_polls=$(echo "$previous_parallel_state" | jq -r --arg w "$wrapper_name" --arg b "$branch_name" '(.[$w].branch_state[$b].stable_polls // 0) + 1' 2>/dev/null)
            else
                branch_stable_polls=1
            fi
            branch_ready="false"
            local terminal_transition=false
            if [[ -n "$prev_branch_status" ]] && ! _stage_status_is_terminal "$prev_branch_status" && _stage_status_is_terminal "$branch_status"; then
                terminal_transition=true
            fi
            if _stage_status_is_terminal "$branch_status" \
                && [[ -n "$branch_duration" && "$branch_duration" != "null" && "$branch_duration" =~ ^[0-9]+$ ]] \
                && [[ "$branch_duration" -ge 1000 || "$current_building" == "false" ]] \
                && ([[ "$terminal_transition" == "true" && "$wrapper_terminal" != "true" ]] || [[ "$branch_stable_polls" -ge 2 ]]); then
                branch_ready="true"
            fi
            if ! _stage_status_is_terminal "$branch_status"; then
                all_terminal="false"
                all_ready="false"
            elif [[ "$branch_ready" != "true" ]]; then
                all_ready="false"
            fi
            branch_state=$(echo "$branch_state" | jq \
                --arg b "$branch_name" \
                --argjson fingerprint "$branch_fingerprint" \
                --argjson stable_polls "$branch_stable_polls" \
                --argjson ready "$branch_ready" \
                '. + {($b): {fingerprint: $fingerprint, stable_polls: $stable_polls, ready_to_print: $ready}}')
            branch_index=$((branch_index + 1))
        done

        local wrapper_fingerprint prev_wrapper_fingerprint wrapper_stable_polls ready_to_print
        wrapper_fingerprint=$(jq -cn --arg s "$wrapper_status" --argjson d "${wrapper_duration:-0}" '{status: $s, durationMillis: $d}')
        prev_wrapper_fingerprint=$(echo "$previous_parallel_state" | jq -c --arg w "$wrapper_name" '.[$w].wrapper_fingerprint // {}' 2>/dev/null)
        if [[ -n "$wrapper_fingerprint" && "$wrapper_fingerprint" == "$prev_wrapper_fingerprint" ]]; then
            wrapper_stable_polls=$(echo "$previous_parallel_state" | jq -r --arg w "$wrapper_name" '(.[$w].wrapper_stable_polls // 0) + 1' 2>/dev/null)
        else
            wrapper_stable_polls=1
        fi
        ready_to_print="false"
        if _stage_status_is_terminal "$wrapper_status" \
            && [[ -n "$wrapper_duration" && "$wrapper_duration" != "null" && "$wrapper_duration" =~ ^[0-9]+$ \
                && "$all_terminal" == "true" && "$all_ready" == "true" && "$stable_polls" -ge 2 && "$wrapper_stable_polls" -ge 2 && "$observed_count" -gt 0 ]]; then
            ready_to_print="true"
        fi

        result=$(echo "$result" | jq \
            --arg w "$wrapper_name" \
            --argjson branches "$branch_entries" \
            --argjson observed_count "$observed_count" \
            --argjson stable_polls "$stable_polls" \
            --argjson first_idx "$scan_start" \
            --arg path_prefix "$path_prefix" \
            --argjson branch_state "$branch_state" \
            --argjson wrapper_fingerprint "$wrapper_fingerprint" \
            --argjson wrapper_stable_polls "$wrapper_stable_polls" \
            --argjson ready "$ready_to_print" \
            '. + {
                ($w): {
                    branches: $branches,
                    observed_count: $observed_count,
                    stable_polls: $stable_polls,
                    first_idx: $first_idx,
                    path_prefix: $path_prefix,
                    branch_state: $branch_state,
                    wrapper_fingerprint: $wrapper_fingerprint,
                    wrapper_stable_polls: $wrapper_stable_polls,
                    ready_to_print: $ready
                }
            }')
    done <<< "$wrapper_names"

    echo "$result"
}

_get_parallel_wrapper_for_stage() {
    local parallel_state="$1"
    local stage_name="$2"
    local stage_entry="$3"

    local wrapper_name
    wrapper_name=$(echo "$stage_entry" | jq -r '.parallel_wrapper // empty' 2>/dev/null)
    if [[ -n "$wrapper_name" ]]; then
        echo "$wrapper_name"
        return
    fi

    local is_wrapper
    is_wrapper=$(echo "$stage_entry" | jq -r '.is_parallel_wrapper // false' 2>/dev/null)
    if [[ "$is_wrapper" == "true" ]]; then
        echo "$stage_name"
        return
    fi

    echo "$parallel_state" | jq -r --arg s "$stage_name" '
        to_entries[]
        | select(any(.value.branches[]?; .name == $s))
        | .key
    ' 2>/dev/null | head -1
}

_parallel_branch_ready_to_print() {
    local parallel_state="$1"
    local wrapper_name="$2"
    local branch_name="$3"

    echo "$parallel_state" | jq -r --arg w "$wrapper_name" --arg b "$branch_name" '.[$w].branch_state[$b].ready_to_print // false' 2>/dev/null
}

_parallel_wrapper_ready_to_print() {
    local parallel_state="$1"
    local wrapper_name="$2"

    echo "$parallel_state" | jq -r --arg w "$wrapper_name" '.[$w].ready_to_print // false' 2>/dev/null
}

_parallel_branch_entry_with_path() {
    local parallel_state="$1"
    local wrapper_name="$2"
    local branch_name="$3"

    local branch_entry path_prefix branch_idx branch_path
    branch_entry=$(echo "$parallel_state" | jq -c --arg w "$wrapper_name" --arg b "$branch_name" '.[$w].branches[] | select(.name == $b)' 2>/dev/null | head -1)
    [[ -z "$branch_entry" || "$branch_entry" == "null" ]] && return 1

    branch_path=$(echo "$branch_entry" | jq -r '.parallel_path // empty' 2>/dev/null)
    if [[ -z "$branch_path" ]]; then
        path_prefix=$(echo "$parallel_state" | jq -r --arg w "$wrapper_name" '.[$w].path_prefix // ""' 2>/dev/null)
        branch_idx=$(echo "$parallel_state" | jq -r --arg w "$wrapper_name" --arg b "$branch_name" '
            .[$w].branches
            | to_entries[]
            | select(.value.name == $b)
            | (.key + 1)
        ' 2>/dev/null | head -1)
        if [[ -n "$branch_idx" ]]; then
            if [[ -n "$path_prefix" ]]; then
                branch_path="${path_prefix}.${branch_idx}"
            else
                branch_path="$branch_idx"
            fi
            branch_entry=$(echo "$branch_entry" | jq --arg pp "$branch_path" '. + {parallel_path: $pp, parallel_branch: .name}')
        fi
    fi

    echo "$branch_entry"
}

_parallel_group_name() {
    local stage_entry="$1"

    local wrapper_name is_wrapper stage_name
    wrapper_name=$(echo "$stage_entry" | jq -r '.parallel_wrapper // empty' 2>/dev/null)
    if [[ -n "$wrapper_name" ]]; then
        echo "$wrapper_name"
        return
    fi

    is_wrapper=$(echo "$stage_entry" | jq -r '.is_parallel_wrapper // false' 2>/dev/null)
    if [[ "$is_wrapper" == "true" ]]; then
        stage_name=$(echo "$stage_entry" | jq -r '.name // empty' 2>/dev/null)
        echo "$stage_name"
        return
    fi

    echo ""
}

_stage_blocked_by_unprinted_predecessor() {
    local current_nested="$1"
    local printed_state="$2"
    local current_index="$3"
    local stage_entry="$4"

    local stage_group
    stage_group=$(_parallel_group_name "$stage_entry")

    local prior_index=0
    while [[ $prior_index -lt $current_index ]]; do
        local prior_entry prior_name prior_status prior_printed prior_group
        prior_entry=$(echo "$current_nested" | jq -c ".[$prior_index]")
        prior_name=$(echo "$prior_entry" | jq -r '.name // empty' 2>/dev/null)
        prior_status=$(echo "$prior_entry" | jq -r '.status // empty' 2>/dev/null)

        if ! _stage_status_is_terminal "$prior_status"; then
            prior_index=$((prior_index + 1))
            continue
        fi

        prior_printed=$(echo "$printed_state" | jq -r --arg s "$prior_name" '.[$s].terminal // false' 2>/dev/null)
        if [[ "$prior_printed" == "true" ]]; then
            prior_index=$((prior_index + 1))
            continue
        fi

        prior_group=$(_parallel_group_name "$prior_entry")
        if [[ -n "$stage_group" && -n "$prior_group" && "$stage_group" == "$prior_group" ]]; then
            prior_index=$((prior_index + 1))
            continue
        fi

        return 0
    done

    return 1
}

_nested_tracking_complete() {
    local current_nested="$1"
    local current_parent_stages="$2"
    local printed_state="$3"

    echo "$current_nested" "$current_parent_stages" "$printed_state" | jq -e -n '
        def is_branch_local_substage_leaf($nested; $stage_name):
            any($nested[]?;
                (.parent_branch_stage? != null)
                and ((.name // "") | split("->") | last) == $stage_name
            );
        (input) as $nested
        | (input) as $parent
        | (input) as $printed
        | (
            all($nested[]?;
                if (.status == "SUCCESS" or .status == "FAILED" or .status == "UNSTABLE" or .status == "ABORTED")
                then ($printed[.name].terminal // false)
                else true
                end
            )
          )
        and (
            all($parent[]?;
                if is_branch_local_substage_leaf($nested; .name) then
                    true
                elif (.status == "SUCCESS" or .status == "FAILED" or .status == "UNSTABLE" or .status == "ABORTED")
                then ($printed[.name].terminal // false)
                else true
                end
            )
        )
    ' >/dev/null 2>&1
}

_force_flush_completion_stages() {
    local job_name="$1"
    local build_number="$2"
    local previous_composite_state="${3:-}"

    local printed_state="{}"
    local parallel_state="{}"
    if [[ -n "$previous_composite_state" && "$previous_composite_state" != "null" ]]; then
        printed_state=$(echo "$previous_composite_state" | jq '.printed // {}' 2>/dev/null) || printed_state="{}"
        parallel_state=$(echo "$previous_composite_state" | jq '.parallel_state // {}' 2>/dev/null) || parallel_state="{}"
    fi

    local current_parent_stages current_nested
    current_parent_stages=$(get_all_stages "$job_name" "$build_number" 2>/dev/null) || current_parent_stages="[]"
    current_nested=$(_get_nested_stages "$job_name" "$build_number" 2>/dev/null) || current_nested="[]"
    [[ -z "$current_parent_stages" || "$current_parent_stages" == "null" ]] && current_parent_stages="[]"
    [[ -z "$current_nested" || "$current_nested" == "null" ]] && current_nested="[]"

    local nested_count=0
    nested_count=$(echo "$current_nested" | jq 'length' 2>/dev/null) || nested_count=0
    local i=0
    while [[ $i -lt $nested_count ]]; do
        local stage_entry stage_name stage_status duration_ms printed_terminal
        stage_entry=$(echo "$current_nested" | jq -c ".[$i]")
        stage_name=$(echo "$stage_entry" | jq -r '.name')
        stage_status=$(echo "$stage_entry" | jq -r '.status')
        duration_ms=$(echo "$stage_entry" | jq -r '.durationMillis')
        printed_terminal=$(echo "$printed_state" | jq -r --arg s "$stage_name" '.[$s].terminal // false' 2>/dev/null)
        if _stage_status_is_terminal "$stage_status" \
            && [[ "$printed_terminal" != "true" ]] \
            && [[ -n "$duration_ms" && "$duration_ms" != "null" && "$duration_ms" =~ ^[0-9]+$ ]]; then
            _print_nested_stage_entry "$stage_entry"
            printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
        fi
        i=$((i + 1))
    done

    local parent_count=0
    parent_count=$(echo "$current_parent_stages" | jq 'length' 2>/dev/null) || parent_count=0
    i=0
    while [[ $i -lt $parent_count ]]; do
        local stage_name stage_status duration_ms printed_terminal nested_match branch_local_substage_match
        stage_name=$(echo "$current_parent_stages" | jq -r ".[$i].name")
        stage_status=$(echo "$current_parent_stages" | jq -r ".[$i].status")
        duration_ms=$(echo "$current_parent_stages" | jq -r ".[$i].durationMillis")
        printed_terminal=$(echo "$printed_state" | jq -r --arg s "$stage_name" '.[$s].terminal // false' 2>/dev/null)
        branch_local_substage_match=$(echo "$current_nested" | jq -c --arg n "$stage_name" '
            [.[] | select((.parent_branch_stage? != null) and ((.name // "") | split("->") | last) == $n)][0]
        ' 2>/dev/null | head -1)
        if _stage_status_is_terminal "$stage_status" \
            && [[ -z "$branch_local_substage_match" || "$branch_local_substage_match" == "null" ]] \
            && [[ "$printed_terminal" != "true" ]] \
            && [[ -n "$duration_ms" && "$duration_ms" != "null" && "$duration_ms" =~ ^[0-9]+$ ]]; then
            nested_match=$(echo "$current_nested" | jq -c --arg n "$stage_name" '.[] | select(.name == $n)' 2>/dev/null | head -1)
            if [[ -n "$nested_match" && "$nested_match" != "null" ]]; then
                _print_nested_stage_entry "$nested_match"
            else
                print_stage_line "$stage_name" "$stage_status" "$duration_ms"
            fi
            printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
        fi
        i=$((i + 1))
    done

    local tracking_complete=false
    if _nested_tracking_complete "$current_nested" "$current_parent_stages" "$printed_state"; then
        tracking_complete=true
    fi

    jq -n \
        --argjson parent "$current_parent_stages" \
        --argjson downstream "{}" \
        --argjson stage_downstream_map "{}" \
        --argjson parallel_info "{}" \
        --argjson nested "$current_nested" \
        --argjson printed "$printed_state" \
        --argjson parallel_state "$parallel_state" \
        --argjson tracking_complete "$tracking_complete" \
        '{parent: $parent, downstream: $downstream, stage_downstream_map: $stage_downstream_map, parallel_info: $parallel_info, nested: $nested, printed: $printed, parallel_state: $parallel_state, tracking_complete: $tracking_complete}'
}

# Track nested stage changes for monitoring mode
# Wraps track_stage_changes() to also track downstream build stages
# Usage: new_state=$(_track_nested_stage_changes "job-name" "build-number" "$previous_composite_state" "$verbose")
# Returns: Composite state JSON on stdout (capture for next iteration)
# Side effect: Prints completed/running stage lines to stderr (with nesting)
# Spec: nested-jobs-display-spec.md, Section: Monitoring Mode Behavior
# Spec: bug-parallel-stages-display-spec.md, Section: Stage Tracker Changes
_track_nested_stage_changes() {
    local job_name="$1"
    local build_number="$2"
    local previous_composite_state="${3:-}"
    local verbose="${4:-false}"

    local previous_nested="[]"
    local printed_state="{}"
    local previous_parallel_state="{}"
    local prev_type=""
    if [[ -n "$previous_composite_state" && "$previous_composite_state" != "[]" && "$previous_composite_state" != "null" ]]; then
        prev_type=$(echo "$previous_composite_state" | jq -r 'type' 2>/dev/null) || prev_type=""
        if [[ "$prev_type" == "object" ]]; then
            previous_nested=$(echo "$previous_composite_state" | jq '.nested // []')
            printed_state=$(echo "$previous_composite_state" | jq '.printed // {}')
            previous_parallel_state=$(echo "$previous_composite_state" | jq '.parallel_state // {}')
        elif [[ "$prev_type" == "array" ]]; then
            # Backward compatibility: banner snapshot used a flat stage array.
            previous_nested="$previous_composite_state"
        fi
    fi

    # Seed printed-state from previously seen statuses so completed stages that
    # were already shown in the banner are not re-printed during the first poll.
    # Only seed from flat arrays (banner transition); composite objects already
    # carry an accurate .printed state that respects deferral decisions.
    if [[ "$prev_type" != "object" && -n "$previous_nested" && "$previous_nested" != "[]" ]]; then
        local seeded_printed="{}"
        seeded_printed=$(echo "$previous_nested" | jq '
            reduce .[] as $s ({};
                if ($s.status == "SUCCESS" or $s.status == "FAILED" or $s.status == "UNSTABLE" or $s.status == "ABORTED") then
                    . + {($s.name): ((.[$s.name] // {}) + {terminal: true})}
                elif ($s.status == "IN_PROGRESS") then
                    . + {($s.name): ((.[$s.name] // {}) + {running: true})}
                else
                    .
                end
            )' 2>/dev/null) || seeded_printed="{}"
        printed_state=$(echo "$seeded_printed" "$printed_state" | jq -s '.[0] * .[1]' 2>/dev/null) || printed_state="$seeded_printed"
    fi

    local current_parent_stages
    current_parent_stages=$(get_all_stages "$job_name" "$build_number" 2>/dev/null) || current_parent_stages="[]"

    local current_nested
    current_nested=$(_get_nested_stages "$job_name" "$build_number" 2>/dev/null) || current_nested="[]"
    if [[ -z "$current_nested" || "$current_nested" == "null" ]]; then
        current_nested="[]"
    fi

    local parallel_state
    parallel_state=$(_build_parallel_tracking_state "$current_nested" "$previous_parallel_state")
    [[ -z "$parallel_state" || "$parallel_state" == "null" ]] && parallel_state="{}"

    local stage_count
    stage_count=$(echo "$current_nested" | jq 'length' 2>/dev/null) || stage_count=0
    local i=0
    while [[ $i -lt $stage_count ]]; do
        local stage_entry stage_name current_status duration_ms
        stage_entry=$(echo "$current_nested" | jq -c ".[$i]")
        stage_name=$(echo "$stage_entry" | jq -r '.name')
        current_status=$(echo "$stage_entry" | jq -r '.status')
        duration_ms=$(echo "$stage_entry" | jq -r '.durationMillis')

        local previous_status
        previous_status=$(echo "$previous_nested" | jq -r --arg n "$stage_name" '.[] | select(.name == $n) | .status // "NOT_EXECUTED"' 2>/dev/null)
        [[ -z "$previous_status" ]] && previous_status="NOT_EXECUTED"

        local printed_terminal printed_running
        printed_terminal=$(echo "$printed_state" | jq -r --arg s "$stage_name" '.[$s].terminal // false' 2>/dev/null)
        printed_running=$(echo "$printed_state" | jq -r --arg s "$stage_name" '.[$s].running // false' 2>/dev/null)
        [[ -z "$printed_terminal" ]] && printed_terminal="false"
        [[ -z "$printed_running" ]] && printed_running="false"

        case "$current_status" in
            SUCCESS|FAILED|UNSTABLE|ABORTED)
                if [[ "$printed_terminal" != "true" ]]; then
                    if _stage_blocked_by_unprinted_predecessor "$current_nested" "$printed_state" "$i" "$stage_entry"; then
                        i=$((i + 1))
                        continue
                    fi

                    local parallel_wrapper
                    parallel_wrapper=$(_get_parallel_wrapper_for_stage "$parallel_state" "$stage_name" "$stage_entry")
                    if [[ -n "$parallel_wrapper" ]]; then
                        local is_wrapper ready_branch ready_wrapper resolved_branch_entry
                        is_wrapper=$(echo "$stage_entry" | jq -r '.is_parallel_wrapper // false' 2>/dev/null)
                        if [[ "$is_wrapper" == "true" ]]; then
                            ready_wrapper=$(_parallel_wrapper_ready_to_print "$parallel_state" "$parallel_wrapper")
                            if [[ "$ready_wrapper" == "true" ]]; then
                                _print_nested_stage_entry "$stage_entry"
                                printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
                            fi
                        else
                            ready_branch=$(_parallel_branch_ready_to_print "$parallel_state" "$parallel_wrapper" "$stage_name")
                            if [[ "$ready_branch" == "true" ]]; then
                                resolved_branch_entry=$(_parallel_branch_entry_with_path "$parallel_state" "$parallel_wrapper" "$stage_name") || resolved_branch_entry="$stage_entry"
                                _print_nested_stage_entry "$resolved_branch_entry"
                                printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
                            fi
                        fi
                        i=$((i + 1))
                        continue
                    fi

                    local allow_print=true
                    if [[ "$verbose" != "true" ]]; then
                        if [[ -z "$duration_ms" || "$duration_ms" == "null" || ! "$duration_ms" =~ ^[0-9]+$ ]]; then
                            allow_print=false
                        fi
                    fi
                    local has_ds
                    has_ds=$(echo "$stage_entry" | jq -r '.has_downstream // false')
                    if [[ "$allow_print" == "true" && "$has_ds" == "true" ]]; then
                        local ds_child_count
                        ds_child_count=$(echo "$current_nested" | jq --arg pfx "${stage_name}->" '[.[] | select(.name | startswith($pfx))] | length')
                        if [[ "$ds_child_count" -eq 0 ]]; then
                            allow_print=false
                        fi
                    fi
                    if [[ "$allow_print" == "true" ]]; then
                        _print_nested_stage_entry "$stage_entry"
                        printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
                    fi
                fi
                ;;
            IN_PROGRESS)
                if [[ "$verbose" == "true" && "$printed_running" != "true" && "$previous_status" == "NOT_EXECUTED" ]]; then
                    _print_nested_stage_entry "$stage_entry"
                    printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {running: true})')
                fi
                ;;
        esac

        i=$((i + 1))
    done

    local tracking_complete=false
    if _nested_tracking_complete "$current_nested" "$current_parent_stages" "$printed_state"; then
        tracking_complete=true
    fi

    # Return composite state with legacy keys retained for test/backward compatibility
    jq -n \
        --argjson parent "$current_parent_stages" \
        --argjson downstream "{}" \
        --argjson stage_downstream_map "{}" \
        --argjson parallel_info "{}" \
        --argjson nested "$current_nested" \
        --argjson printed "$printed_state" \
        --argjson parallel_state "$parallel_state" \
        --argjson tracking_complete "$tracking_complete" \
        '{parent: $parent, downstream: $downstream, stage_downstream_map: $stage_downstream_map, parallel_info: $parallel_info, nested: $nested, printed: $printed, parallel_state: $parallel_state, tracking_complete: $tracking_complete}'
}

# Format epoch timestamp (milliseconds) to human-readable date
# Usage: format_timestamp 1705329125000
# Returns: "2024-01-15 14:32:05"
