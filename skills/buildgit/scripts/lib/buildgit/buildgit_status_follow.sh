_cmd_status_follow() {
    local job_name="$1"
    local json_mode="$2"
    local once_mode="${3:-false}"
    local once_timeout="${4:-10}"
    local line_mode="${5:-false}"
    local no_tests="${6:-false}"
    local prior_jobs_count="${7:-3}"
    local probe_all="${8:-false}"
    local top_job_name="${job_name%%/*}"
    local preamble_job_name="$job_name"

    # Store job name for cleanup handler
    _FOLLOW_JOB_NAME="$job_name"

    if [[ "$probe_all" == "true" ]]; then
        local inferred_branch=""
        inferred_branch=$(_get_current_git_branch 2>/dev/null) || true
        if [[ -n "$inferred_branch" ]]; then
            preamble_job_name="${top_job_name}/${inferred_branch}"
        fi
    fi

    # Set up interrupt handler for follow mode
    trap _follow_mode_cleanup SIGINT SIGTERM

    if [[ "$line_mode" != "true" ]]; then
        if [[ "$once_mode" == "true" ]]; then
            if [[ "$probe_all" == "true" ]]; then
                log_info "Follow mode enabled (once, timeout=${once_timeout}s) - monitoring builds for job '$job_name' across all branches"
            else
                log_info "Follow mode enabled (once, timeout=${once_timeout}s) - monitoring builds for job '$job_name'"
            fi
        else
            if [[ "$probe_all" == "true" ]]; then
                bg_log_info "Follow mode enabled - monitoring builds for job '$job_name' across all branches"
            else
                bg_log_info "Follow mode enabled - monitoring builds for job '$job_name'"
            fi
            bg_log_info "Press Ctrl+C to stop monitoring"
        fi
    fi

    # On the first check, if the latest build is already completed, skip it
    # (no stale replay) and wait for the next new build instead.
    local first_check=true
    local preamble_printed=false
    local starting_notified=false

    while true; do
        if [[ "$probe_all" == "true" && "$job_name" == "$top_job_name" ]]; then
            if [[ "$json_mode" != "true" && "$preamble_printed" != "true" ]]; then
                _display_monitoring_preamble "$preamble_job_name" "$prior_jobs_count" "$no_tests"
                preamble_printed=true
            fi

            local probe_output detected_line detected_branch detected_build_number
            if [[ "$once_mode" == "true" ]]; then
                if [[ "$once_timeout" == "0" ]]; then
                    bg_log_error "no new build detected for 0 seconds"
                    return 2
                fi
                if ! probe_output=$(_follow_wait_probe_all_timeout "$top_job_name" "$once_timeout"); then
                    bg_log_error "no new build detected for ${once_timeout} seconds"
                    return 2
                fi
            else
                if [[ "$line_mode" != "true" ]]; then
                    bg_log_essential "Waiting for first build of $top_job_name..."
                fi
                probe_output=$(_follow_wait_probe_all "$top_job_name")
            fi

            printf '%s\n' "$probe_output"
            detected_line="${probe_output##*$'\n'}"
            detected_build_number="${detected_line##* }"
            detected_branch="${detected_line%% *}"
            job_name="${top_job_name}/${detected_branch}"
            first_check=false
        fi

        # Get current build number and info
        local build_number
        build_number=$(get_last_build_number "$job_name")

        if [[ "$build_number" == "0" || -z "$build_number" ]]; then
            if [[ "$json_mode" != "true" && "$preamble_printed" != "true" ]]; then
                log_info "Waiting for Jenkins build ${job_name} to start..."
                _display_monitoring_preamble "$job_name" "$prior_jobs_count" "$no_tests"
                preamble_printed=true
            fi
            # No builds exist yet
            if [[ "$first_check" == "true" && "$once_mode" == "true" ]]; then
                if [[ "$once_timeout" == "0" ]]; then
                    bg_log_error "no new build detected for 0 seconds"
                    return 2
                fi
                if ! _follow_wait_for_new_build_timeout "$job_name" "0" "$once_timeout" > /dev/null; then
                    bg_log_error "no new build detected for ${once_timeout} seconds"
                    return 2
                fi
                first_check=false
                continue
            fi
            if [[ "$line_mode" != "true" ]]; then
                bg_log_essential "Waiting for first build of $job_name..."
            fi
            _follow_wait_for_new_build "$job_name" "0" > /dev/null
            first_check=false
            continue
        fi

        local build_json
        build_json=$(get_build_info "$job_name" "$build_number")

        if [[ -z "$build_json" ]]; then
            bg_log_error "Failed to fetch build information"
            sleep "$POLL_INTERVAL"
            continue
        fi

        local building
        building=$(echo "$build_json" | jq -r '.building // false')

        if [[ "$json_mode" != "true" && "$preamble_printed" != "true" ]]; then
            local preamble_max_build=""
            if [[ "$building" == "true" ]]; then
                preamble_max_build=$((build_number - 1))
            fi
            log_info "Waiting for Jenkins build ${job_name} to start..."
            _display_monitoring_preamble "$job_name" "$prior_jobs_count" "$no_tests" "$preamble_max_build"
            preamble_printed=true
        fi

        # If build is in progress, display banner and monitor until completion
        if [[ "$building" == "true" ]]; then
            if [[ "$json_mode" != "true" && "$starting_notified" != "true" ]]; then
                log_info "Starting"
                starting_notified=true
            fi
            first_check=false
            local build_exit_code
            if [[ "$line_mode" == "true" && "$json_mode" != "true" ]]; then
                if _monitor_build_line_mode "$job_name" "$build_number" "$no_tests" "true"; then
                    build_exit_code=0
                else
                    build_exit_code=$?
                fi
            elif [[ "$json_mode" == "true" && "$once_mode" == "true" ]]; then
                local elapsed=0
                while [[ $elapsed -lt $MAX_BUILD_TIME ]]; do
                    build_json=$(get_build_info "$job_name" "$build_number")
                    if [[ -z "$build_json" ]]; then
                        sleep "$POLL_INTERVAL"
                        elapsed=$((elapsed + POLL_INTERVAL))
                        continue
                    fi

                    building=$(echo "$build_json" | jq -r '.building // false')
                    if [[ "$building" != "true" ]]; then
                        break
                    fi

                    sleep "$POLL_INTERVAL"
                    elapsed=$((elapsed + POLL_INTERVAL))
                done

                if [[ "$building" == "true" ]]; then
                    bg_log_error "Build #${build_number} did not complete within ${MAX_BUILD_TIME}s timeout"
                    return 1
                fi

                if _jenkins_status_check "$job_name" "true" "$build_number"; then
                    build_exit_code=0
                else
                    build_exit_code=$?
                fi
            else
                bg_log_info "Build #${build_number} is in progress, monitoring..."

                # Calculate running time for status -f (joining in-progress build)
                # Spec: bug-build-monitoring-header-spec.md
                local build_ts_ms running_msg=""
                build_ts_ms=$(echo "$build_json" | jq -r '.timestamp // 0')
                if [[ "$build_ts_ms" != "0" ]]; then
                    local now_ms=$(($(date +%s) * 1000))
                    local running_ms=$((now_ms - build_ts_ms))
                    local running_display
                    running_display=$(format_duration "$running_ms")
                    running_msg="Job ${job_name} #${build_number} has been running for ${running_display}"
                fi

                # Display build info banner before entering monitoring loop
                # Spec: unify-follow-log-spec.md, Section 5 (buildgit status -f)
                _display_build_in_progress_banner "$job_name" "$build_number" "$running_msg"
                _monitor_build "$job_name" "$build_number" "true" "true"
                # Display build completion (test results if applicable + Finished line)
                # Spec: unify-follow-log-spec.md, Section 4 (Build Completion)
                if _handle_build_completion "$job_name" "$build_number"; then
                    build_exit_code=0
                else
                    build_exit_code=$?
                fi
            fi
            if [[ "$once_mode" == "true" ]]; then
                return "$build_exit_code"
            fi
        else
            # Build already completed
            if [[ "$first_check" == "true" ]]; then
                # On entry, do not replay the stale completed build.
                # Wait for the next new build instead.
                first_check=false
                if [[ "$once_mode" == "true" ]]; then
                    if [[ "$once_timeout" == "0" ]]; then
                        bg_log_error "no new build detected for 0 seconds"
                        return 2
                    fi
                    if ! _follow_wait_for_new_build_timeout "$job_name" "$build_number" "$once_timeout" > /dev/null; then
                        bg_log_error "no new build detected for ${once_timeout} seconds"
                        return 2
                    fi
                    continue
                else
                    if [[ "$line_mode" != "true" ]]; then
                        echo ""
                        log_info "Waiting for next build of $job_name..."
                    fi
                    local new_build_number
                    new_build_number=$(_follow_wait_for_new_build "$job_name" "$build_number")
                    if [[ "$line_mode" != "true" ]]; then
                        bg_log_info "New build #${new_build_number} detected"
                    fi
                    continue
                fi
            else
                # Subsequent check: new build that completed quickly — display it
                local build_exit_code
                if [[ "$line_mode" == "true" && "$json_mode" != "true" ]]; then
                    if _status_line_for_build_json "$job_name" "$build_number" "$build_json" "$no_tests"; then
                        build_exit_code=0
                    else
                        build_exit_code=$?
                    fi
                elif [[ "$json_mode" == "true" && "$once_mode" == "true" ]]; then
                    if _jenkins_status_check "$job_name" "true" "$build_number"; then
                        build_exit_code=0
                    else
                        build_exit_code=$?
                    fi
                else
                    if _display_completed_build "$job_name" "$build_number" "$build_json"; then
                        build_exit_code=0
                    else
                        build_exit_code=$?
                    fi
                fi
                if [[ "$once_mode" == "true" ]]; then
                    return "$build_exit_code"
                fi
            fi
        fi

        # Show waiting message in regular follow mode; line mode stays quiet between builds.
        if [[ "$probe_all" == "true" ]]; then
            starting_notified=false
            job_name="$top_job_name"
            continue
        fi

        if [[ "$line_mode" != "true" ]]; then
            echo ""
            log_info "Waiting for next build of $job_name..."
        fi

        # Wait for a new build to start
        starting_notified=false
        local new_build_number
        new_build_number=$(_follow_wait_for_new_build "$job_name" "$build_number")

        if [[ "$line_mode" != "true" ]]; then
            bg_log_info "New build #${new_build_number} detected"
        fi
    done
}
