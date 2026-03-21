# Fast one-line status output for snapshot mode.
# Arguments: job_name [start_build_number] [line_count]
# Returns: exit code based only on the last printed line (newest build).
_status_line_check() {
    local job_name="$1"
    local start_build_number="${2:-}"
    local line_count="${3:-1}"
    local no_tests="${4:-false}"
    local prior_jobs_count="${5:-0}"
    local first_build_number="$start_build_number"

    if [[ -z "$first_build_number" ]]; then
        first_build_number=$(get_last_build_number "$job_name")
        if [[ "$first_build_number" == "0" || -z "$first_build_number" ]]; then
            echo "Error: No builds found for job '${job_name}'" >&2
            return 1
        fi
    fi

    # Collect build numbers to print (newest to oldest), capping at available builds.
    local build_numbers=()
    local i=0
    while [[ "$i" -lt "$line_count" ]]; do
        local current_build_number=$((first_build_number - i))
        if [[ "$current_build_number" -lt 1 ]]; then
            break
        fi
        build_numbers+=("$current_build_number")
        i=$((i + 1))
    done

    # Validate that at least the newest build can be fetched.
    if [[ "${#build_numbers[@]}" -eq 0 ]]; then
        echo "Error: No builds found for job '${job_name}'" >&2
        return 1
    fi

    # Print in reverse order: oldest first, newest last.
    # build_numbers[0] = newest, build_numbers[N-1] = oldest.
    # Loop j from N-1 down to 0 to print oldest→newest.
    local last_exit_code=1
    local total="${#build_numbers[@]}"
    local j="$total"
    while [[ "$j" -gt 0 ]]; do
        j=$((j - 1))
        local bn="${build_numbers[$j]}"

        if [[ "$j" -eq 0 && "$prior_jobs_count" -gt 0 ]]; then
            local max_prior_build=$((bn - 1))
            _display_prior_jobs_block "$job_name" "$prior_jobs_count" "$no_tests" "$max_prior_build"
        fi

        local build_json
        build_json=$(get_build_info "$job_name" "$bn")
        if [[ -z "$build_json" ]]; then
            if [[ "$j" -eq 0 ]]; then
                # Newest build failed to fetch — hard error
                echo "Error: Failed to fetch build information" >&2
                return 1
            fi
            # Older build not available; skip silently
            continue
        fi

        local line_exit=1
        if _status_line_for_build_json "$job_name" "$bn" "$build_json" "$no_tests"; then
            line_exit=0
        fi
        # j==0 is the newest build (last printed line); its exit code is the return value.
        if [[ "$j" -eq 0 ]]; then
            last_exit_code="$line_exit"
        fi
    done

    return "$last_exit_code"
}

# Resolve status build reference to an absolute build number.
# Arguments: job_name, raw_build_ref
# Outputs: resolved absolute build number, or empty string for "latest"
# Returns: 0 on success, 1 on invalid/out-of-range reference
_resolve_status_build_number() {
    local job_name="$1"
    local raw_build_ref="${2:-}"

    if [[ -z "$raw_build_ref" ]]; then
        echo ""
        return 0
    fi

    # 0 and -0 mean "latest/current build"
    if [[ "$raw_build_ref" == "0" || "$raw_build_ref" == "-0" ]]; then
        echo ""
        return 0
    fi

    # Positive values are absolute build numbers
    if [[ "$raw_build_ref" =~ ^[1-9][0-9]*$ ]]; then
        echo "$raw_build_ref"
        return 0
    fi

    # Negative values are relative offsets from latest build number
    if [[ "$raw_build_ref" =~ ^-[0-9]+$ ]]; then
        local relative_offset="${raw_build_ref#-}"
        local latest_build_number
        latest_build_number=$(get_last_build_number "$job_name")
        if [[ "$latest_build_number" == "0" || -z "$latest_build_number" ]]; then
            echo "Error: No builds found for job '${job_name}'" >&2
            return 1
        fi

        local resolved_build_number=$((latest_build_number - relative_offset))
        if [[ "$resolved_build_number" -lt 1 ]]; then
            echo "Error: Relative build reference ${raw_build_ref} resolved to #${resolved_build_number} (must be >= 1)" >&2
            return 1
        fi

        echo "$resolved_build_number"
        return 0
    fi

    echo "Error: Invalid build number: ${raw_build_ref}" >&2
    return 1
}

