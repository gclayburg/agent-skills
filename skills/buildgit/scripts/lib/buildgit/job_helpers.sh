_get_current_git_branch() {
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
    if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
        return 1
    fi
    echo "$current_branch"
}

_normalize_branch_ref() {
    local ref="$1"
    ref="${ref#+}"

    # For refspecs, prefer destination branch when present.
    if [[ "$ref" == *:* ]]; then
        local src_ref dst_ref
        src_ref="${ref%%:*}"
        dst_ref="${ref#*:}"
        if [[ -n "$dst_ref" ]]; then
            ref="$dst_ref"
        elif [[ -n "$src_ref" ]]; then
            ref="$src_ref"
        fi
    fi

    ref="${ref#refs/heads/}"
    if [[ "$ref" == "HEAD" || -z "$ref" ]]; then
        _get_current_git_branch || return 1
    else
        echo "$ref"
    fi
}

_infer_push_branch_from_args() {
    local args=("${PUSH_GIT_ARGS[@]+"${PUSH_GIT_ARGS[@]}"}")
    local positionals=()
    local parse_positionals=false
    local arg

    # Bash 3.2 + set -u throws on iterating an empty array with "${arr[@]}".
    # No push args means no explicit refspec, so use current git branch.
    if [[ "${#args[@]}" -eq 0 ]]; then
        _get_current_git_branch || return 1
        return 0
    fi

    # Support common push syntax: git push [options] [remote] [refspec]
    for arg in "${args[@]}"; do
        if [[ "$arg" == "--" ]]; then
            parse_positionals=true
            continue
        fi
        if [[ "$parse_positionals" == "false" && "$arg" == -* ]]; then
            continue
        fi
        positionals+=("$arg")
    done

    # Branch/refspec is positional #2 when present.
    if [[ "${#positionals[@]}" -ge 2 ]]; then
        _normalize_branch_ref "${positionals[1]}" || return 1
        return 0
    fi

    _get_current_git_branch || return 1
}

_resolve_effective_job_name() {
    local requested_job_name="$1"
    local command_mode="${2:-status}"

    local top_job_name="$requested_job_name"
    local explicit_branch_name=""
    if [[ "$requested_job_name" == */* ]]; then
        top_job_name="${requested_job_name%%/*}"
        explicit_branch_name="${requested_job_name#*/}"
    fi

    if [[ -z "$top_job_name" ]]; then
        bg_log_error "Invalid Jenkins job name: '${requested_job_name}'"
        return 1
    fi

    local job_type
    job_type=$(get_jenkins_job_type "$top_job_name")
    if [[ "$job_type" == "unknown" || -z "$job_type" ]]; then
        # Backward-compatible fallback for Jenkins instances where _class
        # cannot be resolved from the API response.
        if [[ -n "$explicit_branch_name" ]]; then
            bg_log_error "Jenkins job '${requested_job_name}' not found"
            return 1
        fi
        echo "$top_job_name"
        return 0
    fi

    if [[ -n "$explicit_branch_name" ]]; then
        if [[ "$job_type" != "multibranch" ]]; then
            bg_log_error "Jenkins job '${requested_job_name}' not found"
            return 1
        fi
        if ! multibranch_branch_exists "$top_job_name" "$explicit_branch_name"; then
            bg_log_error "Branch '${explicit_branch_name}' not found in multibranch job '${top_job_name}'. Push the branch and wait for Jenkins to scan."
            return 1
        fi
        echo "${top_job_name}/${explicit_branch_name}"
        return 0
    fi

    if [[ "$job_type" == "multibranch" ]]; then
        if [[ "${STATUS_PROBE_ALL:-false}" == "true" && "$command_mode" == "status" ]]; then
            echo "$top_job_name"
            return 0
        fi

        local inferred_branch=""
        case "$command_mode" in
            push)
                inferred_branch=$(_infer_push_branch_from_args) || true
                ;;
            status|build)
                inferred_branch=$(_get_current_git_branch) || true
                ;;
            *)
                inferred_branch=$(_get_current_git_branch) || true
                ;;
        esac

        if [[ -z "$inferred_branch" ]]; then
            bg_log_error "Could not determine git branch for multibranch job '${top_job_name}'"
            return 1
        fi
        if ! multibranch_branch_exists "$top_job_name" "$inferred_branch"; then
            bg_log_error "Branch '${inferred_branch}' not found in multibranch job '${top_job_name}'. Push the branch and wait for Jenkins to scan."
            return 1
        fi
        echo "${top_job_name}/${inferred_branch}"
        return 0
    fi

    echo "$top_job_name"
}

