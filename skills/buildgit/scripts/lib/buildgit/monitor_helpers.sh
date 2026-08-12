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
    console_output=$(get_console_output_cached "$job_name" "$build_number" 2>/dev/null) || true

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

_buildgit_iter_cache_begin() {
    _buildgit_iter_cache_end
    BUILDGIT_ITER_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/buildgit-iter-cache.XXXXXX")"
    export BUILDGIT_ITER_CACHE_DIR
}

_buildgit_iter_cache_end() {
    if [[ -n "${BUILDGIT_ITER_CACHE_DIR:-}" ]]; then
        rm -rf "$BUILDGIT_ITER_CACHE_DIR" 2>/dev/null || true
        unset BUILDGIT_ITER_CACHE_DIR
    fi
}

_buildgit_timing_ms() {
    local start="$1"
    local finish="$2"
    local seconds=$((finish - start))
    if [[ "$seconds" -lt 0 ]]; then
        seconds=0
    fi
    echo $((seconds * 1000))
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
    local iter_num=0
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
        iter_num=$((iter_num + 1))
        local iter_start=""
        local build_info_start=""
        local build_info_end=""
        local build_info_ms=0
        local stage_track_ms=0
        iter_start=$(date +%s)
        if [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]]; then
            build_info_start="$iter_start"
        fi

        local build_info
        build_info=$(get_build_info "$job_name" "$build_number")
        if [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]]; then
            build_info_end=$(date +%s)
            build_info_ms=$(_buildgit_timing_ms "$build_info_start" "$build_info_end")
        fi

        if [[ -z "$build_info" ]]; then
            consecutive_failures=$((consecutive_failures + 1))
            if [[ $consecutive_failures -ge 5 ]]; then
                if [[ "$showed_progress" == "true" ]]; then
                    _clear_follow_line_progress_final
                    showed_progress=false
                fi
                rm -f "$stage_log_file" 2>/dev/null || true
                rm -f "$stage_state_file" 2>/dev/null || true
                rm -f "$deferred_log_file" 2>/dev/null || true
                bg_log_error "Too many consecutive API failures ($consecutive_failures)"
                return 1
            fi
            if [[ "$showed_progress" == "true" ]]; then
                _print_above_follow_line_progress "$(log_warning "API request failed, retrying... ($consecutive_failures/5)")"
                if [[ "${_PROGRESS_BAR_LINE_COUNT:-0}" -le 0 ]]; then
                    showed_progress=false
                fi
            else
                bg_log_warning "API request failed, retrying... ($consecutive_failures/5)"
            fi
            local iter_end iter_cost sleep_secs
            iter_end=$(date +%s)
            iter_cost=$((iter_end - iter_start))
            if [[ $iter_cost -lt 0 ]]; then
                iter_cost=0
            fi
            if [[ $iter_cost -lt $POLL_INTERVAL ]]; then
                sleep_secs=$((POLL_INTERVAL - iter_cost))
                sleep "$sleep_secs"
            fi
            if [[ $iter_cost -gt $POLL_INTERVAL ]]; then
                elapsed=$((elapsed + iter_cost))
            else
                elapsed=$((elapsed + POLL_INTERVAL))
            fi
            line_frame=$((line_frame + 1))
            continue
        fi

        consecutive_failures=0
        _buildgit_iter_cache_begin

        local deferred_output=""
        local stage_output=""
        local emit_verbose_progress=false
        local building result
        building=$(echo "$build_info" | jq -r '.building')
        result=$(echo "$build_info" | jq -r '.result // empty')

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

        # Short-circuit directly into completion handling when Jenkins has already
        # reported a terminal result. Final-stage reconciliation happens in the
        # settle/flush passes below instead of the top-of-loop tracker.
        # Spec: monitor-poll-latency-spec.md § 3
        if [[ "$building" == "false" && -n "$result" ]]; then
            if [[ "$showed_progress" == "true" ]]; then
                _clear_follow_line_progress_final
                showed_progress=false
            fi
            _buildgit_iter_cache_end
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
            # First do one immediate track call, then poll briefly for stability.
            _buildgit_iter_cache_begin
            if [[ "$render_progress" == "true" && -n "$stage_log_file" ]]; then
                BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>"$stage_log_file" >"$stage_state_file"
                stage_state=$(cat "$stage_state_file")
                stage_output=$(cat "$stage_log_file")
                : > "$stage_log_file"
                if [[ -n "$stage_output" ]]; then
                    printf '%s\n' "$stage_output"
                    stage_output=""
                fi
            else
                BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>&1 >"$stage_state_file"
                stage_state=$(cat "$stage_state_file")
            fi
            _buildgit_iter_cache_end
            local settle_elapsed=0
            local stable_polls=0
            local settle_iterations=0
            local verified_exit=false
            local settle_flush_count=0
            local prev_state_fingerprint
            prev_state_fingerprint=$(_stage_state_settle_fingerprint "$stage_state")
            local tracking_complete
            tracking_complete=$(echo "$stage_state" | jq -r '.tracking_complete // false' 2>/dev/null || echo false)
            # Exit when fingerprint stable for STABLE_POLLS iterations OR
            # tracking_complete=true. Empty fd-3 output alone is too eager —
            # late-arriving stages from the Jenkins API may not be in the next
            # poll's print stream but ARE in the next state, so we must wait
            # for state stability (fingerprint match) not just print stability.
            # NB: continuation uses AND — we want to exit when EITHER stable
            # OR complete; the prior code used OR here, which required BOTH
            # and made the loop hit MONITOR_SETTLE_MAX_SECONDS on every
            # monorepo build where tracking_complete never flipped to true.
            #
            # Flush-verified early exit (monitor-exit-latency-spec.md § 2):
            # tracking_complete can never flip to true from tracker passes
            # alone — wrapper/branch-summary rows are deferred and only
            # printed by _force_flush_completion_stages. So on the first
            # stable, print-quiescent fingerprint window, run the flush
            # immediately (fresh cache window = independent second API
            # sample). If the flush's state agrees with the tracker sample
            # AND reports tracking_complete=true, exit now instead of
            # waiting out MONITOR_SETTLE_STABLE_POLLS. Any disagreement
            # falls back to the stable-polls/time caps exactly as before.
            # Print-quiescence is required: the tracker prints parallel
            # rows enriched (resolved ║N paths, matured agents behind the
            # readiness gates) while the flush prints raw entries; letting
            # the flush preempt a still-printing tracker emits raw rows
            # (no [agent]/║N) and marks them printed forever — seen as an
            # integration_tests.bats structure failure on CI.
            while [[ $settle_elapsed -lt $MONITOR_SETTLE_MAX_SECONDS && $stable_polls -lt $MONITOR_SETTLE_STABLE_POLLS && "$tracking_complete" != "true" ]]; do
                sleep 1
                local settle_iteration_start settle_iteration_end settle_iteration_cost
                settle_iteration_start=$(date +%s)
                local settle_stage_output=""
                local settle_tmp_log
                settle_tmp_log="${stage_log_file:-$(mktemp "${TMPDIR:-/tmp}/buildgit-settle-log.XXXXXX")}"
                _buildgit_iter_cache_begin
                BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>"$settle_tmp_log" >"$stage_state_file"
                stage_state=$(cat "$stage_state_file")
                settle_stage_output=$(cat "$settle_tmp_log")
                : > "$settle_tmp_log"
                local tracker_print_quiescent=true
                if [[ -n "$settle_stage_output" ]]; then
                    printf '%s\n' "$settle_stage_output"
                    tracker_print_quiescent=false
                fi
                _buildgit_iter_cache_end
                local current_state_fingerprint
                current_state_fingerprint=$(_stage_state_settle_fingerprint "$stage_state")
                tracking_complete=$(echo "$stage_state" | jq -r '.tracking_complete // false' 2>/dev/null || echo false)
                if [[ "$tracker_print_quiescent" != "true" ]]; then
                    # Tracker is still emitting enriched rows — treat as
                    # instability regardless of the API fingerprint.
                    stable_polls=0
                    prev_state_fingerprint="$current_state_fingerprint"
                elif [[ "$current_state_fingerprint" == "$prev_state_fingerprint" && "$tracking_complete" != "true" ]]; then
                    # Stable window observed — attempt the verified exit.
                    settle_flush_count=$((settle_flush_count + 1))
                    _buildgit_iter_cache_begin
                    BUILDGIT_SIDE_EFFECT_FD=3 _force_flush_completion_stages "$job_name" "$build_number" "$stage_state" 3>"$settle_tmp_log" >"$stage_state_file"
                    stage_state=$(cat "$stage_state_file")
                    settle_stage_output=$(cat "$settle_tmp_log")
                    : > "$settle_tmp_log"
                    if [[ -n "$settle_stage_output" ]]; then
                        printf '%s\n' "$settle_stage_output"
                    fi
                    _buildgit_iter_cache_end
                    local flush_fingerprint
                    flush_fingerprint=$(_stage_state_settle_fingerprint "$stage_state")
                    tracking_complete=$(echo "$stage_state" | jq -r '.tracking_complete // false' 2>/dev/null || echo false)
                    if [[ "$flush_fingerprint" == "$current_state_fingerprint" ]]; then
                        if [[ "$tracking_complete" == "true" ]]; then
                            verified_exit=true
                        fi
                        stable_polls=$((stable_polls + 1))
                    else
                        stable_polls=0
                        prev_state_fingerprint="$flush_fingerprint"
                    fi
                else
                    stable_polls=0
                    prev_state_fingerprint="$current_state_fingerprint"
                fi
                if [[ -z "$stage_log_file" ]]; then
                    rm -f "$settle_tmp_log" 2>/dev/null || true
                fi
                settle_iteration_end=$(date +%s)
                settle_iteration_cost=$((settle_iteration_end - settle_iteration_start + 1))
                if [[ "$settle_iteration_cost" -lt 1 ]]; then
                    settle_iteration_cost=1
                fi
                settle_elapsed=$((settle_elapsed + settle_iteration_cost))
                settle_iterations=$((settle_iterations + 1))
            done
            if [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]]; then
                printf '[buildgit-settle] iterations=%d elapsed=%d stable_polls=%d tracking_complete=%s verified_exit=%s flushes=%d\n' \
                    "$settle_iterations" "$settle_elapsed" "$stable_polls" "$tracking_complete" "$verified_exit" "$settle_flush_count" >&2
            fi
            # Run at least one force-flush pass after the settle loop —
            # UNLESS the settle loop ended via the flush-verified exit, in
            # which case a flush already ran, agreed with an independent
            # tracker sample, printed everything printable, and reported
            # tracking_complete=true; another full-refetch pass is pure
            # added latency. (Spec: monitor-exit-latency-spec.md § 3)
            # For every other exit path (stable-polls cap, time cap,
            # tracker-reported tracking_complete), the mandatory flush is
            # still required: late-arriving parent stages (notably Finalize)
            # may not yet be reflected by the Jenkins API at the moment
            # settle exited, and parallel branch summaries can be deferred
            # in printed_state while the tracker reports complete on CI with
            # MONITOR_SETTLE_STABLE_POLLS=1 — see integration_tests.bats
            # parallel-substages tests which verify Finalize is printed.
            local flush_elapsed=0
            local flush_iterations=0
            local flush_max_iterations=${MONITOR_FLUSH_MAX_ITERATIONS:-1}
            if [[ "$verified_exit" == "true" ]]; then
                flush_iterations=1
            fi
            while [[ $flush_iterations -eq 0 || ( $flush_elapsed -lt $MONITOR_SETTLE_MAX_SECONDS && $flush_iterations -lt $flush_max_iterations && "$tracking_complete" != "true" ) ]]; do
                if [[ $flush_iterations -gt 0 ]]; then
                    sleep 1
                fi
                flush_iterations=$((flush_iterations + 1))
                local flush_iteration_start flush_iteration_end flush_iteration_cost
                flush_iteration_start=$(date +%s)
                _buildgit_iter_cache_begin
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
                _buildgit_iter_cache_end
                flush_iteration_end=$(date +%s)
                flush_iteration_cost=$((flush_iteration_end - flush_iteration_start + 1))
                if [[ "$flush_iteration_cost" -lt 1 ]]; then
                    flush_iteration_cost=1
                fi
                tracking_complete=$(echo "$stage_state" | jq -r '.tracking_complete // false' 2>/dev/null || echo false)
                flush_elapsed=$((flush_elapsed + flush_iteration_cost))
            done
            if [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]]; then
                local total_ms
                total_ms=$(_buildgit_timing_ms "$iter_start" "$(date +%s)")
                printf '[buildgit-timing] iter=%d build_info=%d stage_track=%d total=%d building=%s\n' \
                    "$iter_num" "$build_info_ms" "$stage_track_ms" "$total_ms" "$building" >&2
            fi
            _buildgit_iter_cache_end
            rm -f "$stage_log_file" 2>/dev/null || true
            rm -f "$stage_state_file" 2>/dev/null || true
            rm -f "$deferred_log_file" 2>/dev/null || true
            return 0
        fi

        # Track stage changes for in-progress builds before rendering progress.
        # Spec: bug-show-all-stages.md - all stages must be shown
        # Spec: nested-jobs-display-spec.md - track downstream builds in real-time
        local stage_track_start=""
        if [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]]; then
            stage_track_start=$(date +%s)
        fi
        if [[ "$render_progress" == "true" && -n "$stage_log_file" ]]; then
            BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>"$stage_log_file" >"$stage_state_file"
            stage_state=$(cat "$stage_state_file")
            stage_output=$(cat "$stage_log_file")
            : > "$stage_log_file"
        else
            BUILDGIT_SIDE_EFFECT_FD=3 _track_nested_stage_changes "$job_name" "$build_number" "$stage_state" "$VERBOSE_MODE" 3>&1 >"$stage_state_file"
            stage_state=$(cat "$stage_state_file")
        fi
        if [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]]; then
            stage_track_ms=$(_buildgit_timing_ms "$stage_track_start" "$(date +%s)")
        fi

        # Verbose-only elapsed time messages
        # Spec: full-stage-print-spec.md, Verbose mode
        if [[ "$VERBOSE_MODE" == "true" && $((elapsed - last_time_report)) -ge 30 ]]; then
            emit_verbose_progress=true
            last_time_report=$elapsed
        fi

        if [[ "$showed_progress" == "true" ]]; then
            if [[ -n "$deferred_output" || -n "$stage_output" || "$emit_verbose_progress" == "true" ]]; then
                local permanent_output=""
                if [[ -n "$deferred_output" ]]; then
                    permanent_output+="$deferred_output"
                fi
                if [[ -n "$stage_output" ]]; then
                    if [[ -n "$permanent_output" ]]; then
                        permanent_output+=$'\n'
                    fi
                    permanent_output+="$stage_output"
                fi
                if [[ "$emit_verbose_progress" == "true" ]]; then
                    if [[ -n "$permanent_output" ]]; then
                        permanent_output+=$'\n'
                    fi
                    permanent_output+="$(log_info "Build in progress... (${elapsed}s elapsed)")"
                fi
                _print_above_follow_line_progress "$permanent_output"
                if [[ "${_PROGRESS_BAR_LINE_COUNT:-0}" -le 0 ]]; then
                    showed_progress=false
                fi
                deferred_output=""
                stage_output=""
                emit_verbose_progress=false
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

        _buildgit_iter_cache_end
        if [[ -n "${BUILDGIT_DEBUG_TIMING:-}" ]]; then
            local total_ms
            total_ms=$(_buildgit_timing_ms "$iter_start" "$(date +%s)")
            printf '[buildgit-timing] iter=%d build_info=%d stage_track=%d total=%d building=%s\n' \
                "$iter_num" "$build_info_ms" "$stage_track_ms" "$total_ms" "$building" >&2
        fi
        local iter_end iter_cost sleep_secs
        iter_end=$(date +%s)
        iter_cost=$((iter_end - iter_start))
        if [[ $iter_cost -lt 0 ]]; then
            iter_cost=0
        fi
        if [[ $iter_cost -lt $POLL_INTERVAL ]]; then
            sleep_secs=$((POLL_INTERVAL - iter_cost))
            sleep "$sleep_secs"
        fi
        if [[ $iter_cost -gt $POLL_INTERVAL ]]; then
            elapsed=$((elapsed + iter_cost))
        else
            elapsed=$((elapsed + POLL_INTERVAL))
        fi
        line_frame=$((line_frame + 1))
    done

    if [[ "$showed_progress" == "true" ]]; then
        _clear_follow_line_progress_final
        echo ""
    fi
    _buildgit_iter_cache_end
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

    # Never hand empty/blank text to --argjson: jq aborts with
    # "invalid JSON text passed to --argjson" on stderr, which the probe-all
    # poll loop would repeat forever. No inputs means no candidate.
    if [[ -z "${baselines_json//[$' \t\r\n']}" || -z "${current_json//[$' \t\r\n']}" ]]; then
        return 0
    fi

    jq -rn --argjson base "$baselines_json" --argjson curr "$current_json" '
        $curr
        | to_entries
        | sort_by(.key)
        | map(select((.value > 0) and (($base[.key] // 0) < .value)))
        | first // empty
        | "\(.key) \(.value)"
    ' 2>/dev/null || true
}

# Convert rich baseline JSON { branch: { number, building } } to flat adjusted map.
# In-progress builds (building=true) are counted as number-1 so the current poll
# will immediately satisfy current > baseline for already-running builds.
_normalize_probe_all_baselines() {
    local rich_json="$1"
    if [[ -z "${rich_json//[$' \t\r\n']}" ]]; then
        return 0
    fi
    printf '%s\n' "$rich_json" | jq -c 'with_entries(.value = (if .value.building == true and .value.number > 0 then .value.number - 1 else .value.number end))' 2>/dev/null || true
}

# Convert rich baseline JSON to flat map of just build numbers (no adjustment).
# Used for the "current" side of detection comparisons.
_flatten_probe_all_baselines() {
    local rich_json="$1"
    if [[ -z "${rich_json//[$' \t\r\n']}" ]]; then
        return 0
    fi
    printf '%s\n' "$rich_json" | jq -c 'with_entries(.value = .value.number)' 2>/dev/null || true
}

# Number of consecutive failed probe-all polls between repeat warnings.
# At the default 5s poll interval this is roughly one warning per minute.
_PROBE_ALL_FETCH_WARN_EVERY="${_PROBE_ALL_FETCH_WARN_EVERY:-12}"

# Report that a probe-all poll could not reach Jenkins, without flooding the
# terminal: warn on the first failure, then once every
# _PROBE_ALL_FETCH_WARN_EVERY consecutive failures.
# Writes to stderr on purpose — probe-all's stdout is captured by the caller's
# $(...) and would not surface until the wait finally returns.
_probe_all_log_fetch_failure() {
    local top_job_name="$1"
    local failures="$2"

    if [[ "$failures" -eq 1 ]]; then
        log_warning "Cannot reach Jenkins while waiting for a ${top_job_name} build - retrying every ${POLL_INTERVAL:-5}s" >&2
    elif [[ $((failures % _PROBE_ALL_FETCH_WARN_EVERY)) -eq 0 ]]; then
        log_warning "Still cannot reach Jenkins while waiting for a ${top_job_name} build (${failures} consecutive failed polls)" >&2
    fi
}

# Announce that polling recovered, but only if we previously warned about it.
_probe_all_log_fetch_recovery() {
    local top_job_name="$1"
    local failures="$2"

    if [[ "$failures" -gt 0 ]]; then
        log_info "Jenkins reachable again - resuming ${top_job_name} branch polling" >&2
    fi
}

# Return 0 if the given branch name appears in the space-separated in-progress set.
_branch_was_in_progress() {
    local branch="$1"
    local in_progress_set="$2"
    local b
    for b in $in_progress_set; do
        if [[ "$b" == "$branch" ]]; then
            return 0
        fi
    done
    return 1
}

# Wait for a new multibranch build to start on any branch.
# Arguments: top_job_name
# Prints "branch build_number" on stdout and returns 0 on success.
# Spec: 2026-04-10_probe-all-initial-build-spec.md
_follow_wait_probe_all() {
    local top_job_name="$1"
    local raw_baselines in_progress_branches baselines fetch_failures=0

    # Keep retrying the baseline fetch: an empty/failed response must never be
    # accepted as a baseline, or every branch would look like a new build.
    while ! raw_baselines=$(_fetch_multibranch_baselines "$top_job_name"); do
        fetch_failures=$((fetch_failures + 1))
        _probe_all_log_fetch_failure "$top_job_name" "$fetch_failures"
        sleep "$POLL_INTERVAL"
    done
    _probe_all_log_fetch_recovery "$top_job_name" "$fetch_failures"
    fetch_failures=0
    in_progress_branches=$(echo "$raw_baselines" | jq -r '[to_entries[] | select(.value.building == true) | .key] | join(" ")')
    baselines=$(_normalize_probe_all_baselines "$raw_baselines")

    log_info "Waiting for Jenkins build ${top_job_name} (any branch) to start..."

    while true; do
        local raw_current current detected
        if ! raw_current=$(_fetch_multibranch_baselines "$top_job_name"); then
            fetch_failures=$((fetch_failures + 1))
            _probe_all_log_fetch_failure "$top_job_name" "$fetch_failures"
            sleep "$POLL_INTERVAL"
            continue
        fi
        _probe_all_log_fetch_recovery "$top_job_name" "$fetch_failures"
        fetch_failures=0
        current=$(_flatten_probe_all_baselines "$raw_current")
        detected=$(_detect_probe_all_candidate "$baselines" "$current")

        if [[ -n "$detected" ]]; then
            local branch build_number
            branch="${detected%% *}"
            build_number="${detected##* }"
            if _branch_was_in_progress "$branch" "$in_progress_branches"; then
                log_info "Build already in progress on branch '${branch}' — attaching to ${top_job_name}/${branch} #${build_number}"
            else
                log_info "Build detected on branch '${branch}' — following ${top_job_name}/${branch} #${build_number}"
            fi
            echo "${branch} ${build_number}"
            return 0
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Wait for a new multibranch build to start on any branch, with a timeout.
# Arguments: top_job_name, timeout_secs
# Prints "branch build_number" on stdout and returns 0 on success.
# Returns 1 if timeout expires before a new build appears.
# Spec: 2026-04-10_probe-all-initial-build-spec.md
_follow_wait_probe_all_timeout() {
    local top_job_name="$1"
    local timeout_secs="$2"
    local raw_baselines in_progress_branches baselines fetch_failures=0
    local deadline=$(( $(date +%s) + timeout_secs ))

    # A failed baseline fetch is retried until the deadline; accepting an empty
    # baseline would latch onto an already-finished build on the next poll.
    while ! raw_baselines=$(_fetch_multibranch_baselines "$top_job_name"); do
        fetch_failures=$((fetch_failures + 1))
        _probe_all_log_fetch_failure "$top_job_name" "$fetch_failures"
        if [[ $(date +%s) -ge $deadline ]]; then
            return 1
        fi
        sleep "$POLL_INTERVAL"
    done
    _probe_all_log_fetch_recovery "$top_job_name" "$fetch_failures"
    fetch_failures=0
    in_progress_branches=$(echo "$raw_baselines" | jq -r '[to_entries[] | select(.value.building == true) | .key] | join(" ")')
    baselines=$(_normalize_probe_all_baselines "$raw_baselines")

    log_info "Waiting for Jenkins build ${top_job_name} (any branch) to start..."

    while true; do
        local raw_current current detected
        if ! raw_current=$(_fetch_multibranch_baselines "$top_job_name"); then
            fetch_failures=$((fetch_failures + 1))
            _probe_all_log_fetch_failure "$top_job_name" "$fetch_failures"
            if [[ $(date +%s) -ge $deadline ]]; then
                return 1
            fi
            sleep "$POLL_INTERVAL"
            continue
        fi
        _probe_all_log_fetch_recovery "$top_job_name" "$fetch_failures"
        fetch_failures=0
        current=$(_flatten_probe_all_baselines "$raw_current")
        detected=$(_detect_probe_all_candidate "$baselines" "$current")

        if [[ -n "$detected" ]]; then
            local branch build_number
            branch="${detected%% *}"
            build_number="${detected##* }"
            if _branch_was_in_progress "$branch" "$in_progress_branches"; then
                log_info "Build already in progress on branch '${branch}' — attaching to ${top_job_name}/${branch} #${build_number}"
            else
                log_info "Build detected on branch '${branch}' — following ${top_job_name}/${branch} #${build_number}"
            fi
            echo "${branch} ${build_number}"
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
