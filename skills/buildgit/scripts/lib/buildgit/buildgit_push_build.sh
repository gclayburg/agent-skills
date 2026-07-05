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
        local console_output
        console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || true

        local collected_results collected_rc=0
        if collected_results=$(collect_downstream_test_results "$job_name" "$build_number" "$console_output"); then
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

_parse_push_hook_signal() {
    local git_output="$1"
    local line normalized started_build_number="" cancelled_item="" cancelled_why="" queued_url=""

    while IFS= read -r line; do
        normalized="$line"
        if [[ "$normalized" =~ ^[[:space:]]*remote:[[:space:]]*(.*)$ ]]; then
            normalized="${BASH_REMATCH[1]}"
        else
            normalized="${normalized#"${normalized%%[![:space:]]*}"}"
        fi

        if [[ "$normalized" =~ ^Build[[:space:]]+started:[[:space:]]+(https?://[^[:space:]]+)[[:space:]]*$ ]]; then
            local build_url="${BASH_REMATCH[1]}"
            if [[ "$build_url" =~ /([0-9]+)/?$ ]]; then
                started_build_number="${BASH_REMATCH[1]}"
            fi
            continue
        fi

        if [[ "$normalized" =~ ^WARNING:[[:space:]]+Queue[[:space:]]+item[[:space:]]+([0-9]+)[[:space:]]+was[[:space:]]+CANCELLED(.*)$ ]]; then
            cancelled_item="${BASH_REMATCH[1]}"
            cancelled_why="${BASH_REMATCH[2]}"
            cancelled_why="${cancelled_why#"${cancelled_why%%[![:space:]]*}"}"
            continue
        fi

        if [[ "$normalized" =~ ^Build[[:space:]]+queued:[[:space:]]+(https?://[^[:space:]]*/queue/item/[0-9]+/?)[[:space:]]*$ ]]; then
            queued_url="${BASH_REMATCH[1]}"
        fi
    done <<< "$git_output"

    if [[ -n "$started_build_number" ]]; then
        echo "started:${started_build_number}"
    elif [[ -n "$cancelled_item" ]]; then
        echo "cancelled:${cancelled_item}:${cancelled_why}"
    elif [[ -n "$queued_url" ]]; then
        echo "queued:${queued_url}"
    fi
}

_emit_push_queue_timeout_diagnostics() {
    local job_name="$1"
    local baseline_build="$2"
    local queue_url="$3"
    local last_build queue_path queue_response http_code queue_body queue_status="network error"
    local cancelled="" why="" executable_number=""

    bg_log_error "Post-receive hook queue diagnostics:"
    echo "  Job polled: ${job_name}" >&2
    echo "  Baseline build: #${baseline_build}" >&2

    last_build=$(get_last_build_number "$job_name" 2>/dev/null) || last_build="unknown"
    [[ -n "$last_build" ]] || last_build="unknown"
    echo "  Observed lastBuild.number: ${last_build}" >&2

    queue_path=$(_queue_item_path_from_url "$queue_url")
    if [[ -n "$queue_path" ]]; then
        if queue_response=$(jenkins_api_with_status "$queue_path" 2>&1); then
            :
        else
            :
        fi
        if [[ "$queue_response" == *$'\n'* ]]; then
            http_code="${queue_response##*$'\n'}"
            queue_body="${queue_response%$'\n'*}"
        else
            http_code="$queue_response"
            queue_body=""
        fi

        if [[ "$http_code" == "200" ]]; then
            queue_status="200 OK"
        elif [[ "$http_code" =~ ^[0-9][0-9][0-9]$ && "$http_code" != "000" ]]; then
            local body_snippet
            body_snippet=$(printf '%s' "$queue_body" | tr '\n' ' ')
            body_snippet="${body_snippet:0:200}"
            queue_status="HTTP ${http_code}"
            if [[ -n "$body_snippet" ]]; then
                queue_status="${queue_status}: ${body_snippet}"
            fi
        else
            queue_status="network error"
            if [[ -n "$queue_response" ]]; then
                local error_snippet
                error_snippet=$(printf '%s' "$queue_response" | tr '\n' ' ')
                error_snippet="${error_snippet:0:200}"
                queue_status="${queue_status}: ${error_snippet}"
            fi
        fi

        if [[ -n "$queue_body" ]]; then
            cancelled=$(printf '%s' "$queue_body" | jq -r '.cancelled // empty' 2>/dev/null) || cancelled=""
            why=$(printf '%s' "$queue_body" | jq -r '.why // empty' 2>/dev/null) || why=""
            executable_number=$(printf '%s' "$queue_body" | jq -r '.executable.number // empty' 2>/dev/null) || executable_number=""
        fi
        if [[ -z "$cancelled" ]]; then
            cancelled=$(printf '%s' "$queue_response" | grep -o '"cancelled":[^,}]*' | head -n 1 | cut -d: -f2 | tr -d ' "') || cancelled=""
        fi
        if [[ -z "$why" ]]; then
            why=$(printf '%s' "$queue_response" | grep -o '"why":"[^"]*"' | head -n 1 | cut -d'"' -f4) || why=""
        fi
        if [[ -z "$executable_number" ]]; then
            executable_number=$(printf '%s' "$queue_response" | grep -o '"number":[0-9]*' | head -n 1 | cut -d: -f2) || executable_number=""
        fi
    fi

    echo "  Queue item probe: ${queue_status}" >&2
    echo "  Queue cancelled: ${cancelled:-unknown}" >&2
    echo "  Queue why: ${why:-unknown}" >&2
    echo "  Queue executable.number: ${executable_number:-unknown}" >&2
}

cmd_push() {
    # Parse push-specific options
    _parse_push_options "$@"

    # -------------------------------------------------------------------------
    # Part 1: Execute git push
    # -------------------------------------------------------------------------
    bg_log_info "Pushing to remote..."

    # Capture git push output and exit code
    local git_output
    local git_exit_code=0
    git_output=$(git push "${PUSH_GIT_ARGS[@]+"${PUSH_GIT_ARGS[@]}"}" 2>&1) || git_exit_code=$?

    # Always display git push output (essential output)
    if [[ -n "$git_output" ]]; then
        bg_log_essential "$git_output"
    fi

    # If git push failed, exit with git's exit code
    # Spec: Git command fails - return git's exit code
    if [[ $git_exit_code -ne 0 ]]; then
        return $git_exit_code
    fi

    # Check if there was nothing to push
    # Git push returns 0 with "Everything up-to-date" when nothing to push
    if [[ "$git_output" == *"Everything up-to-date"* ]]; then
        bg_log_info "Nothing to push"
        return 0
    fi

    # -------------------------------------------------------------------------
    # Part 2: If --no-follow, exit after push
    # -------------------------------------------------------------------------
    if [[ "$PUSH_NO_FOLLOW" == "true" ]]; then
        # Use essential output since this confirms the user's explicit request
        bg_log_essential "Push completed (monitoring disabled)"
        return 0
    fi

    # -------------------------------------------------------------------------
    # Part 3: Monitor Jenkins build
    # -------------------------------------------------------------------------
    # Spec: Jenkins Unavailable - Complete git push (done above), then show Jenkins error
    if ! _validate_jenkins_setup "monitor Jenkins build" "push"; then
        bg_log_success "Git push completed successfully"
        return 1
    fi
    local job_name="$_VALIDATED_JOB_NAME"

    # Record baseline build number
    local baseline_build
    baseline_build=$(get_last_build_number "$job_name")
    bg_log_info "Current build baseline: #${baseline_build}"

    local hook_signal hook_kind hook_value hook_detail queue_url=""
    hook_signal=$(_parse_push_hook_signal "$git_output")
    hook_kind="${hook_signal%%:*}"
    hook_value="${hook_signal#*:}"

    if [[ "$hook_kind" == "started" && "$hook_signal" != "$hook_kind" ]]; then
        local new_build_number="$hook_value"
        baseline_build=$((new_build_number - 1))
        bg_log_progress "Build #${new_build_number} already started (reported by post-receive hook)"
        _display_monitoring_preamble "$job_name" "$PUSH_PRIOR_JOBS" "false" "$baseline_build"
        log_info "Starting"

        if [[ "$PUSH_LINE_MODE" == "true" ]]; then
            if _monitor_build_line_mode "$job_name" "$new_build_number" "false" "true"; then
                return 0
            fi
            return 1
        fi

        local push_commit_info push_commit_sha push_commit_msg push_correlation_status
        push_commit_info=$(_get_local_head_commit_context)
        push_commit_sha=$(echo "$push_commit_info" | head -1)
        push_commit_msg=$(echo "$push_commit_info" | tail -1)
        push_correlation_status=$(correlate_commit "$push_commit_sha")

        _display_build_in_progress_banner "$job_name" "$new_build_number" "" \
            "$push_commit_sha" "$push_commit_msg" "$push_correlation_status"

        if ! _monitor_build "$job_name" "$new_build_number" "true" "true"; then
            bg_log_error "Build monitoring interrupted or timed out"
            local console_url
            console_url=$(jenkins_console_url "$job_name" "$new_build_number")
            if [[ -n "$console_url" ]]; then
                bg_log_essential "Suggestion: Check Jenkins console at ${console_url}"
            fi
            return 1
        fi

        echo ""
        _handle_build_completion "$job_name" "$new_build_number"
        return $?
    fi

    if [[ "$hook_kind" == "cancelled" && "$hook_signal" != "$hook_kind" ]]; then
        hook_value="${hook_signal#cancelled:}"
        hook_detail="${hook_value#*:}"
        hook_value="${hook_value%%:*}"
        if [[ -n "$hook_detail" && "$hook_detail" != "$hook_value" ]]; then
            bg_log_error "Jenkins queue item ${hook_value} was cancelled by the post-receive hook (${hook_detail})"
        else
            bg_log_error "Jenkins queue item ${hook_value} was cancelled by the post-receive hook"
        fi
        return 1
    fi

    if [[ "$hook_kind" == "queued" && "$hook_signal" != "$hook_kind" ]]; then
        queue_url="$hook_value"
    fi

    # Wait for new build to start
    if ! _wait_for_build_start "$job_name" "$baseline_build" "$queue_url"; then
        if [[ -n "$queue_url" ]]; then
            _emit_push_queue_timeout_diagnostics "$job_name" "$baseline_build" "$queue_url" || true
        fi
        bg_log_success "Git push completed successfully"
        bg_log_error "Jenkins build monitoring failed - no build started"
        bg_log_essential "Suggestion: Check Jenkins webhook/SCM polling configuration"
        return 1
    fi
    local new_build_number="$_WAIT_FOR_BUILD_RESULT"

    _display_monitoring_preamble "$job_name" "$PUSH_PRIOR_JOBS" "false" "$((new_build_number - 1))"
    log_info "Starting"

    # Display unified build header before monitoring
    # Spec: unify-follow-log-spec.md, Section 5 (buildgit push)
    if [[ "$PUSH_LINE_MODE" == "true" ]]; then
        if _monitor_build_line_mode "$job_name" "$new_build_number" "false" "true"; then
            return 0
        fi
        return 1
    fi

    local push_commit_info push_commit_sha push_commit_msg push_correlation_status
    push_commit_info=$(_get_local_head_commit_context)
    push_commit_sha=$(echo "$push_commit_info" | head -1)
    push_commit_msg=$(echo "$push_commit_info" | tail -1)
    push_correlation_status=$(correlate_commit "$push_commit_sha")

    _display_build_in_progress_banner "$job_name" "$new_build_number" "" \
        "$push_commit_sha" "$push_commit_msg" "$push_correlation_status"

    # Monitor build until completion
    if ! _monitor_build "$job_name" "$new_build_number" "true" "true"; then
        bg_log_error "Build monitoring interrupted or timed out"
        local console_url
        console_url=$(jenkins_console_url "$job_name" "$new_build_number")
        if [[ -n "$console_url" ]]; then
            bg_log_essential "Suggestion: Check Jenkins console at ${console_url}"
        fi
        return 1
    fi

    # Display build result (blank line separator)
    echo ""
    _handle_build_completion "$job_name" "$new_build_number"
}

cmd_build() {
    # Parse build-specific options (exits on error or -h/--help)
    _parse_build_options "$@"

    # -------------------------------------------------------------------------
    # Part 1: Validate environment, connection, and resolve job name
    # -------------------------------------------------------------------------
    # Spec: Jenkins Unavailable for build - Fail immediately with descriptive error
    if ! _validate_jenkins_setup "trigger Jenkins build" "build"; then
        return 1
    fi
    local job_name="$_VALIDATED_JOB_NAME"

    local baseline_build
    baseline_build=$(get_last_build_number "$job_name")

    # -------------------------------------------------------------------------
    # Part 2: Trigger the build
    # -------------------------------------------------------------------------
    bg_log_info "Triggering build for job '$job_name'..."

    local queue_url
    if ! queue_url=$(trigger_build "$job_name"); then
        bg_log_error "Failed to trigger build for job '$job_name'"
        bg_log_essential "Suggestion: Check Jenkins permissions - user may need 'Build' permission for this job"
        return 1
    fi

    bg_log_success "Build triggered successfully"

    # -------------------------------------------------------------------------
    # Part 4: Handle --no-follow mode
    # -------------------------------------------------------------------------
    if [[ "$BUILD_NO_FOLLOW" == "true" ]]; then
        bg_log_essential "Build queued for job '$job_name' (monitoring disabled)"
        if [[ -n "$queue_url" ]]; then
            bg_log_info "Queue item: $queue_url"
        fi
        return 0
    fi

    # -------------------------------------------------------------------------
    # Part 5: Wait for build to start and monitor
    # -------------------------------------------------------------------------
    if ! _wait_for_build_start "$job_name" "$baseline_build" "$queue_url"; then
        bg_log_error "Build did not start within timeout"
        bg_log_essential "Suggestion: Check Jenkins queue at ${JENKINS_URL}/queue/"
        return 1
    fi
    local build_number="$_WAIT_FOR_BUILD_RESULT"

    _display_monitoring_preamble "$job_name" "$BUILD_PRIOR_JOBS" "false" "$((build_number - 1))"
    log_info "Starting"

    # Display unified build header before monitoring
    # Spec: unify-follow-log-spec.md, Section 5 (buildgit build)
    if [[ "$BUILD_LINE_MODE" == "true" ]]; then
        if _monitor_build_line_mode "$job_name" "$build_number" "false" "true"; then
            return 0
        fi
        return 1
    fi

    _display_build_in_progress_banner "$job_name" "$build_number"

    # Monitor build until completion
    if ! _monitor_build "$job_name" "$build_number" "true" "true"; then
        bg_log_error "Build monitoring interrupted or timed out"
        local console_url
        console_url=$(jenkins_console_url "$job_name" "$build_number")
        if [[ -n "$console_url" ]]; then
            bg_log_essential "Suggestion: Check Jenkins console at ${console_url}"
        fi
        return 1
    fi

    # Display build result (blank line separator)
    echo ""
    _handle_build_completion "$job_name" "$build_number"
}