_fetch_multibranch_baselines() {
    local top_job_name="$1"
    local job_path response

    job_path=$(jenkins_job_path "$top_job_name")
    response=$(jenkins_api "${job_path}/api/json?tree=jobs[name,lastBuild[number]]")

    echo "$response" | jq '[.jobs[]? | {key: .name, value: (.lastBuild.number // 0)}] | from_entries'
}

# Validate Jenkins environment, resolve job name, verify connectivity
# Usage: _validate_jenkins_setup "context-for-errors"
# Sets: _VALIDATED_JOB_NAME
# Returns: 0 on success, 1 on failure (with appropriate error messages)
_validate_jenkins_setup() {
    local context="$1"  # e.g., "monitor Jenkins builds", "trigger Jenkins build"
    local command_mode="${2:-status}"

    if ! validate_dependencies; then
        bg_log_error "Cannot ${context} - missing dependencies (jq, curl)"
        bg_log_essential "Suggestion: Install jq and curl, then retry"
        return 1
    fi

    if ! validate_environment; then
        bg_log_error "Cannot ${context} - environment not configured"
        bg_log_essential "Suggestion: Set JENKINS_URL, JENKINS_USER_ID, and JENKINS_API_TOKEN"
        return 1
    fi

    if [[ -n "$JOB_NAME" ]]; then
        _VALIDATED_JOB_NAME="$JOB_NAME"
        bg_log_info "Using specified job: $_VALIDATED_JOB_NAME"
    else
        bg_log_info "Discovering Jenkins job name..."
        if ! _VALIDATED_JOB_NAME=$(discover_job_name); then
            bg_log_error "Cannot ${context} - could not determine job name"
            bg_log_essential "Suggestion: Use -j/--job to specify job name"
            return 1
        fi
        bg_log_success "Job name: $_VALIDATED_JOB_NAME"
    fi

    bg_log_info "Verifying Jenkins connectivity..."
    if ! verify_jenkins_connection; then
        bg_log_error "Cannot ${context} - cannot connect to Jenkins"
        bg_log_essential "Suggestion: Check JENKINS_URL and credentials"
        return 1
    fi

    if ! _VALIDATED_JOB_NAME=$(_resolve_effective_job_name "$_VALIDATED_JOB_NAME" "$command_mode"); then
        bg_log_error "Cannot ${context} - could not resolve Jenkins job"
        bg_log_essential "Suggestion: Verify --job value and git branch"
        return 1
    fi

    if ! verify_job_exists "$_VALIDATED_JOB_NAME"; then
        bg_log_error "Cannot ${context} - job not found: $_VALIDATED_JOB_NAME"
        bg_log_essential "Suggestion: Verify job name with -j/--job option"
        return 1
    fi

    return 0
}

