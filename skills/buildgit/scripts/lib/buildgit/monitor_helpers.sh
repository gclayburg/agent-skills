# Monitor a build until completion
# Reuses monitoring logic from pushmon.sh pattern
# Arguments: job_name, build_number
# Returns: 0 when build completes
# Print deferred header fields when data becomes available
# Called from _monitor_build when console output arrives after initial banner
# Only prints fields that were actually missing from the initial header
# Spec: bug-build-monitoring-header-spec.md - deferred header fields
_print_deferred_header_fields() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"
    local max_attempts="${DEFERRED_HEADER_MAX_ATTEMPTS:-6}"

    # Need console output to resolve deferred fields
    local console_output
    console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || true

    if [[ -z "$console_output" ]]; then
        return 1  # Not yet available
    fi

    # Re-extract build context with console output
    _extract_build_context "$job_name" "$build_number" "$build_json" "$console_output"
    _DEFERRED_HEADER_ATTEMPTS=$(( ${_DEFERRED_HEADER_ATTEMPTS:-0} + 1 ))

    # Print Commit line if it was deferred and now available
    if [[ "$_DEFERRED_COMMIT" == "true" && -n "$_BC_COMMIT_SHA" && "$_BC_COMMIT_SHA" != "unknown" ]]; then
        local commit_display
        commit_display=$(_format_commit_display "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG")
        _format_correlation_display "$_BC_CORRELATION_STATUS"
        echo "Commit:     ${commit_display}"
        echo "            ${_CORRELATION_COLOR}${_CORRELATION_SYMBOL} ${_CORRELATION_DESC}${COLOR_RESET}"
        _DEFERRED_COMMIT=false
        printed_something=true
    fi

    # Print Agent line if it was deferred
    if [[ "${_DEFERRED_AGENT:-false}" == "true" ]]; then
        _parse_build_metadata "$console_output"
        if [[ -n "${_META_AGENT:-}" ]]; then
            echo "Agent:      ${_META_AGENT}"
            _DEFERRED_AGENT=false
            printed_something=true
        fi
    fi

    # Print Console URL last, after deferred Commit/Agent.
    if [[ "${_DEFERRED_CONSOLE:-false}" == "true" ]]; then
        if [[ "${_DEFERRED_COMMIT:-false}" != "true" && "${_DEFERRED_AGENT:-false}" != "true" ]] || \
           [[ "${_DEFERRED_HEADER_ATTEMPTS:-0}" -ge "$max_attempts" ]]; then
            local url
            url=$(echo "$build_json" | jq -r '.url // empty')
            if [[ -n "$url" ]]; then
                echo "Console:    ${url}console"
            fi
            _DEFERRED_CONSOLE=false
        fi
    fi

    return 0
}

