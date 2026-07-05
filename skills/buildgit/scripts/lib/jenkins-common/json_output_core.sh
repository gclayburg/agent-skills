output_json() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"
    local trigger_type="$4"
    local trigger_user="$5"
    local commit_sha="$6"
    local commit_msg="$7"
    local correlation_status="$8"
    local console_output="${9:-}"

    # Extract values from build JSON
    local result building duration timestamp url
    result=$(echo "$build_json" | jq -r '.result // null')
    building=$(echo "$build_json" | jq -r '.building // false')
    duration=$(echo "$build_json" | jq -r '.duration // 0')
    timestamp=$(echo "$build_json" | jq -r '.timestamp // 0')
    url=$(echo "$build_json" | jq -r '.url // empty')

    # Calculate duration in seconds
    local duration_seconds=0
    if [[ "$duration" =~ ^[0-9]+$ ]]; then
        duration_seconds=$((duration / 1000))
    fi

    # Determine if build is failed (any non-SUCCESS completed result)
    local is_failed=false
    if [[ "$result" != "SUCCESS" && "$result" != "null" && -n "$result" ]]; then
        is_failed=true
    fi

    # Determine correlation booleans
    local in_local_history=false
    local reachable_from_head=false
    local is_head=false

    case "$correlation_status" in
        your_commit)
            in_local_history=true
            reachable_from_head=true
            is_head=true
            ;;
        in_history)
            in_local_history=true
            reachable_from_head=true
            ;;
        not_in_history)
            in_local_history=true
            ;;
    esac

    # Build base JSON
    local json_output
    local trigger_user_value="$trigger_user"
    local commit_message_value="$commit_msg"
    if [[ "$trigger_user_value" == "unknown" ]]; then
        trigger_user_value=""
    fi
    if [[ "$commit_message_value" == "unknown" ]]; then
        commit_message_value=""
    fi
    json_output=$(jq -n \
        --arg job "$job_name" \
        --argjson build_number "$build_number" \
        --arg status "$result" \
        --argjson building "$building" \
        --argjson duration_seconds "$duration_seconds" \
        --arg timestamp "$(format_timestamp_iso "$timestamp")" \
        --arg url "$url" \
        --arg trigger_type "$trigger_type" \
        --arg trigger_user "$trigger_user_value" \
        --arg sha "$commit_sha" \
        --arg message "$commit_message_value" \
        --argjson in_local_history "$in_local_history" \
        --argjson reachable_from_head "$reachable_from_head" \
        --argjson is_head "$is_head" \
        --arg console_url "${url}console" \
        '{
            job: $job,
            build: {
                number: $build_number,
                status: (if $status == "null" then null else $status end),
                building: $building,
                duration_seconds: $duration_seconds,
                timestamp: (if $timestamp == "null" then null else $timestamp end),
                url: $url
            },
            trigger: {
                type: $trigger_type,
                user: $trigger_user
            },
            triggerUser: $trigger_user,
            commit: {
                sha: $sha,
                message: $message,
                in_local_history: $in_local_history,
                reachable_from_head: $reachable_from_head,
                is_head: $is_head
            },
            commitMessage: $message,
            console_url: $console_url
        }')

    # Add nested stages array to JSON output
    # Spec: nested-jobs-display-spec.md, Section: JSON Output
    local nested_stages_json
    nested_stages_json=$(_get_nested_stages "$job_name" "$build_number" 2>/dev/null) || nested_stages_json="[]"

    if [[ -n "$nested_stages_json" && "$nested_stages_json" != "[]" ]]; then
        # Transform to match JSON output spec: rename durationMillis to duration_ms
        local stages_for_json
        stages_for_json=$(echo "$nested_stages_json" | jq '
            [.[] | {
                name: .name,
                status: .status,
                duration_ms: .durationMillis,
                agent: .agent
            } + (if .downstream_job then {
                downstream_job: .downstream_job,
                downstream_build: .downstream_build,
                parent_stage: .parent_stage,
                nesting_depth: .nesting_depth
            } else {} end) + (if .has_downstream then {
                has_downstream: true
            } else {} end) + (if .nesting_depth > 0 and (.downstream_job | not) then {
                nesting_depth: .nesting_depth,
                downstream_job: .downstream_job,
                downstream_build: .downstream_build,
                parent_stage: .parent_stage
            } else {} end)
            + (if .is_parallel_wrapper then {
                is_parallel_wrapper: true,
                parallel_branches: .parallel_branches
            } else {} end)
            + (if .parallel_branch then {
                parallel_branch: .parallel_branch
            } + (if .parallel_wrapper then {
                parallel_wrapper: .parallel_wrapper
            } else {} end)
              + (if .parallel_path then {
                parallel_path: .parallel_path
            } else {} end)
              + (if .parent_branch_stage then {
                parent_branch_stage: .parent_branch_stage
            } else {} end) else {} end)]
        ' 2>/dev/null) || stages_for_json="[]"

        if [[ -n "$stages_for_json" && "$stages_for_json" != "[]" ]]; then
            json_output=$(echo "$json_output" | jq --argjson stages "$stages_for_json" '. + {stages: $stages}')
        fi
    fi

    # Add failure info if build failed
    if [[ "$is_failed" == "true" && -n "$console_output" ]]; then
        local failure_json
        failure_json=$(_build_failure_json "$job_name" "$build_number" "$console_output")

        local build_info_json
        build_info_json=$(_build_info_json "$console_output")

        # Merge failure and build_info into the output
        json_output=$(echo "$json_output" | jq \
            --argjson failure "$failure_json" \
            --argjson build_info "$build_info_json" \
            '. + {failure: $failure, build_info: $build_info}')
    fi

    # Add test results for all completed builds
    # Spec: show-test-results-always-spec.md, Section 7
    local is_completed=false
    if [[ "$result" != "null" && -n "$result" && "$building" == "false" ]]; then
        is_completed=true
    fi

    if [[ "$is_completed" == "true" ]]; then
        local collected_results test_report_rc=0
        if [[ -z "$console_output" ]]; then
            console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null || true)
        fi
        if collected_results=$(collect_downstream_test_results "$job_name" "$build_number" "$console_output"); then
            test_report_rc=0
        else
            test_report_rc=$?
            collected_results=""
        fi

        if [[ "$test_report_rc" -eq 2 ]]; then
            _note_test_results_comm_failure "$job_name" "$build_number"
            json_output=$(echo "$json_output" | jq '. + {test_results: null, testResults: null, testResultsError: "communication_failure"}')
        elif [[ -n "$collected_results" ]]; then
            local test_results_formatted
            test_results_formatted=$(format_hierarchical_test_results_json "$collected_results")

            if [[ -n "$test_results_formatted" ]]; then
                json_output=$(echo "$json_output" | jq \
                    --argjson test_results "$test_results_formatted" \
                    '. + {test_results: $test_results}')
            else
                json_output=$(echo "$json_output" | jq '. + {test_results: null}')
            fi
        else
            # No test report available - include null sentinel
            # Spec: show-test-results-always-spec.md, Section 3.2
            json_output=$(echo "$json_output" | jq '. + {test_results: null}')
        fi

        # Adjust failure.error_summary and failure.console_log based on CONSOLE_MODE (failures only)
        # Spec: console-on-unstable-spec.md, Section 3 (JSON output)
        if [[ "$is_failed" == "true" ]]; then
            local has_test_failures=false
            if [[ -n "$collected_results" ]]; then
                local fail_count
                fail_count=$(echo "$collected_results" | jq -r '
                    [.[] | select(.test_json != "") | .test_json | fromjson | (.failCount // 0)] | add // 0
                ') || fail_count=0
                if [[ "$fail_count" -gt 0 ]]; then
                    has_test_failures=true
                fi
            fi

            if [[ "$has_test_failures" == "true" && -z "${CONSOLE_MODE:-}" ]]; then
                # Suppress error_summary when test failures present and no --console
                json_output=$(echo "$json_output" | jq \
                    'if .failure then .failure.error_summary = null else . end')
            fi

            if [[ "${CONSOLE_MODE:-}" =~ ^[0-9]+$ ]]; then
                # --console N: add console_log with last N lines, null out error_summary
                local console_log_lines
                console_log_lines=$(echo "$console_output" | tail -"${CONSOLE_MODE}")
                json_output=$(echo "$json_output" | jq \
                    --arg console_log "$console_log_lines" \
                    'if .failure then .failure.error_summary = null | .failure.console_log = $console_log else . end')
            fi
        fi
    fi

    echo "$json_output"
}

# Build failure JSON object
# Usage: _build_failure_json "job_name" "build_number" "console_output"
# Returns: JSON object with failed_jobs, root_cause_job, failed_stage, error_summary, console_output
# Spec: bug-status-json-spec.md
_build_failure_json() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"

    local failed_jobs=()
    local root_cause_job="$job_name"
    local failed_stage=""
    local error_summary=""
    local json_console_output=""

    # Start with root job
    failed_jobs+=("$job_name")

    # Detect early failure: no pipeline stages ran
    # Spec: bug-status-json-spec.md, Detection Criteria
    local stages
    stages=$(get_all_stages "$job_name" "$build_number")
    local stage_count
    stage_count=$(echo "$stages" | jq 'length' 2>/dev/null) || stage_count=0

    if [[ "$stage_count" -eq 0 ]]; then
        # Early failure — include full console output, no error_summary
        json_console_output="$console_output"
    else
        # Stages exist — get failed stage and error details

        # Get failed stage for root job
        failed_stage=$(get_failed_stage "$job_name" "$build_number" 2>/dev/null) || true

        # Find downstream builds and their failure status
        local downstream_builds
        downstream_builds=$(detect_all_downstream_builds "$console_output")

        if [[ -n "$downstream_builds" ]]; then
            # Track the deepest failed job
            local current_console="$console_output"
            local current_job="$job_name"
            local current_build="$build_number"

            while true; do
                local failed_downstream
                failed_downstream=$(find_failed_downstream_build "$current_console")

                if [[ -z "$failed_downstream" ]]; then
                    break
                fi

                local ds_job ds_build
                ds_job=$(echo "$failed_downstream" | cut -d' ' -f1)
                ds_build=$(echo "$failed_downstream" | cut -d' ' -f2)

                if [[ -n "$ds_job" && "$ds_job" != "$current_job" ]]; then
                    failed_jobs+=("$ds_job")
                    root_cause_job="$ds_job"
                    current_job="$ds_job"
                    current_build="$ds_build"

                    # Get console for this downstream build
                    current_console=$(get_console_output "$ds_job" "$ds_build" 2>/dev/null) || break

                    # Update failed stage from root cause job
                    local ds_stage
                    ds_stage=$(get_failed_stage "$ds_job" "$ds_build" 2>/dev/null) || true
                    if [[ -n "$ds_stage" ]]; then
                        failed_stage="$ds_stage"
                    fi
                else
                    break
                fi
            done

            # Get multi-line error summary from root cause (mirrors _display_error_logs)
            # Spec: bug-status-json-spec.md, Technical Requirement 2
            if [[ -n "$current_console" ]]; then
                error_summary=$(extract_error_lines "$current_console" 30)
            fi
        else
            # No downstream — use stage-aware error extraction (mirrors _display_error_logs)
            if [[ -n "$failed_stage" ]]; then
                local stage_logs
                stage_logs=$(extract_stage_logs "$console_output" "$failed_stage")

                local line_count
                line_count=$(echo "$stage_logs" | wc -l | tr -d ' ')

                if [[ -n "$stage_logs" ]] && [[ "$line_count" -ge "$STAGE_LOG_MIN_LINES" ]]; then
                    error_summary=$(extract_error_lines "$stage_logs" 30)
                else
                    # Fallback: stage extraction insufficient
                    error_summary=$(echo "$console_output" | tail -"$STAGE_LOG_FALLBACK_LINES")
                fi
            else
                error_summary=$(extract_error_lines "$console_output" 30)
            fi
        fi
    fi

    # Build JSON array for failed_jobs
    local failed_jobs_json
    failed_jobs_json=$(printf '%s\n' "${failed_jobs[@]}" | jq -R . | jq -s .)

    jq -n \
        --argjson failed_jobs "$failed_jobs_json" \
        --arg root_cause_job "$root_cause_job" \
        --arg failed_stage "$failed_stage" \
        --arg error_summary "$error_summary" \
        --arg console_output "$json_console_output" \
        '{
            failed_jobs: $failed_jobs,
            root_cause_job: $root_cause_job,
            failed_stage: (if $failed_stage == "" then null else $failed_stage end),
            error_summary: (if $error_summary == "" then null else $error_summary end),
            console_output: (if $console_output == "" then null else $console_output end),
            console_log: null
        }'
}