# Status command handler
# Displays Jenkins build status
# Spec reference: buildgit-spec.md, buildgit status
# Error handling: buildgit-spec.md, Error Handling section
cmd_status() {
    # Parse status-specific options
    _parse_status_options "$@"

    # Validate incompatible option combinations for --format
    if [[ "${STATUS_FORMAT_EXPLICIT:-false}" == "true" && "$STATUS_JSON_MODE" == "true" ]]; then
        _usage_error "cannot combine --format with --json"
    fi
    if [[ "${STATUS_FORMAT_EXPLICIT:-false}" == "true" && "$STATUS_ALL_MODE" == "true" ]]; then
        _usage_error "cannot combine --format with --all"
    fi

    # Validate incompatible option combinations for --line mode
    if [[ "$STATUS_LINE_MODE" == "true" && "$STATUS_ALL_MODE" == "true" ]]; then
        _usage_error "Cannot use --line with --all"
    fi
    if [[ "$STATUS_LINE_MODE" == "true" && "$STATUS_JSON_MODE" == "true" ]]; then
        _usage_error "Cannot use --line with --json"
    fi
    if [[ "$STATUS_ONCE_MODE" == "true" && "$STATUS_FOLLOW_MODE" != "true" ]]; then
        _usage_error "Error: --once requires --follow (-f)"
    fi
    if [[ "${STATUS_PROBE_ALL:-false}" == "true" && "$STATUS_FOLLOW_MODE" != "true" ]]; then
        _usage_error "Error: --probe-all requires --follow (-f)"
    fi
    if [[ "${STATUS_PROBE_ALL:-false}" == "true" && -n "${JOB_NAME:-}" && "$JOB_NAME" == */* ]]; then
        _usage_error "Error: --probe-all requires a top-level multibranch job name, not an explicit branch job"
    fi
    if [[ "${STATUS_N_SET:-false}" == "true" && -n "$STATUS_BUILD_NUMBER" ]]; then
        _usage_error "Cannot combine a build number with -n"
    fi

    # Validate incompatible options: follow + build number
    if [[ "$STATUS_FOLLOW_MODE" == "true" && -n "$STATUS_BUILD_NUMBER" ]]; then
        _usage_error "Cannot use --follow with a specific build number"
    fi

    # For follow mode, jump straight to Jenkins monitoring
    if [[ "$STATUS_FOLLOW_MODE" == "true" ]]; then
        if [[ "${STATUS_PRIOR_JOBS_EXPLICIT:-false}" != "true" ]]; then
            STATUS_PRIOR_JOBS=3
        fi

        # Validate and setup Jenkins connection
        if ! _validate_jenkins_setup "monitor Jenkins builds" "status"; then
            return 1
        fi

        if [[ "${STATUS_PROBE_ALL:-false}" == "true" ]]; then
            local probe_job_name="${_VALIDATED_JOB_NAME%%/*}"
            local probe_job_type
            probe_job_type=$(get_jenkins_job_type "$probe_job_name")
            if [[ "$probe_job_type" != "multibranch" ]]; then
                bg_log_warning "--probe-all is only supported for multibranch pipeline jobs; falling back to normal follow mode for '${_VALIDATED_JOB_NAME}'"
                STATUS_PROBE_ALL=false
            fi
        fi

        # Display N prior completed builds before entering follow mode (if -n specified)
        if [[ "${STATUS_N_SET:-false}" == "true" ]]; then
            _display_n_prior_builds "$_VALIDATED_JOB_NAME" "$STATUS_LINE_COUNT" "$STATUS_LINE_MODE" "$STATUS_NO_TESTS"
        fi

        # Enter follow mode loop (never returns normally)
        _cmd_status_follow "$_VALIDATED_JOB_NAME" "$STATUS_JSON_MODE" "$STATUS_ONCE_MODE" "$STATUS_ONCE_TIMEOUT" "$STATUS_LINE_MODE" "$STATUS_NO_TESTS" "$STATUS_PRIOR_JOBS" "$STATUS_PROBE_ALL"
        # Should not reach here
        return 0
    fi

    # -------------------------------------------------------------------------
    # Display Jenkins build status
    # -------------------------------------------------------------------------
    if ! _validate_jenkins_setup "check Jenkins status" "status"; then
        return 1
    fi

    local resolved_status_build_number=""
    if ! resolved_status_build_number=$(_resolve_status_build_number "$_VALIDATED_JOB_NAME" "$STATUS_BUILD_NUMBER"); then
        return 1
    fi

    # JSON mode always uses structured output path
    if [[ "$STATUS_JSON_MODE" == "true" ]]; then
        if [[ "${STATUS_N_SET:-false}" == "true" ]]; then
            _status_multi_build_check "$_VALIDATED_JOB_NAME" "$resolved_status_build_number" "$STATUS_LINE_COUNT" "true"
            return $?
        fi
        _jenkins_status_check "$_VALIDATED_JOB_NAME" "$STATUS_JSON_MODE" "$resolved_status_build_number"
        return $?
    fi

    # Determine output mode for status snapshots.
    # Default: one-line output (full output only with --all).
    local use_line_mode="$STATUS_LINE_MODE"
    local line_count="$STATUS_LINE_COUNT"
    if [[ "$STATUS_LINE_MODE" != "true" && "$STATUS_ALL_MODE" != "true" && "${STATUS_N_SET:-false}" != "true" ]]; then
        use_line_mode=true
        line_count="1"
    fi
    if [[ "$STATUS_LINE_MODE" != "true" && "$STATUS_ALL_MODE" != "true" && "${STATUS_N_SET:-false}" == "true" ]]; then
        use_line_mode=true
    fi

    if [[ "$use_line_mode" == "true" ]]; then
        _status_line_check "$_VALIDATED_JOB_NAME" "$resolved_status_build_number" "$line_count" "$STATUS_NO_TESTS" "$STATUS_PRIOR_JOBS"
        return $?
    fi

    if [[ "${STATUS_N_SET:-false}" == "true" ]]; then
        _status_multi_build_check "$_VALIDATED_JOB_NAME" "$resolved_status_build_number" "$line_count" "false" "$STATUS_PRIOR_JOBS" "$STATUS_NO_TESTS"
        return $?
    fi

    if [[ "$STATUS_PRIOR_JOBS" -gt 0 ]]; then
        local target_build_number="$resolved_status_build_number"
        if [[ -z "$target_build_number" ]]; then
            target_build_number=$(get_last_build_number "$_VALIDATED_JOB_NAME")
        fi
        if [[ "$target_build_number" =~ ^[0-9]+$ && "$target_build_number" -gt 0 ]]; then
            _display_prior_jobs_block "$_VALIDATED_JOB_NAME" "$STATUS_PRIOR_JOBS" "$STATUS_NO_TESTS" "$((target_build_number - 1))"
        fi
    fi

    _jenkins_status_check "$_VALIDATED_JOB_NAME" "$STATUS_JSON_MODE" "$resolved_status_build_number"
}

# =============================================================================
# Push Command Implementation
# =============================================================================

# Parse push command options
# Separates buildgit options (--no-follow) from git push options
# Sets: PUSH_NO_FOLLOW, PUSH_GIT_ARGS
_parse_push_options() {
    PUSH_NO_FOLLOW=false
    PUSH_LINE_MODE=false
    PUSH_PRIOR_JOBS=3
    PUSH_GIT_ARGS=()
    _LINE_FORMAT_STRING="$_DEFAULT_LINE_FORMAT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-follow)
                PUSH_NO_FOLLOW=true
                shift
                ;;
            --line)
                PUSH_LINE_MODE=true
                shift
                ;;
            --format)
                shift
                if [[ -z "${1:-}" ]]; then
                    _usage_error "--format requires a format string argument"
                fi
                _LINE_FORMAT_STRING="$1"
                PUSH_LINE_MODE=true
                shift
                ;;
            --format=*)
                _LINE_FORMAT_STRING="${1#--format=}"
                PUSH_LINE_MODE=true
                shift
                ;;
            --prior-jobs)
                shift
                PUSH_PRIOR_JOBS=$(_parse_prior_jobs_value "${1:-}" "--prior-jobs")
                shift
                ;;
            --prior-jobs=*)
                PUSH_PRIOR_JOBS=$(_parse_prior_jobs_value "${1#--prior-jobs=}" "--prior-jobs")
                shift
                ;;
            *)
                # Pass through to git push
                PUSH_GIT_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# Wait for a new build to start
# Usage: _wait_for_build_start "job-name" "baseline-build-number" ["queue-url"]
# When queue_url is provided, tries the queue API first (for triggered builds).
# Otherwise, or on queue API failure, falls back to polling by build number.
# Returns: new build number on stdout, 1 on timeout
_QUEUE_WAIT_LINE_ACTIVE=false
_QUEUE_WAIT_LAST_MESSAGE=""
_QUEUE_WAIT_STICKY_LINE_COUNT=0

_queue_wait_phase_prefix() {
    local why="$1"
    if [[ -z "$why" ]]; then
        echo ""
        return 0
    fi
    if [[ "$why" =~ ^([^0-9]*)[0-9].*$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$why"
    fi
}

_redraw_queue_wait_sticky_lines() {
    local old_count="${_QUEUE_WAIT_STICKY_LINE_COUNT:-0}"
    local new_lines=("$@")
    local new_count="${#new_lines[@]}"
    local max_count="$old_count"
    if [[ "$new_count" -gt "$max_count" ]]; then
        max_count="$new_count"
    fi
    if [[ "$max_count" -le 0 ]]; then
        return 0
    fi

    local payload=""
    if [[ "$old_count" -gt 0 ]]; then
        payload+=$'\r'
        if [[ "$old_count" -gt 1 ]]; then
            payload+=$(printf '\033[%sA' "$((old_count - 1))")
        fi
    fi

    local idx
    for ((idx=0; idx<max_count; idx++)); do
        local line=""
        if [[ "$idx" -lt "$new_count" ]]; then
            line="${new_lines[$idx]}"
        fi
        payload+=$'\033[K'"$line"
        if [[ "$idx" -lt $((max_count - 1)) ]]; then
            payload+=$'\n'
        fi
    done

    if [[ "$old_count" -gt "$new_count" && "$new_count" -gt 0 ]]; then
        payload+=$(printf '\033[%sA' "$((old_count - new_count))")
    fi

    printf '%b' "$payload" >&2
    _QUEUE_WAIT_STICKY_LINE_COUNT="$new_count"
}

_clear_queue_wait_status() {
    local old_count="${_QUEUE_WAIT_STICKY_LINE_COUNT:-0}"
    if [[ "$old_count" -gt 0 ]]; then
        local payload=$'\r'
        if [[ "$old_count" -gt 1 ]]; then
            payload+=$(printf '\033[%sA' "$((old_count - 1))")
        fi

        local idx
        for ((idx=0; idx<old_count; idx++)); do
            payload+=$'\033[K'
            if [[ "$idx" -lt $((old_count - 1)) ]]; then
                payload+=$'\n'
            fi
        done

        if [[ "$old_count" -gt 1 ]]; then
            payload+=$(printf '\033[%sA' "$((old_count - 1))")
        fi
        payload+=$'\r'
        printf '%b' "$payload" >&2
        _QUEUE_WAIT_STICKY_LINE_COUNT=0
        _QUEUE_WAIT_LINE_ACTIVE=false
        _QUEUE_WAIT_LAST_MESSAGE=""
    fi
}

_queue_item_path_from_url() {
    local queue_url="$1"
    if [[ "$queue_url" =~ /queue/item/([0-9]+) ]]; then
        echo "/queue/item/${BASH_REMATCH[1]}/api/json"
        return 0
    fi
    echo ""
}

_get_queue_item_for_job() {
    local job_name="$1"
    local queue_response
    queue_response=$(jenkins_api "/queue/api/json" 2>/dev/null) || true
    if [[ -z "$queue_response" ]]; then
        echo ""
        return 0
    fi

    echo "$queue_response" | jq -c --arg job "$job_name" '
        [.items[]?
         | select((.task.name // "") == $job)
         | select((.cancelled // false) != true)
        ]
        | sort_by(.inQueueSince // 0)
        | .[0] // empty
    ' 2>/dev/null || echo ""
}

_WAIT_FOR_BUILD_RESULT=""

_wait_for_build_start() {
    local job_name="$1"
    local baseline="$2"
    local queue_url="${3:-}"
    _WAIT_FOR_BUILD_RESULT=""
    local build_start_timeout="${BUILD_START_TIMEOUT:-120}"
    local queue_item_path queue_confirmed=false elapsed=0
    local pending_build_number=$((baseline + 1))
    local queue_detected=false
    local last_queue_phase=""
    local last_non_tty_log_epoch=0
    local queue_frame=0
    local queue_estimate_ms=""

    bg_log_progress "Waiting for Jenkins build $job_name to start..."

    queue_item_path=$(_queue_item_path_from_url "$queue_url")
    if _status_stdout_is_tty; then
        queue_estimate_ms=$(_get_last_successful_build_duration "$job_name")
    fi

    while true; do
        local current
        current=$(get_last_build_number "$job_name")

        if [[ "$current" -gt "$baseline" ]]; then
            _clear_queue_wait_status
            bg_log_success "Build #${current} started"
            _WAIT_FOR_BUILD_RESULT="$current"
            return 0
        fi

        local queue_item_json=""
        if [[ -n "$queue_item_path" ]]; then
            queue_item_json=$(jenkins_api "$queue_item_path" 2>/dev/null) || true
        fi
        if [[ -z "$queue_item_json" ]]; then
            queue_item_json=$(_get_queue_item_for_job "$job_name")
        fi

        if [[ -n "$queue_item_json" ]]; then
            local queue_cancelled
            queue_cancelled=$(echo "$queue_item_json" | jq -r '.cancelled // false' 2>/dev/null) || queue_cancelled=false
            if [[ "$queue_cancelled" == "true" ]]; then
                _clear_queue_wait_status
                bg_log_error "Build was cancelled while in queue"
                return 1
            fi

            queue_confirmed=true
            local executable_number
            executable_number=$(echo "$queue_item_json" | jq -r '.executable.number // empty' 2>/dev/null) || executable_number=""
            if [[ -n "$executable_number" && "$executable_number" != "null" ]]; then
                _clear_queue_wait_status
                bg_log_success "Build #${executable_number} started"
                _WAIT_FOR_BUILD_RESULT="$executable_number"
                return 0
            fi

            local queue_why
            queue_why=$(echo "$queue_item_json" | jq -r '.why // empty' 2>/dev/null) || queue_why=""
            local queue_msg="Build #${pending_build_number} is QUEUED"
            if [[ -n "$queue_why" ]]; then
                queue_msg+=" — ${queue_why}"
            fi

            local queue_phase
            queue_phase=$(_queue_wait_phase_prefix "$queue_why")
            local is_transition=false
            if [[ "$queue_detected" != "true" || "$queue_phase" != "$last_queue_phase" ]]; then
                is_transition=true
            fi

            if _status_stdout_is_tty; then
                if [[ "$queue_detected" != "true" ]]; then
                    _clear_queue_wait_status
                    log_info "Build #${pending_build_number} is QUEUED"
                elif [[ "$is_transition" == "true" && -n "$queue_why" ]]; then
                    _clear_queue_wait_status
                    log_info "Build #${pending_build_number} is QUEUED — ${queue_why}"
                fi

                local sticky_lines=()
                local running_build_number=""
                if [[ "$queue_why" =~ Build\ \#([0-9]+)\ is\ already\ in\ progress ]]; then
                    running_build_number="${BASH_REMATCH[1]}"
                fi
                if [[ -n "$running_build_number" ]]; then
                    local running_build_json running_building running_timestamp
                    running_build_json=$(get_build_info "$job_name" "$running_build_number")
                    if [[ -n "$running_build_json" ]]; then
                        running_building=$(echo "$running_build_json" | jq -r '.building // false' 2>/dev/null) || running_building=false
                        if [[ "$running_building" == "true" ]]; then
                            running_timestamp=$(echo "$running_build_json" | jq -r '.timestamp // 0' 2>/dev/null) || running_timestamp=0
                            sticky_lines+=("$(_render_follow_line_in_progress "$job_name" "$running_build_number" "$running_timestamp" "$queue_estimate_ms" "$queue_frame")")
                        fi
                    fi
                fi
                local in_queue_since_ms
                in_queue_since_ms=$(echo "$queue_item_json" | jq -r '.inQueueSince // 0' 2>/dev/null) || in_queue_since_ms=0
                sticky_lines+=("$(_render_follow_line_queued "$job_name" "$pending_build_number" "$in_queue_since_ms" "$queue_estimate_ms" "$queue_frame")")
                _redraw_queue_wait_sticky_lines "${sticky_lines[@]}"
            else
                local now_epoch
                now_epoch=$(date +%s)
                if [[ "$is_transition" == "true" || $((now_epoch - last_non_tty_log_epoch)) -ge 30 ]]; then
                    log_info "$queue_msg"
                    last_non_tty_log_epoch="$now_epoch"
                fi
            fi

            queue_detected=true
            last_queue_phase="$queue_phase"
        fi

        if [[ "$queue_confirmed" != "true" ]]; then
            if [[ "$elapsed" -ge "$build_start_timeout" ]]; then
                _clear_queue_wait_status
                bg_log_error "Timeout: No build started within ${build_start_timeout} seconds"
                return 1
            fi
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        queue_frame=$((queue_frame + 1))
    done
}

_stage_state_settle_fingerprint() {
    local stage_state="$1"

    echo "$stage_state" | jq -cS '
        del(
            .parallel_state[]?.stable_polls,
            .parallel_state[]?.wrapper_stable_polls,
            .parallel_state[]?.branch_state[]?.stable_polls
        )
    ' 2>/dev/null || echo "$stage_state"
}

# Monitor push-triggered build until completion
# Arguments: job_name, build_number
# Returns: 0 on success, 1 on failure
# _push_monitor_build removed - consolidated into _monitor_build()
# Spec: unify-follow-log-spec.md, Implementation Requirements

# Display build result after push
# Arguments: job_name, build_number
# Returns: 0 if build succeeded, 1 otherwise
# Handle build completion display (unified format)
# Called after _monitor_build() returns 0
# Shows test results (if failed/unstable) and "Finished: STATUS" line
# Arguments: job_name, build_number
# Returns: 0 for SUCCESS, 1 for FAILURE/UNSTABLE/other
# Spec: unify-follow-log-spec.md, Section 4 (Build Completion)
_handle_build_completion() {
    local job_name="$1"
    local build_number="$2"

    # Fetch final build info
    local build_json
    build_json=$(get_build_info "$job_name" "$build_number")
    local result
    result=$(echo "$build_json" | jq -r '.result // "UNKNOWN"')

    # Display failure details if applicable (any non-SUCCESS result)
    # Spec: refactor-shared-failure-diagnostics-spec.md
    if [[ "$result" != "SUCCESS" ]]; then
        local console_output
        console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || true

        # Failure diagnostics (shared)
        _display_failure_diagnostics "$job_name" "$build_number" "$console_output"
    else
        # Display test results for SUCCESS builds
        # Spec: show-test-results-always-spec.md, Section 1.2
        local test_results_json test_results_rc=0
        if test_results_json=$(fetch_test_results "$job_name" "$build_number"); then
            test_results_rc=0
        else
            test_results_rc=$?
            test_results_json=""
        fi
        if [[ "$test_results_rc" -eq 2 ]]; then
            _note_test_results_comm_failure "$job_name" "$build_number"
            display_test_results_comm_error
        else
            display_test_results "$test_results_json"
        fi
    fi

    # Print final status line
    echo ""
    print_finished_line "$result"

    # Print duration
    # Spec: bug-build-monitoring-header-spec.md
    local duration_ms
    duration_ms=$(echo "$build_json" | jq -r '.duration // 0')
    if [[ "$duration_ms" != "0" && "$duration_ms" =~ ^[0-9]+$ ]]; then
        log_info "Duration: $(format_duration "$duration_ms")"
    fi

    # Return appropriate exit code
    if [[ "$result" == "SUCCESS" ]]; then
        return 0
    else
        return 1
    fi
}

# Resolve local HEAD commit context for push-triggered builds.
# Outputs two lines:
#   line 1: short SHA (or "unknown")
#   line 2: subject line message (or empty)
_get_local_head_commit_context() {
    local sha="unknown"
    local msg=""

    if sha=$(git rev-parse --short=7 HEAD 2>/dev/null); then
        msg=$(git log -1 --pretty=%s 2>/dev/null || true)
        echo "$sha"
        echo "$msg"
        return 0
    fi

    echo "unknown"
    echo ""
}

# Push command handler
# Pushes commits and monitors the resulting Jenkins build
# Spec reference: buildgit-spec.md, buildgit push
# Error handling: buildgit-spec.md, Error Handling section