# Unified build monitoring loop
# Polls Jenkins API until build completes, tracking stage changes in real-time
# Arguments: job_name, build_number
# Returns: 0 when build completes, 1 on timeout/error
# Spec: unify-follow-log-spec.md, Section 3 (Stage Output)
__buildgit_monitor_build_impl() {
    local job_name="$1"
    local build_number="$2"
    local show_progress_footer="${3:-false}"
    local include_queue_lines="${4:-false}"
    local elapsed=0
    local consecutive_failures=0
    local last_time_report=0
    local line_frame=0
    local showed_progress=false
    local estimate_ms=""
    local render_progress=false
    local stage_log_file=""
    local stage_state_file=""
    local deferred_log_file=""
    stage_state_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-stage-state.XXXXXX")"
    if [[ "$show_progress_footer" == "true" ]]; then
        if _status_stdout_is_tty; then
            render_progress=true
            _prime_follow_progress_estimates "$job_name"
            estimate_ms="${_FOLLOW_BUILD_ESTIMATE_MS:-}"
            stage_log_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-stage-log.XXXXXX")"
            deferred_log_file="$(mktemp "${TMPDIR:-/tmp}/buildgit-deferred-log.XXXXXX")"
        fi
    fi

    # Initialize stage_state from banner's snapshot (avoids timing gaps)
    # _BANNER_STAGES_JSON is set by _display_stages() --completed-only in the banner
    # Spec: bug-show-all-stages.md - use banner state to avoid missing stages
    local stage_state="${_BANNER_STAGES_JSON:-[]}"
    _BANNER_STAGES_JSON=""  # Reset after reading

    bg_log_info "Monitoring build #${build_number}..."

    while [[ $elapsed -lt $MAX_BUILD_TIME ]]; do
        local build_info
        build_info=$(get_build_info "$job_name" "$build_number")

        if [[ -z "$build_info" ]]; then
            consecutive_failures=$((consecutive_failures + 1))
            if [[ "$showed_progress" == "true" ]]; then
                _clear_follow_line_progress
                showed_progress=false
            fi
            if [[ $consecutive_failures -ge 5 ]]; then
                rm -f "$stage_log_file" 2>/dev/null || true
                rm -f "$stage_state_file" 2>/dev/null || true
                rm -f "$deferred_log_file" 2>/dev/null || true
                bg_log_error "Too many consecutive API failures ($consecutive_failures)"
                return 1
            fi
            bg_log_warning "API request failed, retrying... ($consecutive_failures/5)"
            sleep "$POLL_INTERVAL"
            elapsed=$((elapsed + POLL_INTERVAL))
            line_frame=$((line_frame + 1))
            continue
        fi

        consecutive_failures=0

        local deferred_output=""
        local stage_output=""
        local emit_verbose_progress=false

        # Collect deferred-header output first so API calls complete before clear+redraw.
        if [[ "${_DEFERRED_COMMIT:-false}" == "true" || "${_DEFERRED_AGENT:-false}" == "true" || "${_DEFERRED_CONSOLE:-false}" == "true" ]]; then
            if [[ "$render_progress" == "true" && -n "$deferred_log_file" ]]; then
                _print_deferred_header_fields "$job_name" "$build_number" "${_DEFERRED_BUILD_JSON:-$build_info}" >"$deferred_log_file" 2>&1 || true
                deferred_output=$(cat "$deferred_log_file")
                : > "$deferred_log_file"
            else
                _print_deferred_header_fields "$job_name" "$build_number" "${_DEFERRED_BUILD_JSON:-$build_info}" || true
            fi
        fi

        # Track stage changes BEFORE checking completion
        # This ensures the final iteration still catches stage transitions
        # Spec: bug-show-all-stages.md - all stages must be shown
        # Spec: nested-jobs-display-spec.md - track downstream builds in real-time
        if [[ "$render_progress" == "true" && -n "$stage_log_file" ]]; then
            BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>"$stage_log_file" >"$stage_state_file"
            stage_state=$(cat "$stage_state_file")
            stage_output=$(cat "$stage_log_file")
            : > "$stage_log_file"
        else
            BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>&1 >"$stage_state_file"
            stage_state=$(cat "$stage_state_file")
        fi

        local building result
        building=$(echo "$build_info" | jq -r '.building')
        result=$(echo "$build_info" | jq -r '.result // empty')

        # Check completion (after stage tracking so final transitions are caught)
        if [[ "$building" == "false" && -n "$result" ]]; then
            if [[ "$showed_progress" == "true" ]]; then
                _clear_follow_line_progress
                showed_progress=false
            fi
            if [[ -n "$deferred_output" ]]; then
                printf '%s\n' "$deferred_output"
                deferred_output=""
            fi
            if [[ -n "$stage_output" ]]; then
                printf '%s\n' "$stage_output"
                stage_output=""
            fi
            # Reconcile late-arriving nested stage metadata before exiting monitor.
            # Jenkins can mark the root build complete slightly before nested
            # stage details are fully available through API/log parsing.
            # Keep polling until state stabilizes or max settle window expires.
            local settle_elapsed=0
            local stable_polls=0
            local prev_state_fingerprint
            prev_state_fingerprint=$(_stage_state_settle_fingerprint "$stage_state")
            local tracking_complete
            tracking_complete=$(echo "$stage_state" | jq -r '.tracking_complete // false' 2>/dev/null || echo false)
            while [[ $settle_elapsed -lt $MONITOR_SETTLE_MAX_SECONDS && ( $stable_polls -lt $MONITOR_SETTLE_STABLE_POLLS || "$tracking_complete" != "true" ) ]]; do
                sleep 1
                local settle_iteration_start settle_iteration_end settle_iteration_cost
                settle_iteration_start=$(date +%s)
                local settle_stage_output=""
                if [[ "$render_progress" == "true" && -n "$stage_log_file" ]]; then
                    BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>"$stage_log_file" >"$stage_state_file"
                    stage_state=$(cat "$stage_state_file")
                    settle_stage_output=$(cat "$stage_log_file")
                    : > "$stage_log_file"
                    if [[ -n "$settle_stage_output" ]]; then
                        printf '%s\n' "$settle_stage_output"
                    fi
                else
                    BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>&1 >"$stage_state_file"
                    stage_state=$(cat "$stage_state_file")
                fi
                settle_iteration_end=$(date +%s)
                settle_iteration_cost=$((settle_iteration_end - settle_iteration_start + 1))
                if [[ "$settle_iteration_cost" -lt 1 ]]; then
                    settle_iteration_cost=1
                fi
                local current_state_fingerprint
                current_state_fingerprint=$(_stage_state_settle_fingerprint "$stage_state")
                tracking_complete=$(echo "$stage_state" | jq -r '.tracking_complete // false' 2>/dev/null || echo false)
                if [[ "$current_state_fingerprint" == "$prev_state_fingerprint" ]]; then
                    stable_polls=$((stable_polls + 1))
                else
                    stable_polls=0
                    prev_state_fingerprint="$current_state_fingerprint"
                fi
                settle_elapsed=$((settle_elapsed + settle_iteration_cost))
            done
            if [[ "$render_progress" == "true" && -n "$stage_log_file" ]]; then
                BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>"$stage_log_file" >"$stage_state_file"
                stage_state=$(cat "$stage_state_file")
                stage_output=$(cat "$stage_log_file")
                : > "$stage_log_file"
                if [[ -n "$stage_output" ]]; then
                    printf '%s\n' "$stage_output"
                fi
            else
                BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>&1 >"$stage_state_file"
                stage_state=$(cat "$stage_state_file")
            fi
            tracking_complete=$(echo "$stage_state" | jq -r '.tracking_complete // false' 2>/dev/null || echo false)
            if [[ "$tracking_complete" != "true" ]]; then
                local flush_elapsed=0
                while [[ $flush_elapsed -lt $MONITOR_SETTLE_MAX_SECONDS && "$tracking_complete" != "true" ]]; do
                    sleep 1
                    local flush_iteration_start flush_iteration_end flush_iteration_cost
                    flush_iteration_start=$(date +%s)
                    if [[ "$render_progress" == "true" && -n "$stage_log_file" ]]; then
                        BUILDGIT_SIDE_EFFECT_FD=3 _force_flush_completion_stages "$job_name" "$build_number" "$stage_state" 3>"$stage_log_file" >"$stage_state_file"
                        stage_state=$(cat "$stage_state_file")
                        stage_output=$(cat "$stage_log_file")
                        : > "$stage_log_file"
                        if [[ -n "$stage_output" ]]; then
                            printf '%s\n' "$stage_output"
                        fi
                    else
                        BUILDGIT_SIDE_EFFECT_FD=3 _force_flush_completion_stages "$job_name" "$build_number" "$stage_state" 3>&1 >"$stage_state_file"
                        stage_state=$(cat "$stage_state_file")
                    fi
                    flush_iteration_end=$(date +%s)
                    flush_iteration_cost=$((flush_iteration_end - flush_iteration_start + 1))
                    if [[ "$flush_iteration_cost" -lt 1 ]]; then
                        flush_iteration_cost=1
                    fi
                    tracking_complete=$(echo "$stage_state" | jq -r '.tracking_complete // false' 2>/dev/null || echo false)
                    flush_elapsed=$((flush_elapsed + flush_iteration_cost))
                done
            fi
            rm -f "$stage_log_file" 2>/dev/null || true
            rm -f "$stage_state_file" 2>/dev/null || true
            rm -f "$deferred_log_file" 2>/dev/null || true
            return 0
        fi

        # Verbose-only elapsed time messages
        # Spec: full-stage-print-spec.md, Verbose mode
        if [[ "$VERBOSE_MODE" == "true" && $((elapsed - last_time_report)) -ge 30 ]]; then
            emit_verbose_progress=true
            last_time_report=$elapsed
        fi

        if [[ "$showed_progress" == "true" ]]; then
            if [[ -n "$deferred_output" || -n "$stage_output" || "$emit_verbose_progress" == "true" ]]; then
                _clear_follow_line_progress
                showed_progress=false
            fi
        fi

        if [[ -n "$deferred_output" ]]; then
            printf '%s\n' "$deferred_output"
        fi
        if [[ -n "$stage_output" ]]; then
            printf '%s\n' "$stage_output"
        fi
        if [[ "$emit_verbose_progress" == "true" ]]; then
            bg_log_progress "Build in progress... (${elapsed}s elapsed)"
        fi

        if [[ "$render_progress" == "true" ]]; then
            local stages_json=""
            if [[ "$THREADS_MODE" == "true" ]]; then
                stages_json=$(_get_follow_active_stages "$job_name" "$build_number")
            fi
            _display_follow_line_progress "$job_name" "$build_number" "$build_info" "$estimate_ms" "$line_frame" "$include_queue_lines" "$stages_json"
            showed_progress=true
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        line_frame=$((line_frame + 1))
    done

    if [[ "$showed_progress" == "true" ]]; then
        _clear_follow_line_progress
        echo ""
    fi
    rm -f "$stage_log_file" 2>/dev/null || true
    rm -f "$stage_state_file" 2>/dev/null || true
    rm -f "$deferred_log_file" 2>/dev/null || true
    bg_log_error "Build timeout: exceeded ${MAX_BUILD_TIME} seconds"
    bg_log_info "Build may still be running - check Jenkins console"
    return 1
}