# Extract a brief error summary from console output
# Usage: _extract_error_summary "console_output"
# Returns: Single-line error summary
_extract_error_summary() {
    local console_output="$1"

    # Try to find first meaningful error line
    local error_line
    error_line=$(echo "$console_output" | grep -iE '^(ERROR|FATAL|Exception|.*failed:)' 2>/dev/null | head -1) || true

    if [[ -z "$error_line" ]]; then
        # Try assertion errors
        error_line=$(echo "$console_output" | grep -iE 'AssertionError|assertion failed' 2>/dev/null | head -1) || true
    fi

    if [[ -z "$error_line" ]]; then
        # Try test failures
        error_line=$(echo "$console_output" | grep -iE 'Test.*failed|failed.*test' 2>/dev/null | head -1) || true
    fi

    # Truncate to reasonable length
    if [[ -n "$error_line" ]]; then
        echo "${error_line:0:200}"
    fi
}

# Build build_info JSON object from console output
# Usage: _build_info_json "console_output"
# Returns: JSON object with started_by, agent, pipeline
_build_info_json() {
    local console_output="$1"

    _parse_build_metadata "$console_output"

    jq -n \
        --arg started_by "$_META_STARTED_BY" \
        --arg agent "$_META_AGENT" \
        --arg pipeline "$_META_PIPELINE" \
        '{
            started_by: (if $started_by == "" then null else $started_by end),
            agent: (if $agent == "" then null else $agent end),
            pipeline: (if $pipeline == "" then null else $pipeline end)
        }'
}
