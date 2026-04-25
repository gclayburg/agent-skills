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
    # NB: "${2:-{}}" expands to "{}}" (extra brace) when $2 is non-empty due to
    # how bash parses braces inside default-value expansions. Use explicit fall-
    # through to get the intended behavior.
    local previous_parallel_state="$2"
    [[ -z "$previous_parallel_state" ]] && previous_parallel_state="{}"
    local build_info_json current_building="true"
    build_info_json=$(get_build_info "$job_name" "$build_number" 2>/dev/null) || true
    if [[ -n "$build_info_json" ]]; then
        current_building=$(echo "$build_info_json" | jq -r 'if has("building") and .building != null then .building else true end' 2>/dev/null)
        [[ -z "$current_building" || "$current_building" == "null" ]] && current_building="true"
    fi

    # Perf: the whole parallel-state transition is computed in a single jq
    # program instead of forking ~10-15 jq calls per wrapper × per branch
    # every poll iteration. Behavior mirrors the prior implementation exactly
    # (same structure, same stable-poll semantics, same ready_to_print logic).
    [[ -z "$current_nested" || "$current_nested" == "null" ]] && current_nested="[]"
    [[ "$previous_parallel_state" == "null" ]] && previous_parallel_state="{}"

    jq -n \
        --argjson nested "$current_nested" \
        --argjson prev "$previous_parallel_state" \
        --arg building "$current_building" '
        def is_terminal($s):
            $s == "SUCCESS" or $s == "FAILED" or $s == "UNSTABLE" or $s == "ABORTED";
        def is_nonneg_int(v):
            (v | type) == "number" and v >= 0;
        def drop_last_seg(p):
            if p == "" then ""
            elif (p | contains(".")) then (p | sub("\\.[^.]+$"; ""))
            else "" end;
        def last_seg(n):
            ((n // "") | split("->") | last);
        def matches_declared_branch($name; $declared; $wprefix):
            any($declared[]?; . == $name or ($wprefix != "" and ($wprefix + .) == $name));
        def is_direct_branch_for_wrapper($stage; $wname; $declared; $wprefix):
            (($stage.is_parallel_wrapper // false) != true)
            and (
                (($stage.parallel_wrapper // "") == $wname)
                or matches_declared_branch(($stage.name // ""); $declared; $wprefix)
            )
            and (
                ((($stage.parallel_branch // "") != "")
                 and (last_seg($stage.name // "") == ($stage.parallel_branch // "")))
                or matches_declared_branch(($stage.name // ""); $declared; $wprefix)
            );

        ($nested // []) as $nested
        | ($prev // {}) as $prev
        | ($nested | to_entries | map(select(.value.is_parallel_wrapper == true))) as $wrappers
        | reduce $wrappers[] as $we ({__buildgit_building: $building};
            . as $acc
            | $we.value.name as $wname
            | $we.key as $wrapper_idx
            | ($we.value.nesting_depth // 0) as $wrapper_depth
            | ($we.value.parallel_branches // []) as $declared
            # When the wrapper itself has a prefix (a nested parallel
            # wrapper, e.g. "Build SignalBoot->Publish and Archive"), the
            # assembled branches under it carry the same prefix on their
            # name (e.g. "Build SignalBoot->Docker Push") but the original
            # parallel_wrapper field still holds the bare local name
            # ("Publish and Archive"). Match these prefixed branches by
            # composing prefix + "->" + declared_name.
            | ((($wname | split("->")) as $segs
                | if ($segs | length) > 1
                  then (($segs[0:-1]) | join("->")) + "->"
                  else "" end)) as $wprefix
            | ([ $nested | to_entries[] as $e
                 | select(is_direct_branch_for_wrapper($e.value; $wname; $declared; $wprefix))
                 | { idx: $e.key,
                     name: $e.value.name,
                     path: ($e.value.parallel_path // ""),
                     depth: ($e.value.nesting_depth // 0) } ]
               | sort_by(.idx)) as $known
            | (if ($known | length) > 0 then ($known[0].depth // $wrapper_depth)
               else $wrapper_depth end) as $branch_depth
            | (if ($known | length) > 0 then $known[0].idx else null end) as $first_known_idx
            | (($prev[$wname].first_idx // null)) as $prev_first_idx
            | (if $first_known_idx != null then $first_known_idx
               elif $prev_first_idx != null then $prev_first_idx
               else null end) as $scan_start
            | if $scan_start == null then $acc
              else
                ([ $nested | to_entries[]
                   | select(.key >= $scan_start and .key < $wrapper_idx)
                   | (.value + { __idx: .key })
                   | select(((.nesting_depth // 0) == $branch_depth)
                            and is_direct_branch_for_wrapper(.; $wname; $declared; $wprefix)) ]) as $branch_entries
                | ($branch_entries | length) as $observed_count
                | (($prev[$wname].observed_count // -1)) as $prev_observed_count
                | (if $prev_observed_count == $observed_count
                   then ($prev[$wname].stable_polls // 0) + 1
                   else 1 end) as $stable_polls
                | (if ($known | length) == 0 then ""
                   else drop_last_seg($known[0].path // "") end) as $path_prefix
                | ($we.value.status // "") as $wstatus
                | ($we.value.durationMillis // null) as $wdur
                | is_terminal($wstatus) as $wrapper_terminal
                | (reduce ($branch_entries[]) as $be (
                    { state: {}, all_terminal: true, all_ready: true };
                    .state as $bs
                    | $be.name as $bname
                    | ($be.status // "") as $bstatus
                    | ($be.durationMillis // null) as $bdur
                    | ({ status: $bstatus, durationMillis: $bdur }) as $bfp
                    | (($prev[$wname].branch_state[$bname].fingerprint // {})) as $prev_bfp
                    | (($prev[$wname].branch_state[$bname].fingerprint.status // null)) as $prev_bstatus
                    | (if $bfp == $prev_bfp
                       then ($prev[$wname].branch_state[$bname].stable_polls // 0) + 1
                       else 1 end) as $bstable
                    | (($prev_bstatus != null)
                       and ((is_terminal($prev_bstatus)) | not)
                       and is_terminal($bstatus)) as $terminal_transition
                    | (is_terminal($bstatus)
                       and is_nonneg_int($bdur)
                       and ($bdur >= 1000 or $building == "false")
                       and (($terminal_transition and ($wrapper_terminal | not))
                            or $bstable >= 2)) as $bready
                    | .state = ($bs + { ($bname): { fingerprint: $bfp, stable_polls: $bstable, ready_to_print: $bready } })
                    | if (is_terminal($bstatus) | not)
                        then .all_terminal = false | .all_ready = false
                      elif ($bready | not) then .all_ready = false
                      else . end
                  )) as $scan
                | $scan.state as $branch_state
                | $scan.all_terminal as $all_terminal
                | $scan.all_ready as $all_ready
                | ({ status: $wstatus, durationMillis: $wdur }) as $wfp
                | (($prev[$wname].wrapper_fingerprint // {})) as $prev_wfp
                | (if $wfp == $prev_wfp
                   then ($prev[$wname].wrapper_stable_polls // 0) + 1
                   else 1 end) as $wrapper_stable_polls
                | (is_terminal($wstatus)
                   and is_nonneg_int($wdur)
                   and $all_terminal and $all_ready
                   and $stable_polls >= 2
                   and $wrapper_stable_polls >= 2
                   and $observed_count > 0) as $ready_to_print
                | $acc + { ($wname): {
                    branches: $branch_entries,
                    observed_count: $observed_count,
                    stable_polls: $stable_polls,
                    first_idx: $scan_start,
                    path_prefix: $path_prefix,
                    branch_state: $branch_state,
                    wrapper_fingerprint: $wfp,
                    wrapper_stable_polls: $wrapper_stable_polls,
                    ready_to_print: $ready_to_print
                  } }
              end
          )
    '
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

_parallel_wrapper_branches_printed_fast() {
    local stage_entry="$1"

    local branches
    branches=$(echo "$stage_entry" | jq -r '.parallel_branches[]? // empty' 2>/dev/null) || branches=""
    if [[ -z "$branches" ]]; then
        return 1
    fi

    local branch_name found branch_idx
    while IFS= read -r branch_name; do
        [[ -z "$branch_name" ]] && continue
        found=false
        branch_idx=0
        while [[ $branch_idx -lt ${#_ts_names[@]} ]]; do
            if [[ "${_ts_names[$branch_idx]}" == "$branch_name" && "${_ts_printed_terminal[$branch_idx]}" == "true" ]]; then
                found=true
                break
            fi
            branch_idx=$((branch_idx + 1))
        done
        if [[ "$found" != "true" ]]; then
            return 1
        fi
    done <<< "$branches"

    return 0
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

# Fast variant — pure-bash predicate that reads the aligned per-stage arrays
# precomputed by _track_nested_stage_changes. Avoids the O(N^2) × ~7 jq forks
# the legacy variant costs on monorepo builds.
# Inputs (globals, set by the tracker before calling):
#   _ts_is_terminal_status, _ts_printed_terminal, _ts_group
# Arguments: current_index
# Returns 0 if a prior non-same-group terminal stage is still unprinted.
_stage_blocked_by_unprinted_predecessor_fast() {
    local current_index="$1"
    local stage_group="${_ts_group[$current_index]}"
    local prior=0
    while [[ $prior -lt $current_index ]]; do
        if [[ "${_ts_is_terminal_status[$prior]}" == "1" && "${_ts_printed_terminal[$prior]}" != "true" ]]; then
            if [[ "${_ts_is_direct_branch[$prior]:-false}" == "true" ]]; then
                local prior_name="${_ts_names[$prior]}"
                local prior_prefix="${prior_name}->"
                local child_name child_count=0
                for child_name in "${_ts_names[@]}"; do
                    case "$child_name" in
                        "${prior_prefix}"*) child_count=$((child_count + 1)) ;;
                    esac
                done
                if [[ "$child_count" -gt 0 ]]; then
                    prior=$((prior + 1))
                    continue
                fi
            fi
            local prior_group="${_ts_group[$prior]}"
            if [[ -z "$stage_group" || -z "$prior_group" || "$stage_group" != "$prior_group" ]]; then
                return 0
            fi
        fi
        prior=$((prior + 1))
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

    # Perf: batch-extract per-stage fields up front; avoids 4+ jq forks per
    # stage in the flush loops (called repeatedly during settle).
    local -a _ff_names=() _ff_status=() _ff_duration=() _ff_entry=()
    local _ff_n _ff_s _ff_d _ff_e
    while IFS=$'\t' read -r _ff_n _ff_s _ff_d _ff_e; do
        [[ -z "$_ff_n" ]] && continue
        _ff_names+=("$_ff_n")
        _ff_status+=("$_ff_s")
        _ff_duration+=("$_ff_d")
        _ff_entry+=("$_ff_e")
    done < <(echo "$current_nested" | jq -r '.[]? | [.name, .status, (.durationMillis|tostring), tojson] | @tsv' 2>/dev/null)

    # Printed-state snapshot (read-only cache; updates mutate the JSON).
    local -a _ffp_names=() _ffp_terminal=()
    local _ffp_n _ffp_t
    while IFS=$'\t' read -r _ffp_n _ffp_t; do
        [[ -z "$_ffp_n" ]] && continue
        _ffp_names+=("$_ffp_n")
        _ffp_terminal+=("$_ffp_t")
    done < <(echo "$printed_state" | jq -r 'to_entries[]? | [.key, (.value.terminal // false|tostring)] | @tsv' 2>/dev/null)

    local nested_count=${#_ff_names[@]}
    local i=0
    while [[ $i -lt $nested_count ]]; do
        local stage_entry stage_name stage_status duration_ms printed_terminal
        stage_name="${_ff_names[$i]}"
        stage_status="${_ff_status[$i]}"
        duration_ms="${_ff_duration[$i]}"
        stage_entry="${_ff_entry[$i]}"
        printed_terminal="false"
        local _k=0
        while [[ $_k -lt ${#_ffp_names[@]} ]]; do
            if [[ "${_ffp_names[$_k]}" == "$stage_name" ]]; then
                printed_terminal="${_ffp_terminal[$_k]}"
                break
            fi
            _k=$((_k + 1))
        done
        if _stage_status_is_terminal "$stage_status" \
            && [[ "$printed_terminal" != "true" ]] \
            && [[ -n "$duration_ms" && "$duration_ms" != "null" && "$duration_ms" =~ ^[0-9]+$ ]]; then
            _print_nested_stage_entry "$stage_entry"
            printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
            _ffp_names+=("$stage_name")
            _ffp_terminal+=("true")
        fi
        i=$((i + 1))
    done

    # Parent-stages batch extraction.
    local -a _fp_names=() _fp_status=() _fp_duration=()
    local _fp_n _fp_s _fp_d
    while IFS=$'\t' read -r _fp_n _fp_s _fp_d; do
        [[ -z "$_fp_n" ]] && continue
        _fp_names+=("$_fp_n")
        _fp_status+=("$_fp_s")
        _fp_duration+=("$_fp_d")
    done < <(echo "$current_parent_stages" | jq -r '.[]? | [.name, .status, (.durationMillis|tostring)] | @tsv' 2>/dev/null)

    local parent_count=${#_fp_names[@]}
    i=0
    while [[ $i -lt $parent_count ]]; do
        local stage_name stage_status duration_ms printed_terminal nested_match branch_local_substage_match
        stage_name="${_fp_names[$i]}"
        stage_status="${_fp_status[$i]}"
        duration_ms="${_fp_duration[$i]}"
        printed_terminal="false"
        local _k=0
        while [[ $_k -lt ${#_ffp_names[@]} ]]; do
            if [[ "${_ffp_names[$_k]}" == "$stage_name" ]]; then
                printed_terminal="${_ffp_terminal[$_k]}"
                break
            fi
            _k=$((_k + 1))
        done
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

    local _ts_dbg_t0 _ts_dbg_t1 _ts_dbg_t2 _ts_dbg_t3 _ts_dbg_t3b _ts_dbg_t4
    [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]] && _ts_dbg_t0=$(perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000')

    local current_parent_stages
    current_parent_stages=$(get_all_stages "$job_name" "$build_number" 2>/dev/null) || current_parent_stages="[]"
    [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]] && _ts_dbg_t1=$(perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000')

    local current_nested
    current_nested=$(_get_nested_stages "$job_name" "$build_number" 2>/dev/null) || current_nested="[]"
    if [[ -z "$current_nested" || "$current_nested" == "null" ]]; then
        current_nested="[]"
    fi
    [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]] && _ts_dbg_t2=$(perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000')

    local parallel_state
    parallel_state=$(_build_parallel_tracking_state "$current_nested" "$previous_parallel_state")
    [[ -z "$parallel_state" || "$parallel_state" == "null" ]] && parallel_state="{}"
    [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]] && _ts_dbg_t3=$(perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000')

    # Perf: batch-extract per-stage fields + per-stage lookups against
    # previous_nested and printed_state in a single jq pass. All loop-body
    # state for stage i lives at index i in parallel bash arrays — the tracker
    # loop forks zero jqs per stage for the read path, and only forks when a
    # mutating write happens (rare, bounded by the number of emitted prints).
    # Separator is ASCII Unit Separator (\x1f, non-whitespace) so empty fields
    # between delimiters are preserved by bash read. Using \t would collapse
    # adjacent tabs because tab is IFS-whitespace.
    local _ts_sep=$'\x1f'
    local -a _ts_names=() _ts_status=() _ts_duration=() _ts_entry=()
    local -a _ts_parallel_wrapper=() _ts_is_parallel_wrapper=()
    local -a _ts_is_terminal_status=() _ts_has_downstream=() _ts_group=()
    local -a _ts_previous_status=() _ts_printed_terminal=() _ts_printed_running=()
    local -a _ts_is_direct_branch=()
    local _ts_n _ts_s _ts_d _ts_pw _ts_ipw _ts_term _ts_hd _ts_g _ts_prev _ts_pt _ts_pr _ts_db _ts_e
    while IFS="$_ts_sep" read -r _ts_n _ts_s _ts_d _ts_pw _ts_ipw _ts_term _ts_hd _ts_g _ts_prev _ts_pt _ts_pr _ts_db _ts_e; do
        [[ -z "$_ts_n" ]] && continue
        _ts_names+=("$_ts_n")
        _ts_status+=("$_ts_s")
        _ts_duration+=("$_ts_d")
        _ts_parallel_wrapper+=("$_ts_pw")
        _ts_is_parallel_wrapper+=("$_ts_ipw")
        _ts_is_terminal_status+=("$_ts_term")
        _ts_has_downstream+=("$_ts_hd")
        _ts_group+=("$_ts_g")
        _ts_previous_status+=("$_ts_prev")
        _ts_printed_terminal+=("$_ts_pt")
        _ts_printed_running+=("$_ts_pr")
        _ts_is_direct_branch+=("$_ts_db")
        _ts_entry+=("$_ts_e")
    done < <(echo "$current_nested" | jq -r \
        --argjson prev "$previous_nested" \
        --argjson printed "$printed_state" \
        --arg sep $'\x1f' '
        (($prev // []) | map({(.name): (.status // "NOT_EXECUTED")}) | add // {}) as $prev_map |
        .[] | . as $s | [
            ($s.name // ""),
            ($s.status // ""),
            (($s.durationMillis // "") | tostring),
            ($s.parallel_wrapper // ""),
            (if ($s.is_parallel_wrapper // false) == true then "true" else "false" end),
            (if ($s.status == "SUCCESS" or $s.status == "FAILED" or $s.status == "UNSTABLE" or $s.status == "ABORTED") then "1" else "0" end),
            (($s.has_downstream // false) | tostring),
            (if ($s.parallel_wrapper // "") != "" then $s.parallel_wrapper
             elif ($s.is_parallel_wrapper // false) == true then ($s.name // "")
             else "" end),
            ($prev_map[$s.name // ""] // "NOT_EXECUTED"),
            (($printed[$s.name // ""].terminal // false) | tostring),
            (($printed[$s.name // ""].running // false) | tostring),
            # is_direct_branch: stage is a direct parallel branch (versus
            # a sub-stage that inherited parallel_wrapper from its parent).
            # The computed parallel_state branch list can include expanded
            # downstream child stages because they share the parent branch
            # depth in the assembled nested list. The explicit parallel_branch
            # identity from _get_nested_stages is the reliable signal here.
            (if ($s.parallel_wrapper // "") != ""
                and (($s.parallel_branch // "") != ""
                     and (($s.parallel_branch // "")
                          == (($s.name // "") | split("->") | last)))
             then "true" else "false" end),
            ($s | tojson)
        ] | join($sep)
    ' 2>/dev/null)

    [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]] && _ts_dbg_t3b=$(perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000')

    local stage_count=${#_ts_names[@]}
    # Diagnostic counters (emitted under BUILDGIT_DEBUG_TIMING) so we can tell
    # whether stages are held back by blocking predecessors, unready parallel
    # wrappers, or unready parallel branches — the three reasons a completed
    # stage can go unprinted during the main loop.
    local _dbg_printed_this_iter=0
    local _dbg_blocked_predecessor=0
    local _dbg_wrapper_not_ready=0
    local _dbg_branch_not_ready=0
    local _dbg_allow_print_false=0
    local _dbg_terminal_already_printed=0
    local _dbg_terminal_waiting=0
    local i=0
    while [[ $i -lt $stage_count ]]; do
        local stage_entry stage_name current_status duration_ms
        local previous_status printed_terminal printed_running
        stage_name="${_ts_names[$i]}"
        current_status="${_ts_status[$i]}"
        duration_ms="${_ts_duration[$i]}"
        stage_entry="${_ts_entry[$i]}"
        previous_status="${_ts_previous_status[$i]}"
        printed_terminal="${_ts_printed_terminal[$i]}"
        printed_running="${_ts_printed_running[$i]}"

        case "$current_status" in
            SUCCESS|FAILED|UNSTABLE|ABORTED)
                if [[ "$printed_terminal" != "true" ]]; then
                    _dbg_terminal_waiting=$((_dbg_terminal_waiting + 1))
                    if _stage_blocked_by_unprinted_predecessor_fast "$i"; then
                        _dbg_blocked_predecessor=$((_dbg_blocked_predecessor + 1))
                        i=$((i + 1))
                        continue
                    fi

                    local parallel_wrapper=""
                    if [[ "${_ts_is_parallel_wrapper[$i]}" == "true" ]]; then
                        parallel_wrapper="$stage_name"
                    elif [[ "${_ts_is_direct_branch[$i]}" == "true" ]]; then
                        # Inherited parallel_wrapper is only meaningful when
                        # this stage is an actual direct branch in the
                        # wrapper's branch_state map. Sub-stages that only
                        # inherited the wrapper field from an outer parent
                        # must NOT enter the parallel-readiness gate — they
                        # would never satisfy it (they're not in branch_state)
                        # and would sit unprinted until the final flush.
                        parallel_wrapper="${_ts_parallel_wrapper[$i]}"
                    fi
                    if [[ -n "$parallel_wrapper" ]]; then
                        local is_wrapper="${_ts_is_parallel_wrapper[$i]}"
                        local ready_branch ready_wrapper resolved_branch_entry
                        if [[ "$is_wrapper" == "true" ]]; then
                            ready_wrapper=$(_parallel_wrapper_ready_to_print "$parallel_state" "$parallel_wrapper")
                            if [[ "$ready_wrapper" == "true" ]] || _parallel_wrapper_branches_printed_fast "$stage_entry"; then
                                _print_nested_stage_entry "$stage_entry"
                                printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
                                _ts_printed_terminal[$i]="true"
                                _dbg_printed_this_iter=$((_dbg_printed_this_iter + 1))
                            else
                                _dbg_wrapper_not_ready=$((_dbg_wrapper_not_ready + 1))
                            fi
                        else
                            ready_branch=$(_parallel_branch_ready_to_print "$parallel_state" "$parallel_wrapper" "$stage_name")
                            local branch_duration_ready=false
                            if [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
                                local branch_child_count=0 _branch_child _branch_prefix
                                _branch_prefix="${stage_name}->"
                                for _branch_child in "${_ts_names[@]}"; do
                                    case "$_branch_child" in
                                        "${_branch_prefix}"*) branch_child_count=$((branch_child_count + 1)) ;;
                                    esac
                                done
                                if [[ "$duration_ms" -ge 1000 && "$branch_child_count" -eq 0 ]]; then
                                    branch_duration_ready=true
                                fi
                            fi
                            if [[ "$ready_branch" == "true" || "$branch_duration_ready" == "true" ]]; then
                                resolved_branch_entry=$(_parallel_branch_entry_with_path "$parallel_state" "$parallel_wrapper" "$stage_name") || resolved_branch_entry="$stage_entry"
                                _print_nested_stage_entry "$resolved_branch_entry"
                                printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
                                _ts_printed_terminal[$i]="true"
                                _dbg_printed_this_iter=$((_dbg_printed_this_iter + 1))
                            else
                                _dbg_branch_not_ready=$((_dbg_branch_not_ready + 1))
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
                    if [[ "$allow_print" == "true" && "${_ts_has_downstream[$i]}" == "true" ]]; then
                        local ds_child_count=0 _cn _pfx
                        _pfx="${stage_name}->"
                        for _cn in "${_ts_names[@]}"; do
                            case "$_cn" in
                                "${_pfx}"*) ds_child_count=$((ds_child_count + 1)) ;;
                            esac
                        done
                        if [[ "$ds_child_count" -eq 0 ]]; then
                            allow_print=false
                        fi
                    fi
                    if [[ "$allow_print" == "true" ]]; then
                        _print_nested_stage_entry "$stage_entry"
                        printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {terminal: true})')
                        _ts_printed_terminal[$i]="true"
                        _dbg_printed_this_iter=$((_dbg_printed_this_iter + 1))
                    else
                        _dbg_allow_print_false=$((_dbg_allow_print_false + 1))
                    fi
                else
                    _dbg_terminal_already_printed=$((_dbg_terminal_already_printed + 1))
                fi
                ;;
            IN_PROGRESS)
                if [[ "$verbose" == "true" && "$printed_running" != "true" && "$previous_status" == "NOT_EXECUTED" ]]; then
                    _print_nested_stage_entry "$stage_entry"
                    printed_state=$(echo "$printed_state" | jq --arg s "$stage_name" '.[$s] = ((.[$s] // {}) + {running: true})')
                    _ts_printed_running[$i]="true"
                fi
                ;;
        esac

        i=$((i + 1))
    done
    [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]] && _ts_dbg_t4=$(perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000')

    local tracking_complete=false
    if _nested_tracking_complete "$current_nested" "$current_parent_stages" "$printed_state"; then
        tracking_complete=true
    fi

    if [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]]; then
        printf '[buildgit-timing-detail] parent=%d nested=%d parallel=%d prologue=%d body=%d stages=%d\n' \
            $((_ts_dbg_t1 - _ts_dbg_t0)) \
            $((_ts_dbg_t2 - _ts_dbg_t1)) \
            $((_ts_dbg_t3 - _ts_dbg_t2)) \
            $((_ts_dbg_t3b - _ts_dbg_t3)) \
            $((_ts_dbg_t4 - _ts_dbg_t3b)) \
            "$stage_count" >&2
        printf '[buildgit-print] printed=%d terminal_waiting=%d blocked_predecessor=%d wrapper_not_ready=%d branch_not_ready=%d allow_print_false=%d already_printed=%d tracking_complete=%s\n' \
            "$_dbg_printed_this_iter" "$_dbg_terminal_waiting" "$_dbg_blocked_predecessor" \
            "$_dbg_wrapper_not_ready" "$_dbg_branch_not_ready" "$_dbg_allow_print_false" \
            "$_dbg_terminal_already_printed" "$tracking_complete" >&2
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