# Display build in progress banner (unified header format)
# Used before monitoring begins for all commands (push, build, status -f)
# Arguments: job_name, build_number, [running_msg]
# Spec reference: unify-follow-log-spec.md, Section 2 (Build Header)
__buildgit_display_build_in_progress_banner_impl() {
    local job_name="$1"
    local build_number="$2"
    local running_msg="${3:-}"
    local preferred_commit_sha="${4:-}"
    local preferred_commit_msg="${5:-}"
    local preferred_correlation_status="${6:-}"

    # Get build info
    local build_json
    build_json=$(get_build_info "$job_name" "$build_number")

    if [[ -z "$build_json" ]]; then
        bg_log_warning "Could not fetch build info for banner display"
        return 0
    fi

    # Get console output for trigger detection, commit extraction, and agent extraction
    local console_output
    console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || true

    # Extract trigger, commit, and correlation context
    _extract_build_context "$job_name" "$build_number" "$build_json" "$console_output"
    if [[ -n "$preferred_commit_sha" && "$preferred_commit_sha" != "unknown" ]]; then
        _BC_COMMIT_SHA="$preferred_commit_sha"
        _BC_COMMIT_MSG="$preferred_commit_msg"
        if [[ -n "$preferred_correlation_status" ]]; then
            _BC_CORRELATION_STATUS="$preferred_correlation_status"
        else
            _BC_CORRELATION_STATUS=$(correlate_commit "$preferred_commit_sha")
        fi
    fi

    # Get current stage
    local current_stage
    current_stage=$(get_current_stage "$job_name" "$build_number" 2>/dev/null) || true

    # Display the unified header (banner + metadata + Console URL)
    # Spec: unify-follow-log-spec.md, Section 2
    display_building_output "$job_name" "$build_number" "$build_json" \
        "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
        "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
        "$_BC_CORRELATION_STATUS" "$current_stage" \
        "$console_output" "$running_msg"

    # Track which header fields need deferred printing by _monitor_build
    # Spec: bug-build-monitoring-header-spec.md - deferred header fields
    _DEFERRED_COMMIT=false
    _DEFERRED_AGENT=false
    _DEFERRED_CONSOLE=false
    _DEFERRED_BUILD_JSON=""
    _DEFERRED_HEADER_ATTEMPTS=0
    if [[ -z "$_BC_COMMIT_SHA" || "$_BC_COMMIT_SHA" == "unknown" ]]; then
        _DEFERRED_COMMIT=true
    fi
    _parse_build_metadata "$console_output"
    if [[ -z "${_META_AGENT:-}" ]]; then
        _DEFERRED_AGENT=true
    fi
    local banner_url
    banner_url=$(echo "$build_json" | jq -r '.url // empty')
    if [[ -n "$banner_url" ]] && [[ "$_DEFERRED_COMMIT" == "true" || "$_DEFERRED_AGENT" == "true" ]]; then
        _DEFERRED_CONSOLE=true
    fi
    if [[ "$_DEFERRED_COMMIT" == "true" || "$_DEFERRED_AGENT" == "true" || "$_DEFERRED_CONSOLE" == "true" ]]; then
        _DEFERRED_BUILD_JSON="$build_json"
    fi

    # Display only completed stages after the header (skip IN_PROGRESS)
    # Also saves full stage state to _BANNER_STAGES_JSON for _monitor_build
    # Spec: bug-show-all-stages.md - never show "(running)" in initial display
    echo ""
    _display_stages "$job_name" "$build_number" --completed-only
}