# Snapshot status output for multiple builds (oldest first).
# Arguments: job_name, [start_build_number], [line_count], [json_mode]
# Returns: exit code based on the newest build (last printed row/object)
_status_multi_build_check() {
    local job_name="$1"
    local start_build_number="${2:-}"
    local line_count="${3:-1}"
    local json_mode="${4:-false}"
    local prior_jobs_count="${5:-0}"
    local no_tests="${6:-false}"
    local first_build_number="$start_build_number"

    if [[ -z "$first_build_number" ]]; then
        first_build_number=$(get_last_build_number "$job_name")
        if [[ "$first_build_number" == "0" || -z "$first_build_number" ]]; then
            echo "Error: No builds found for job '${job_name}'" >&2
            return 1
        fi
    fi

    local build_numbers=()
    local i=0
    while [[ "$i" -lt "$line_count" ]]; do
        local current_build_number=$((first_build_number - i))
        if [[ "$current_build_number" -lt 1 ]]; then
            break
        fi
        build_numbers+=("$current_build_number")
        i=$((i + 1))
    done

    if [[ "${#build_numbers[@]}" -eq 0 ]]; then
        echo "Error: No builds found for job '${job_name}'" >&2
        return 1
    fi

    local last_exit_code=1
    local total="${#build_numbers[@]}"
    local j="$total"
    while [[ "$j" -gt 0 ]]; do
        j=$((j - 1))
        local bn="${build_numbers[$j]}"
        local build_exit=1

        if [[ "$json_mode" != "true" && "$j" -eq 0 && "$prior_jobs_count" -gt 0 ]]; then
            local max_prior_build=$((bn - 1))
            _display_prior_jobs_block "$job_name" "$prior_jobs_count" "$no_tests" "$max_prior_build"
        fi

        if [[ "$json_mode" == "true" ]]; then
            local json_object
            if json_object=$(_jenkins_status_check "$job_name" "true" "$bn"); then
                build_exit=0
            else
                build_exit=$?
            fi

            if [[ -n "$json_object" ]]; then
                # JSONL: one compact JSON object per build.
                local compact_json
                compact_json=$(printf "%s\n" "$json_object" | jq -c . 2>/dev/null || printf "%s\n" "$json_object")
                printf "%s\n" "$compact_json"
            fi
        else
            if [[ "$j" -lt $((total - 1)) ]]; then
                echo ""
            fi
            if _jenkins_status_check "$job_name" "false" "$bn"; then
                build_exit=0
            else
                build_exit=$?
            fi
        fi

        if [[ "$j" -eq 0 ]]; then
            last_exit_code="$build_exit"
        fi
    done

    return "$last_exit_code"
}

# Extract trigger, commit, and correlation info from a build
# Usage: _extract_build_context "job-name" "build-number" ["build_json"] ["console_output"]
# Sets globals: _BC_TRIGGER_TYPE, _BC_TRIGGER_USER,
#               _BC_COMMIT_SHA, _BC_COMMIT_MSG, _BC_CORRELATION_STATUS
_extract_build_context() {
    local job_name="$1"
    local build_number="$2"
    local build_json="${3:-}"
    local console_output="${4:-}"

    if [[ -n "$build_json" && "${build_json#\{}" == "$build_json" ]]; then
        console_output="$build_json"
        build_json=""
    fi

    _BC_TRIGGER_TYPE="unknown"
    _BC_TRIGGER_USER="unknown"
    if [[ -n "$build_json" ]]; then
        local trigger_info
        trigger_info=$(detect_trigger_type_from_build_json "$build_json")
        local IFS=$'\n'
        set -- $trigger_info
        _BC_TRIGGER_TYPE="${1:-unknown}"
        _BC_TRIGGER_USER="${2:-unknown}"
    fi

    if [[ "$_BC_TRIGGER_TYPE" == "unknown" && -n "$console_output" ]]; then
        local trigger_info
        trigger_info=$(detect_trigger_type "$console_output")
        local IFS=$'\n'
        set -- $trigger_info
        _BC_TRIGGER_TYPE="${1:-unknown}"
        _BC_TRIGGER_USER="${2:-unknown}"
    fi

    # Extract triggering commit
    local commit_info
    commit_info=$(extract_triggering_commit "$job_name" "$build_number" "$build_json" "$console_output")
    local IFS=$'\n'
    set -- $commit_info
    _BC_COMMIT_SHA="${1:-unknown}"
    _BC_COMMIT_MSG="${2:-unknown}"

    # Correlate commit with local history
    _BC_CORRELATION_STATUS=$(correlate_commit "$_BC_COMMIT_SHA")
}

# Perform Jenkins status check and display
# Reuses logic from checkbuild.sh
# Arguments: job_name, json_mode [, build_number]
# Returns: exit code (0=success, 1=failure, 2=building)
_jenkins_status_check() {
    local job_name="$1"
    local json_mode="$2"
    local build_number="${3:-}"

    if [[ -n "$build_number" ]]; then
        bg_log_info "Fetching build #${build_number} information..."
    else
        # Get last build number
        bg_log_info "Fetching last build information..."
        build_number=$(get_last_build_number "$job_name")

        if [[ "$build_number" == "0" || -z "$build_number" ]]; then
            bg_log_error "No builds found for job '$job_name'"
            return 1
        fi
    fi

    # Get build info
    local build_json
    build_json=$(get_build_info "$job_name" "$build_number")

    if [[ -z "$build_json" ]]; then
        if [[ -n "${3:-}" ]]; then
            bg_log_error "Build #${build_number} not found for job '$job_name'"
        else
            bg_log_error "Failed to fetch build information"
        fi
        return 1
    fi

    # Extract build status
    local result building
    result=$(echo "$build_json" | jq -r '.result // "null"')
    building=$(echo "$build_json" | jq -r '.building // false')

    bg_log_success "Build #$build_number found"

    # Get console output for trigger detection and commit extraction
    bg_log_info "Analyzing build details..."
    local console_output
    console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || true

    # Extract trigger, commit, and correlation context
    _extract_build_context "$job_name" "$build_number" "$build_json" "$console_output"

    # Determine output based on build status
    local exit_code

    if [[ "$building" == "true" ]]; then
        # Build is in progress
        local current_stage
        current_stage=$(get_current_stage "$job_name" "$build_number" 2>/dev/null) || true

        if [[ "$json_mode" == "true" ]]; then
            output_json "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        else
            display_building_output "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$current_stage" \
                "$console_output"
        fi
        exit_code=2

    elif [[ "$result" == "SUCCESS" ]]; then
        # Build succeeded
        if [[ "$json_mode" == "true" ]]; then
            output_json "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        else
            display_success_output "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        fi
        exit_code=0

    else
        # Build failed (FAILURE, UNSTABLE, ABORTED, or other)
        if [[ "$json_mode" == "true" ]]; then
            output_json "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        else
            display_failure_output "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        fi
        exit_code=1
    fi

    return "$exit_code"
}
