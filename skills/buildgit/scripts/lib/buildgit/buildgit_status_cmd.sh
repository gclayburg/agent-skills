_status_special_output() {
    local job_name="$1"
    local build_number="$2"

    local build_json
    build_json=$(get_build_info "$job_name" "$build_number")
    if [[ -z "$build_json" ]]; then
        bg_log_error "Build #${build_number} not found for job '$job_name'"
        return 1
    fi

    if [[ "$STATUS_LIST_STAGES_MODE" == "true" ]]; then
        local stages_json
        stages_json=$(get_all_stages "$job_name" "$build_number")
        if [[ "$STATUS_JSON_MODE" == "true" ]]; then
            printf '%s\n' "${stages_json:-[]}"
        else
            echo "$stages_json" | jq -r '.[].name' 2>/dev/null || true
        fi
        return 0
    fi

    if [[ -n "${STATUS_CONSOLE_TEXT_STAGE:-}" ]]; then
        local stage_tmp
        stage_tmp=$(mktemp)
        if get_stage_console_output "$job_name" "$build_number" "$STATUS_CONSOLE_TEXT_STAGE" >"$stage_tmp"; then
            cat "$stage_tmp"
            rm -f "$stage_tmp"
            return 0
        else
            local stage_rc=$?
            rm -f "$stage_tmp"
            if [[ "$stage_rc" -eq 3 ]]; then
                bg_log_error "Stage '${STATUS_CONSOLE_TEXT_STAGE}' not found for build #${build_number}"
                if [[ -n "${_STAGE_CONSOLE_AVAILABLE_STAGES:-}" ]]; then
                    printf 'Available stages:\n%s\n' "$_STAGE_CONSOLE_AVAILABLE_STAGES" >&2
                fi
            elif [[ "$stage_rc" -eq 4 ]]; then
                bg_log_error "Stage '${STATUS_CONSOLE_TEXT_STAGE}' is ambiguous for build #${build_number}"
                if [[ -n "${_STAGE_CONSOLE_AMBIGUOUS_STAGES:-}" ]]; then
                    printf 'Matching stages:\n%s\n' "$_STAGE_CONSOLE_AMBIGUOUS_STAGES" >&2
                fi
            else
                bg_log_error "Could not retrieve console text for stage '${STATUS_CONSOLE_TEXT_STAGE}' in build #${build_number}"
            fi
            return 1
        fi
    fi

    local console_output
    if ! console_output=$(get_console_output_raw "$job_name" "$build_number"); then
        bg_log_error "Could not retrieve console text for build #${build_number}"
        return 1
    fi
    printf '%s\n' "$console_output"
    return 0
}

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

    # Validate -g/--gitlog combinations (run before generic --line/--json checks)
    if [[ "${STATUS_GITLOG:-false}" == "true" ]]; then
        if [[ "$STATUS_ALL_MODE" == "true" ]]; then
            _usage_error "Cannot use --gitlog with --all"
        fi
        if [[ "$STATUS_JSON_MODE" == "true" ]]; then
            _usage_error "Cannot use --gitlog with --json"
        fi
        if [[ "$STATUS_FOLLOW_MODE" == "true" ]]; then
            _usage_error "Cannot use --gitlog with --follow"
        fi
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

    # Validate -r/--reverse combinations
    if [[ "${STATUS_REVERSE:-false}" == "true" && "$STATUS_FOLLOW_MODE" == "true" ]]; then
        _usage_error "Cannot use -r/--reverse with --follow"
    fi
    if [[ "${STATUS_REVERSE:-false}" == "true" && "${STATUS_GITLOG:-false}" == "true" ]]; then
        _usage_error "Cannot use -r/--reverse with --gitlog"
    fi
    if [[ "$STATUS_CONSOLE_TEXT_MODE" == "true" || "$STATUS_LIST_STAGES_MODE" == "true" ]]; then
        if [[ "$STATUS_CONSOLE_TEXT_MODE" == "true" && "$STATUS_LIST_STAGES_MODE" == "true" ]]; then
            _usage_error "Cannot combine --console-text with --list-stages"
        fi
        if [[ "$STATUS_FOLLOW_MODE" == "true" || "$STATUS_ONCE_MODE" == "true" ]]; then
            _usage_error "Cannot combine --console-text/--list-stages with --follow"
        fi
        if [[ "$STATUS_LINE_MODE" == "true" || "$STATUS_ALL_MODE" == "true" ]]; then
            _usage_error "Cannot combine --console-text/--list-stages with --line or --all"
        fi
        if [[ "${STATUS_N_SET:-false}" == "true" || "$STATUS_PRIOR_JOBS" -gt 0 ]]; then
            _usage_error "Cannot combine --console-text/--list-stages with -n or --prior-jobs"
        fi
        if [[ "$STATUS_CONSOLE_TEXT_MODE" == "true" && "$STATUS_JSON_MODE" == "true" ]]; then
            _usage_error "Cannot combine --console-text with --json"
        fi
        if [[ "$VERBOSE_MODE" == "true" ]]; then
            _usage_error "Cannot combine --console-text/--list-stages with --verbose"
        fi
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

    if [[ "$STATUS_CONSOLE_TEXT_MODE" == "true" || "$STATUS_LIST_STAGES_MODE" == "true" ]]; then
        if [[ -z "$resolved_status_build_number" ]]; then
            resolved_status_build_number=$(get_last_build_number "$_VALIDATED_JOB_NAME")
            if [[ "$resolved_status_build_number" == "0" || -z "$resolved_status_build_number" ]]; then
                bg_log_error "No builds found for job '$_VALIDATED_JOB_NAME'"
                return 1
            fi
        fi
        _status_special_output "$_VALIDATED_JOB_NAME" "$resolved_status_build_number"
        return $?
    fi

    # JSON mode always uses structured output path
    if [[ "$STATUS_JSON_MODE" == "true" ]]; then
        if [[ "${STATUS_N_SET:-false}" == "true" ]]; then
            _status_multi_build_check "$_VALIDATED_JOB_NAME" "$resolved_status_build_number" "$STATUS_LINE_COUNT" "true" "0" "$STATUS_NO_TESTS" "$STATUS_REVERSE"
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

    # --gitlog branches into the interleave helper (line mode only).
    if [[ "${STATUS_GITLOG:-false}" == "true" ]]; then
        if [[ "$STATUS_ALL_MODE" == "true" ]]; then
            _usage_error "Cannot use --gitlog with --all"
        fi
        _status_gitlog_interleave "$_VALIDATED_JOB_NAME" "$resolved_status_build_number" "$line_count" "$STATUS_NO_TESTS" "${STATUS_N_SET:-false}" "$STATUS_GITLOG_RANGE"
        return $?
    fi

    if [[ "$use_line_mode" == "true" ]]; then
        _status_line_check "$_VALIDATED_JOB_NAME" "$resolved_status_build_number" "$line_count" "$STATUS_NO_TESTS" "$STATUS_PRIOR_JOBS" "$STATUS_REVERSE"
        return $?
    fi

    if [[ "${STATUS_N_SET:-false}" == "true" ]]; then
        _status_multi_build_check "$_VALIDATED_JOB_NAME" "$resolved_status_build_number" "$line_count" "false" "$STATUS_PRIOR_JOBS" "$STATUS_NO_TESTS" "$STATUS_REVERSE"
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