# Wait for a new build to start (for follow mode)
# Arguments: job_name, baseline_build_number
# Returns: new build number on stdout, or exits on timeout
_follow_wait_for_new_build() {
    local job_name="$1"
    local baseline="$2"

    while true; do
        local current
        current=$(get_last_build_number "$job_name")

        if [[ "$current" -gt "$baseline" ]]; then
            echo "$current"
            return 0
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Wait for a new build number to appear, with a deadline-based timeout
# Arguments: job_name, baseline_build_number, timeout_secs
# Prints new build number on stdout and returns 0 on success
# Returns 1 if timeout expires before a new build appears
_follow_wait_for_new_build_timeout() {
    local job_name="$1"
    local baseline="$2"
    local timeout_secs="$3"

    local deadline=$(( $(date +%s) + timeout_secs ))

    while true; do
        local current
        current=$(get_last_build_number "$job_name")

        if [[ "$current" -gt "$baseline" ]]; then
            echo "$current"
            return 0
        fi

        local now
        now=$(date +%s)
        if [[ $now -ge $deadline ]]; then
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

_detect_probe_all_candidate() {
    local baselines_json="$1"
    local current_json="$2"

    jq -rn --argjson base "$baselines_json" --argjson curr "$current_json" '
        $curr
        | to_entries
        | sort_by(.key)
        | map(select((.value > 0) and (($base[.key] // 0) < .value)))
        | first // empty
        | "\(.key) \(.value)"
    '
}

# Wait for a new multibranch build to start on any branch.
# Arguments: top_job_name
# Prints "branch build_number" on stdout and returns 0 on success.
_follow_wait_probe_all() {
    local top_job_name="$1"
    local baselines
    baselines=$(_fetch_multibranch_baselines "$top_job_name")

    log_info "Waiting for Jenkins build ${top_job_name} (any branch) to start..."

    while true; do
        sleep "$POLL_INTERVAL"

        local current detected
        current=$(_fetch_multibranch_baselines "$top_job_name")
        detected=$(_detect_probe_all_candidate "$baselines" "$current")

        if [[ -n "$detected" ]]; then
            local branch build_number
            branch="${detected%% *}"
            build_number="${detected##* }"
            log_info "Build detected on branch '${branch}' — following ${top_job_name}/${branch} #${build_number}"
            echo "${branch} ${build_number}"
            return 0
        fi
    done
}

# Wait for a new multibranch build to start on any branch, with a timeout.
# Arguments: top_job_name, timeout_secs
# Prints "branch build_number" on stdout and returns 0 on success.
# Returns 1 if timeout expires before a new build appears.
_follow_wait_probe_all_timeout() {
    local top_job_name="$1"
    local timeout_secs="$2"
    local baselines
    baselines=$(_fetch_multibranch_baselines "$top_job_name")

    log_info "Waiting for Jenkins build ${top_job_name} (any branch) to start..."

    local deadline=$(( $(date +%s) + timeout_secs ))

    while true; do
        sleep "$POLL_INTERVAL"

        local current detected
        current=$(_fetch_multibranch_baselines "$top_job_name")
        detected=$(_detect_probe_all_candidate "$baselines" "$current")

        if [[ -n "$detected" ]]; then
            local branch build_number
            branch="${detected%% *}"
            build_number="${detected##* }"
            log_info "Build detected on branch '${branch}' — following ${top_job_name}/${branch} #${build_number}"
            echo "${branch} ${build_number}"
            return 0
        fi

        local now
        now=$(date +%s)
        if [[ $now -ge $deadline ]]; then
            return 1
        fi
    done
}

# Collect N most recently completed build numbers.
# Arguments: job_name, count, [max_build_number]
# Sets global array: _PRIOR_COMPLETED_BUILD_NUMS (newest first)
# In-progress builds are skipped and do not count toward N.
_collect_n_prior_completed_build_numbers() {
    local job_name="$1"
    local count="$2"
    local max_build_number="${3:-}"
    _PRIOR_COMPLETED_BUILD_NUMS=()

    if [[ "$count" -le 0 ]]; then
        return 0
    fi

    local latest_build
    latest_build=$(get_last_build_number "$job_name")
    if [[ "$latest_build" == "0" || -z "$latest_build" ]]; then
        return 0
    fi

    local start_build="$latest_build"
    if [[ -n "$max_build_number" ]]; then
        start_build="$max_build_number"
    fi
    if [[ "$start_build" -lt 1 ]]; then
        return 0
    fi

    # Walk backwards collecting completed build numbers
    local build_num="$start_build"
    local collected=0

    while [[ $collected -lt $count && $build_num -gt 0 ]]; do
        local binfo
        binfo=$(get_build_info "$job_name" "$build_num")
        if [[ -n "$binfo" ]]; then
            local is_building
            is_building=$(echo "$binfo" | jq -r '.building // false')
            if [[ "$is_building" != "true" ]]; then
                _PRIOR_COMPLETED_BUILD_NUMS+=("$build_num")
                collected=$((collected + 1))
            fi
        fi
        build_num=$((build_num - 1))
    done
}

# Display N most recently completed builds, oldest first
# Arguments: job_name, count, [line_mode], [no_tests], [max_build_number], [emit_output]
# In-progress builds are skipped and do not count toward N.
# Sets global: _DISPLAY_N_PRIOR_LAST_COUNT
_display_n_prior_builds() {
    local job_name="$1"
    local count="$2"
    local line_mode="${3:-false}"
    local no_tests="${4:-false}"
    local max_build_number="${5:-}"
    local emit_output="${6:-true}"

    _collect_n_prior_completed_build_numbers "$job_name" "$count" "$max_build_number"
    _DISPLAY_N_PRIOR_LAST_COUNT="${#_PRIOR_COMPLETED_BUILD_NUMS[@]}"

    if [[ "$emit_output" != "true" ]]; then
        return 0
    fi

    # Display oldest first (reverse order of collection)
    local i
    for (( i=${#_PRIOR_COMPLETED_BUILD_NUMS[@]}-1; i>=0; i-- )); do
        local bnum="${_PRIOR_COMPLETED_BUILD_NUMS[$i]}"
        local bjson
        bjson=$(get_build_info "$job_name" "$bnum")
        if [[ "$line_mode" == "true" ]]; then
            _status_line_for_build_json "$job_name" "$bnum" "$bjson" "$no_tests" || true
        else
            _display_completed_build "$job_name" "$bnum" "$bjson" || true
        fi
    done
}

# Display the prior-jobs one-line block (header + rows) when rows exist.
# Arguments: job_name, prior_jobs_count, [no_tests], [max_build_number]
_display_prior_jobs_block() {
    local job_name="$1"
    local prior_jobs_count="$2"
    local no_tests="${3:-false}"
    local max_build_number="${4:-}"

    if [[ "$prior_jobs_count" -le 0 ]]; then
        return 0
    fi

    _display_n_prior_builds "$job_name" "$prior_jobs_count" "true" "$no_tests" "$max_build_number" "false"
    if [[ "${_DISPLAY_N_PRIOR_LAST_COUNT:-0}" -le 0 ]]; then
        return 0
    fi

    log_info "Prior ${prior_jobs_count} Jobs"
    _display_n_prior_builds "$job_name" "$prior_jobs_count" "true" "$no_tests" "$max_build_number" "true"
}

# Display prior jobs and estimated build time before monitoring starts.
# Arguments: job_name, prior_jobs_count, [no_tests], [max_build_number]
_display_monitoring_preamble() {
    local job_name="$1"
    local prior_jobs_count="$2"
    local no_tests="${3:-false}"
    local max_build_number="${4:-}"

    _display_prior_jobs_block "$job_name" "$prior_jobs_count" "$no_tests" "$max_build_number"

    local estimate_ms
    estimate_ms=$(_get_last_successful_build_duration "$job_name")
    if [[ "$estimate_ms" =~ ^[1-9][0-9]*$ ]]; then
        log_info "Estimated build time = $(format_duration "$estimate_ms")"
    else
        log_info "Estimated build time = unknown"
    fi
}

# Display completed build with full header (for follow mode)
# Used when the follow loop detects a build that already completed
# Reuses the same display functions as snapshot `buildgit status`
# Arguments: job_name, build_number, build_json
# Returns: 0 for SUCCESS, 1 for FAILURE/UNSTABLE/other
# Spec: bug-status-f-missing-header-spec.md
_display_completed_build() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"

    local result
    result=$(echo "$build_json" | jq -r '.result // "UNKNOWN"')

    # Get console output for trigger detection, commit extraction, and agent extraction
    local console_output
    console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || true

    # Extract trigger, commit, and correlation context
    _extract_build_context "$job_name" "$build_number" "$build_json" "$console_output"

    # Display using the same output path as snapshot mode
    # Finished line and Duration are now included in display_*_output functions
    if [[ "$result" == "SUCCESS" ]]; then
        display_success_output "$job_name" "$build_number" "$build_json" \
            "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
            "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
            "$_BC_CORRELATION_STATUS" "$console_output"
    else
        display_failure_output "$job_name" "$build_number" "$build_json" \
            "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
            "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
            "$_BC_CORRELATION_STATUS" "$console_output"
    fi

    # Return appropriate exit code
    if [[ "$result" == "SUCCESS" ]]; then
        return 0
    else
        return 1
    fi
}

# Follow mode implementation for status command
# Spec reference: 2026-02-16_add-once-flag-to-status-f-spec.md
# On entry, does NOT replay the most recently completed build (no stale replay).
# Only monitors builds that are running at or after invocation time.
