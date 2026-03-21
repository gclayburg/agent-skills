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

# =============================================================================
# Nested/Downstream Stage Display Functions
# =============================================================================
# Spec: nested-jobs-display-spec.md

# Extract agent name from build console output
# Usage: _extract_agent_name "$console_output"
# Returns: agent name string, or empty
_extract_agent_name() {
    local console_output="$1"
    _extract_running_agent_from_console "$console_output" || true
}

# Extract a pipeline-scope agent from console output when Jenkins allocates the
# node before the first named stage.
# Usage: _extract_pre_stage_agent_from_console "$console_output"
# Returns: agent name string, or empty if the first stage starts before any
#          "Running on" line appears.
_extract_pre_stage_agent_from_console() {
    local console_output="$1"
    local stripped_console

    stripped_console=$(printf "%s\n" "$console_output" | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g')

    printf "%s\n" "$stripped_console" | awk '
        /^\[Pipeline\] \{ \(.+\)$/ { exit }
        /Running on[[:space:]]+.+[[:space:]]+in[[:space:]]+\// {
            agent_name = $0
            sub(/^.*Running on[[:space:]]+/, "", agent_name)
            sub(/[[:space:]]+in[[:space:]]+\/.*$/, "", agent_name)
            sub(/^[[:space:]]+/, "", agent_name)
            sub(/[[:space:]]+$/, "", agent_name)
            print agent_name
            exit
        }
    ' || true
}

# Build a map of pipeline stage name -> Jenkins agent name from console output.
# Usage: _build_stage_agent_map "$console_output"
# Returns: JSON object like {"Build":"agent6 guthrie","Unit Tests A":"agent7"}
# Notes:
# - Associates each "Running on" line with the most recent unmatched stage block.
# - Normalizes "Branch: <name>" stage labels to "<name>" for wfapi compatibility.
_build_stage_agent_map() {
    local console_output="${1:-}"
    if [[ -z "$console_output" ]]; then
        echo "{}"
        return 0
    fi

    local stage_agent_pairs
    stage_agent_pairs=$(printf "%s\n" "$console_output" | \
        sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' | \
        awk '
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }

            {
                if ($0 ~ /^\[Pipeline\] \{ \(.+\)$/) {
                    stage_name = $0
                    sub(/^\[Pipeline\] \{ \(/, "", stage_name)
                    sub(/\)$/, "", stage_name)
                    sub(/^Branch:[[:space:]]+/, "", stage_name)
                    pending[++pending_count] = stage_name
                    next
                }

                if ($0 ~ /Running on[[:space:]]+.+[[:space:]]+in[[:space:]]+\//) {
                    agent_name = $0
                    sub(/^.*Running on[[:space:]]+/, "", agent_name)
                    sub(/[[:space:]]+in[[:space:]]+\/.*$/, "", agent_name)
                    agent_name = trim(agent_name)
                    for (i = pending_count; i >= 1; i--) {
                        if (pending[i] != "") {
                            if (!(pending[i] in stage_agent_map)) {
                                stage_agent_map[pending[i]] = agent_name
                            }
                            pending[i] = ""
                            break
                        }
                    }
                }
            }

            END {
                for (stage_name in stage_agent_map) {
                    printf "%s\t%s\n", stage_name, stage_agent_map[stage_name]
                }
            }
        ')

    if [[ -z "$stage_agent_pairs" ]]; then
        echo "{}"
        return 0
    fi

    local stage_agent_map_json="{}"
    local stage_name agent_name
    while IFS=$'\t' read -r stage_name agent_name; do
        [[ -z "${stage_name:-}" ]] && continue
        stage_agent_map_json=$(echo "$stage_agent_map_json" | jq \
            --arg stage "$stage_name" \
            --arg agent "$agent_name" \
            '. + {($stage): $agent}')
    done <<< "$stage_agent_pairs"

    echo "$stage_agent_map_json"
}

# Map parent stages to their downstream builds
# Usage: _map_stages_to_downstream "$console_output" "$stages_json"
# Returns: JSON object mapping stage names to {job, build} pairs
# Example: {"Build Handle": {"job": "downstream-job", "build": 42}}
_map_stages_to_downstream() {
    local console_output="$1"
    local stages_json="$2"

    local result="{}"
    local claimed_positive_downstreams="{}"
    local stage_count
    stage_count=$(echo "$stages_json" | jq 'length' 2>/dev/null) || stage_count=0

    local i=0
    while [[ $i -lt $stage_count ]]; do
        local stage_name
        stage_name=$(echo "$stages_json" | jq -r ".[$i].name")

        # Extract this stage's console logs
        local stage_logs
        stage_logs=$(extract_stage_logs "$console_output" "$stage_name")

        if [[ -n "$stage_logs" ]]; then
            # Check for downstream builds in this stage's logs
            local downstream
            downstream=$(detect_all_downstream_builds "$stage_logs")

            if [[ -n "$downstream" ]]; then
                # Select best downstream match for this stage
                local ds_job ds_build
                local selected_downstream
                selected_downstream=$(_select_downstream_build_for_stage "$stage_name" "$downstream" "$stage_logs")
                ds_job=$(echo "$selected_downstream" | awk '{print $1}')
                ds_build=$(echo "$selected_downstream" | awk '{print $2}')

                if [[ -n "$ds_job" && -n "$ds_build" ]]; then
                    local downstream_key selected_score already_claimed_by_positive
                    downstream_key="${ds_job}#${ds_build}"
                    selected_score=$(_downstream_stage_job_match_score "$stage_name" "$ds_job")
                    already_claimed_by_positive=$(echo "$claimed_positive_downstreams" | jq -r --arg key "$downstream_key" '.[$key] // false' 2>/dev/null)
                    if [[ "$selected_score" -le 0 && "$already_claimed_by_positive" == "true" ]]; then
                        i=$((i + 1))
                        continue
                    fi
                    result=$(echo "$result" | jq \
                        --arg stage "$stage_name" \
                        --arg job "$ds_job" \
                        --argjson build "$ds_build" \
                        '. + {($stage): {"job": $job, "build": $build}}')
                    if [[ "$selected_score" -gt 0 ]]; then
                        claimed_positive_downstreams=$(echo "$claimed_positive_downstreams" | jq \
                            --arg key "$downstream_key" \
                            '. + {($key): true}')
                    fi
                fi
            fi
        fi

        i=$((i + 1))
    done

    echo "$result"
}

_detect_branch_substages_from_blue_ocean() {
    local stages_json="$1"
    local blue_nodes_json="$2"
    local wrapper_stage="$3"
    local branches_json="$4"

    if [[ -z "$blue_nodes_json" || "$blue_nodes_json" == "[]" ]]; then
        echo "{}"
        return 0
    fi

    jq -cn \
        --arg wrapper "$wrapper_stage" \
        --argjson stages "$stages_json" \
        --argjson nodes "$blue_nodes_json" \
        --argjson branches "$branches_json" '
        def find_by_id($id): ($nodes[] | select(.id == $id));
        def nearest_parallel($node_id):
            if ($node_id == null or $node_id == "") then
                null
            else
                (find_by_id($node_id)?) as $node
                | if $node == null then
                    null
                  elif $node.type == "PARALLEL" then
                    $node
                  else
                    nearest_parallel($node.firstParent)
                  end
            end;

        ($stages | map(select(.name == $wrapper)) | first) as $wrapper_entry
        | if ($wrapper_entry | type) == "null" or (($wrapper_entry.id // "") == "") then
            {}
          else
            ($nodes | map(select(.type == "PARALLEL" and .firstParent == ($wrapper_entry.id | tostring))) | map({(.id): .name}) | add // {}) as $branch_by_id
            | reduce $branches[] as $branch (
                ($branches | map({(.): []}) | add // {});
                .[$branch] = (
                    $stages
                    | map(select((.id // "") != "" and .name != $wrapper and .name != $branch))
                    | map(
                        . as $stage
                        | (nearest_parallel(($stage.id | tostring))) as $parallel
                        | select($parallel != null and ($branch_by_id[$parallel.id] // "") == $branch)
                        | $stage
                    )
                    | sort_by(.startTimeMillis, .name)
                    | map(.name)
                )
            )
          end
        '
}

_extract_agent_before_console_marker() {
    local console_output="$1"
    local marker="$2"

    if [[ -z "$console_output" || -z "$marker" ]]; then
        return 0
    fi

    printf "%s\n" "$console_output" | awk -v marker="$marker" '
        /Running on[[:space:]]+.+[[:space:]]+in[[:space:]]+\// {
            agent = $0
            sub(/^.*Running on[[:space:]]+/, "", agent)
            sub(/[[:space:]]+in[[:space:]]+\/.*$/, "", agent)
            last_agent = agent
        }

        index($0, marker) {
            if (last_agent != "") {
                print last_agent
            }
            exit
        }
    ' || true
}

_detect_parallel_branch_agent_from_blue_ocean() {
    local job_name="$1"
    local build_number="$2"
    local branch_node_id="$3"
    local console_output="$4"
    local pipeline_scope_agent="$5"

    if [[ -z "$branch_node_id" ]]; then
        echo "$pipeline_scope_agent"
        return 0
    fi

    local steps_json
    steps_json=$(get_blue_ocean_node_steps "$job_name" "$build_number" "$branch_node_id" 2>/dev/null) || steps_json="[]"
    if [[ -z "$steps_json" || "$steps_json" == "[]" ]]; then
        echo "$pipeline_scope_agent"
        return 0
    fi

    local has_branch_local_setup
    has_branch_local_setup=$(echo "$steps_json" | jq -r 'map(select(.displayName == "Check out from version control")) | length > 0')
    if [[ "$has_branch_local_setup" != "true" ]]; then
        echo "$pipeline_scope_agent"
        return 0
    fi

    local marker agent
    marker=$(echo "$steps_json" | jq -r 'map(select(.displayDescription != "")) | .[0].displayDescription // empty')
    agent=$(_extract_agent_before_console_marker "$console_output" "$marker")
    if [[ -n "$agent" ]]; then
        echo "$agent"
    else
        echo "$pipeline_scope_agent"
    fi
}

# Get nested stages for a build, recursively expanding downstream builds
# Usage: _get_nested_stages "job-name" "build-number" [prefix] [nesting_depth] [parent_stage] [parallel_path]
# Returns: JSON array of stage objects with nested stage metadata
_get_nested_stages() {
    local job_name="$1"
    local build_number="$2"
    local prefix="${3:-}"
    local nesting_depth="${4:-0}"
    local parent_stage_name="${5:-}"
    local inherited_parallel_path="${6:-}"

    local stages_json
    stages_json=$(get_all_stages "$job_name" "$build_number")
    if [[ -z "$stages_json" || "$stages_json" == "[]" ]]; then
        echo "[]"
        return 0
    fi

    local console_output
    console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || true
    local blue_nodes_json
    blue_nodes_json=$(get_blue_ocean_nodes "$job_name" "$build_number" 2>/dev/null) || blue_nodes_json="[]"

    local stage_agent_map="{}"
    local pipeline_scope_agent=""
    if [[ -n "$console_output" ]]; then
        stage_agent_map=$(_build_stage_agent_map "$console_output")
        pipeline_scope_agent=$(_extract_pre_stage_agent_from_console "$console_output")
    fi

    local parallel_info="{}"
    local _branch_to_wrapper="{}"
    local _branch_to_path="{}"
    local _branch_to_local_substages="{}"
    local _substage_to_branch="{}"
    local _branch_to_blue_node_id="{}"
    local _wrapper_last_branch_index="{}"
    local _branch_aggregate_duration="{}"
    if [[ -n "$console_output" ]]; then
        local stage_count_for_parallel
        stage_count_for_parallel=$(echo "$stages_json" | jq 'length')
        local pi=0
        while [[ $pi -lt $stage_count_for_parallel ]]; do
            local pi_stage_name
            pi_stage_name=$(echo "$stages_json" | jq -r ".[$pi].name")
            local branches
            branches=$(_detect_parallel_branches "$console_output" "$pi_stage_name")
            if [[ -n "$branches" && "$branches" != "[]" ]]; then
                local branch_substages
                branch_substages=$(_detect_branch_substages "$console_output" "$pi_stage_name")
                if [[ "$blue_nodes_json" != "[]" ]]; then
                    local blue_branch_substages
                    blue_branch_substages=$(_detect_branch_substages_from_blue_ocean "$stages_json" "$blue_nodes_json" "$pi_stage_name" "$branches")
                    if [[ -n "$blue_branch_substages" && "$blue_branch_substages" != "{}" ]]; then
                        branch_substages="$blue_branch_substages"
                    fi
                fi
                parallel_info=$(echo "$parallel_info" | jq \
                    --arg s "$pi_stage_name" \
                    --argjson b "$branches" \
                    '. + {($s): {"branches": $b}}')

                local branch_index=1
                local max_branch_idx=-1
                local branch_name
                while IFS= read -r branch_name; do
                    [[ -z "$branch_name" ]] && continue
                    _branch_to_wrapper=$(echo "$_branch_to_wrapper" | jq \
                        --arg b "$branch_name" --arg w "$pi_stage_name" '. + {($b): $w}')
                    if [[ "$blue_nodes_json" != "[]" ]]; then
                        local branch_blue_node_id
                        branch_blue_node_id=$(echo "$blue_nodes_json" | jq -r \
                            --arg wrapper "$pi_stage_name" \
                            --arg branch "$branch_name" \
                            --argjson stages "$stages_json" '
                                ($stages | map(select(.name == $wrapper)) | first | .id // "") as $wrapper_id
                                | if $wrapper_id == "" then
                                    ""
                                  else
                                    [.[] | select(.type == "PARALLEL" and .firstParent == ($wrapper_id | tostring) and .name == $branch)][0].id // ""
                                  end
                            ')
                        if [[ -n "$branch_blue_node_id" ]]; then
                            _branch_to_blue_node_id=$(echo "$_branch_to_blue_node_id" | jq \
                                --arg b "$branch_name" \
                                --arg id "$branch_blue_node_id" \
                                '. + {($b): $id}')
                        fi
                    fi
                    local branch_path="$branch_index"
                    if [[ -n "$inherited_parallel_path" ]]; then
                        branch_path="${inherited_parallel_path}.${branch_index}"
                    fi
                    _branch_to_path=$(echo "$_branch_to_path" | jq \
                        --arg b "$branch_name" --arg p "$branch_path" '. + {($b): $p}')
                    local branch_local_substages
                    branch_local_substages=$(echo "${branch_substages:-{}}" | jq --arg b "$branch_name" '.[$b] // []')
                    _branch_to_local_substages=$(echo "$_branch_to_local_substages" | jq \
                        --arg b "$branch_name" \
                        --argjson substages "$branch_local_substages" \
                        '. + {($b): $substages}')
                    while IFS= read -r substage_name; do
                        [[ -z "$substage_name" ]] && continue
                        _substage_to_branch=$(echo "$_substage_to_branch" | jq \
                            --arg s "$substage_name" \
                            --arg b "$branch_name" \
                            '. + {($s): $b}')
                    done <<< "$(echo "$branch_local_substages" | jq -r '.[]')"

                    local branch_pos
                    branch_pos=$(echo "$stages_json" | jq -r --arg n "$branch_name" 'to_entries[] | select(.value.name == $n) | .key' | head -1)
                    if [[ "$branch_pos" =~ ^[0-9]+$ && "$branch_pos" -gt "$max_branch_idx" ]]; then
                        max_branch_idx="$branch_pos"
                    fi
                    branch_index=$((branch_index + 1))
                done <<< "$(echo "$branches" | jq -r '.[]')"
                if [[ "$max_branch_idx" -ge 0 ]]; then
                    _wrapper_last_branch_index=$(echo "$_wrapper_last_branch_index" | jq \
                        --arg w "$pi_stage_name" --argjson idx "$max_branch_idx" '. + {($w): $idx}')
                fi
            fi
            pi=$((pi + 1))
        done
    fi

    local branch_name
    while IFS= read -r branch_name; do
        [[ -z "$branch_name" ]] && continue
        local branch_duration aggregate_duration
        branch_duration=$(echo "$stages_json" | jq -r --arg n "$branch_name" '[.[] | select(.name == $n)][0].durationMillis // 0')
        aggregate_duration="$branch_duration"
        if ! [[ "$aggregate_duration" =~ ^[0-9]+$ ]]; then
            aggregate_duration=0
        fi

        local branch_local_substages
        branch_local_substages=$(echo "$_branch_to_local_substages" | jq -r --arg b "$branch_name" '.[$b] // [] | .[]')
        local substage_name
        while IFS= read -r substage_name; do
            [[ -z "$substage_name" ]] && continue
            local substage_duration
            substage_duration=$(echo "$stages_json" | jq -r --arg n "$substage_name" '[.[] | select(.name == $n)][0].durationMillis // 0')
            if [[ "$substage_duration" =~ ^[0-9]+$ ]]; then
                aggregate_duration=$((aggregate_duration + substage_duration))
            fi
        done <<< "$branch_local_substages"

        _branch_aggregate_duration=$(echo "$_branch_aggregate_duration" | jq \
            --arg b "$branch_name" \
            --argjson d "$aggregate_duration" \
            '. + {($b): $d}')
    done <<< "$(echo "$_branch_to_wrapper" | jq -r 'keys[]?')"

    local stage_downstream_map="{}"
    if [[ -n "$console_output" ]]; then
        local filtered_stages_json
        if [[ "$parallel_info" != "{}" ]]; then
            filtered_stages_json=$(echo "$stages_json" | jq --argjson pi "$parallel_info" \
                '[.[] | select(.name as $n | $pi | has($n) | not)]')
        else
            filtered_stages_json="$stages_json"
        fi
        stage_downstream_map=$(_map_stages_to_downstream "$console_output" "$filtered_stages_json")
    fi

    local result="[]"
    local deferred_wrappers="{}"
    local stage_count
    stage_count=$(echo "$stages_json" | jq 'length')

    local i=0
    while [[ $i -lt $stage_count ]]; do
        local stage_name status duration_ms
        stage_name=$(echo "$stages_json" | jq -r ".[$i].name")
        status=$(echo "$stages_json" | jq -r ".[$i].status")
        duration_ms=$(echo "$stages_json" | jq -r ".[$i].durationMillis")

        local local_parent_branch
        local_parent_branch=$(echo "$_substage_to_branch" | jq -r --arg s "$stage_name" '.[$s] // empty')
        if [[ -n "$local_parent_branch" && "$local_parent_branch" != "null" ]]; then
            i=$((i + 1))
            continue
        fi

        local stage_agent=""
        if [[ "$stage_agent_map" != "{}" ]]; then
            stage_agent=$(echo "$stage_agent_map" | jq -r --arg s "$stage_name" '.[$s] // empty')
        fi
        if [[ -z "$stage_agent" && -n "$pipeline_scope_agent" ]]; then
            stage_agent="$pipeline_scope_agent"
        fi

        local is_parallel_wrapper="false"
        local parallel_branches_json="null"
        local parallel_branch=""
        local parallel_wrapper=""
        local stage_parallel_path="$inherited_parallel_path"

        local wrapper_check
        wrapper_check=$(echo "$parallel_info" | jq -r --arg s "$stage_name" 'has($s)') || wrapper_check="false"
        if [[ "$wrapper_check" == "true" ]]; then
            is_parallel_wrapper="true"
            stage_parallel_path=""
            parallel_branches_json=$(echo "$parallel_info" | jq --arg s "$stage_name" '.[$s].branches')
            local max_branch_dur=0
            local branch_name
            while IFS= read -r branch_name; do
                [[ -z "$branch_name" ]] && continue
                local bd
                bd=$(echo "$_branch_aggregate_duration" | jq -r --arg n "$branch_name" '.[$n] // 0')
                if [[ "$bd" =~ ^[0-9]+$ && "$bd" -gt "$max_branch_dur" ]]; then
                    max_branch_dur="$bd"
                fi
            done <<< "$(echo "$parallel_branches_json" | jq -r '.[]')"
            if [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
                duration_ms=$((duration_ms + max_branch_dur))
            fi
        fi

        local bw_check
        bw_check=$(echo "$_branch_to_wrapper" | jq -r --arg b "$stage_name" '.[$b] // empty')
        if [[ -n "$bw_check" && "$bw_check" != "null" ]]; then
            parallel_branch="$stage_name"
            parallel_wrapper="$bw_check"
            stage_parallel_path=$(echo "$_branch_to_path" | jq -r --arg b "$stage_name" '.[$b] // empty')
            duration_ms=$(echo "$_branch_aggregate_duration" | jq -r --arg b "$stage_name" '.[$b] // empty')
            if [[ -n "$blue_nodes_json" && "$blue_nodes_json" != "[]" ]]; then
                local branch_blue_node_id branch_agent_from_blue
                branch_blue_node_id=$(echo "$_branch_to_blue_node_id" | jq -r --arg b "$stage_name" '.[$b] // empty')
                branch_agent_from_blue=$(_detect_parallel_branch_agent_from_blue_ocean "$job_name" "$build_number" "$branch_blue_node_id" "$console_output" "$pipeline_scope_agent")
                if [[ -n "$branch_agent_from_blue" ]]; then
                    stage_agent="$branch_agent_from_blue"
                fi
            fi
        fi

        local ds_info
        ds_info=$(echo "$stage_downstream_map" | jq -r --arg s "$stage_name" '.[$s] // empty')

        local display_name
        if [[ -n "$prefix" ]]; then
            display_name="${prefix}->${stage_name}"
        else
            display_name="${stage_name}"
        fi

        local branch_local_substages_json="[]"
        if [[ -n "$parallel_branch" ]]; then
            branch_local_substages_json=$(echo "$_branch_to_local_substages" | jq --arg b "$stage_name" '.[$b] // []')
        fi

        if [[ "$branch_local_substages_json" != "[]" ]]; then
            local local_substage_name
            while IFS= read -r local_substage_name; do
                [[ -z "$local_substage_name" ]] && continue

                local local_substage_json local_substage_status local_substage_duration
                local_substage_json=$(echo "$stages_json" | jq -c --arg n "$local_substage_name" '[.[] | select(.name == $n)][0]')
                [[ -z "$local_substage_json" || "$local_substage_json" == "null" ]] && continue
                local_substage_status=$(echo "$local_substage_json" | jq -r '.status')
                local_substage_duration=$(echo "$local_substage_json" | jq -r '.durationMillis')

                local local_substage_agent=""
                if [[ "$stage_agent_map" != "{}" ]]; then
                    local_substage_agent=$(echo "$stage_agent_map" | jq -r --arg s "$local_substage_name" '.[$s] // empty')
                fi
                if [[ -z "$local_substage_agent" ]]; then
                    local_substage_agent="$stage_agent"
                fi
                if [[ -z "$local_substage_agent" && -n "$pipeline_scope_agent" ]]; then
                    local_substage_agent="$pipeline_scope_agent"
                fi

                local local_substage_display_name="${display_name}->${local_substage_name}"
                local local_substage_ds_info
                local_substage_ds_info=$(echo "$stage_downstream_map" | jq -r --arg s "$local_substage_name" '.[$s] // empty')
                if [[ -n "$local_substage_ds_info" && "$local_substage_ds_info" != "null" ]]; then
                    local ds_job ds_build nested_stages
                    ds_job=$(echo "$local_substage_ds_info" | jq -r '.job')
                    ds_build=$(echo "$local_substage_ds_info" | jq -r '.build')
                    nested_stages=$(_get_nested_stages "$ds_job" "$ds_build" "$local_substage_display_name" "$((nesting_depth + 1))" "$local_substage_name" "$stage_parallel_path" 2>/dev/null) || nested_stages="[]"

                    nested_stages=$(echo "$nested_stages" | jq \
                        --arg pb "$parallel_branch" \
                        --arg pw "$parallel_wrapper" \
                        --arg pp "$stage_parallel_path" \
                        '[.[] |
                            . + (if $pb != "" and ((.parallel_branch // "") == "") then {parallel_branch: $pb} else {} end)
                              + (if $pw != "" and ((.parallel_wrapper // "") == "") then {parallel_wrapper: $pw} else {} end)
                              + (if $pp != "" and ((.parallel_path // "") == "") then {parallel_path: $pp} else {} end)
                        ]')

                    if [[ "$nested_stages" != "[]" ]]; then
                        result=$(echo "$result" "$nested_stages" | jq -s '.[0] + .[1]')
                    fi
                fi

                local local_substage_entry
                local_substage_entry=$(jq -n \
                    --arg name "$local_substage_display_name" \
                    --arg status "$local_substage_status" \
                    --argjson duration_ms "$local_substage_duration" \
                    --arg agent "$local_substage_agent" \
                    --argjson nesting_depth "$nesting_depth" \
                    --arg parallel_branch "$parallel_branch" \
                    --arg parallel_wrapper "$parallel_wrapper" \
                    --arg parallel_path "${stage_parallel_path:-}" \
                    --arg parent_branch_stage "$stage_name" \
                    --argjson has_downstream "$(if [[ "$local_substage_ds_info" != "" && "$local_substage_ds_info" != "null" ]]; then echo true; else echo false; fi)" \
                    '{
                        name: $name,
                        status: $status,
                        durationMillis: $duration_ms,
                        agent: $agent,
                        nesting_depth: $nesting_depth,
                        has_downstream: $has_downstream,
                        parent_branch_stage: $parent_branch_stage
                    }
                    + (if $parallel_branch != "" then {parallel_branch: $parallel_branch, parallel_wrapper: $parallel_wrapper} else {} end)
                    + (if $parallel_path != "" then {parallel_path: $parallel_path} else {} end)')
                result=$(echo "$result" | jq --argjson entry "$local_substage_entry" '. + [$entry]')
            done <<< "$(echo "$branch_local_substages_json" | jq -r '.[]')"
        fi

        local nested_stages="[]"
        if [[ -n "$ds_info" && "$ds_info" != "null" ]]; then
            local ds_job ds_build
            ds_job=$(echo "$ds_info" | jq -r '.job')
            ds_build=$(echo "$ds_info" | jq -r '.build')
            nested_stages=$(_get_nested_stages "$ds_job" "$ds_build" "$display_name" "$((nesting_depth + 1))" "$stage_name" "$stage_parallel_path" 2>/dev/null) || nested_stages="[]"

            if [[ -n "$parallel_branch" ]]; then
                nested_stages=$(echo "$nested_stages" | jq \
                    --arg pb "$parallel_branch" \
                    --arg pw "$parallel_wrapper" \
                    --arg pp "$stage_parallel_path" \
                    '[.[] |
                        . + (if ((.parallel_branch // "") == "") then {parallel_branch: $pb} else {} end)
                          + (if $pw != "" and ((.parallel_wrapper // "") == "") then {parallel_wrapper: $pw} else {} end)
                          + (if $pp != "" and ((.parallel_path // "") == "") then {parallel_path: $pp} else {} end)
                    ]')
            fi

            if [[ "$nested_stages" != "[]" ]]; then
                result=$(echo "$result" "$nested_stages" | jq -s '.[0] + .[1]')
            fi
        fi

        local stage_entry
        if [[ $nesting_depth -gt 0 ]]; then
            stage_entry=$(jq -n \
                --arg name "$display_name" \
                --arg status "$status" \
                --argjson duration_ms "$duration_ms" \
                --arg agent "$stage_agent" \
                --argjson nesting_depth "$nesting_depth" \
                --arg downstream_job "$job_name" \
                --argjson downstream_build "$build_number" \
                --arg parent_stage "$parent_stage_name" \
                --arg parallel_branch "${parallel_branch:-}" \
                --arg parallel_wrapper "${parallel_wrapper:-}" \
                --arg parallel_path "${stage_parallel_path:-}" \
                --argjson has_downstream "$(if [[ "$ds_info" != "" && "$ds_info" != "null" ]]; then echo true; else echo false; fi)" \
                '{
                    name: $name,
                    status: $status,
                    durationMillis: $duration_ms,
                    agent: $agent,
                    nesting_depth: $nesting_depth,
                    downstream_job: $downstream_job,
                    downstream_build: $downstream_build,
                    parent_stage: $parent_stage,
                    has_downstream: $has_downstream
                }
                + (if $parallel_branch != "" then {parallel_branch: $parallel_branch} else {} end)
                + (if $parallel_wrapper != "" then {parallel_wrapper: $parallel_wrapper} else {} end)
                + (if $parallel_path != "" then {parallel_path: $parallel_path} else {} end)')
        else
            stage_entry=$(jq -n \
                --arg name "$display_name" \
                --arg status "$status" \
                --argjson duration_ms "$duration_ms" \
                --arg agent "$stage_agent" \
                --argjson nesting_depth "$nesting_depth" \
                --argjson is_parallel_wrapper "$is_parallel_wrapper" \
                --argjson parallel_branches "${parallel_branches_json:-null}" \
                --arg parallel_branch "$parallel_branch" \
                --arg parallel_wrapper "$parallel_wrapper" \
                --arg parallel_path "${stage_parallel_path:-}" \
                --argjson has_downstream "$(if [[ "$ds_info" != "" && "$ds_info" != "null" ]]; then echo true; else echo false; fi)" \
                '{
                    name: $name,
                    status: $status,
                    durationMillis: $duration_ms,
                    agent: $agent,
                    nesting_depth: $nesting_depth,
                    has_downstream: $has_downstream
                }
                + (if $is_parallel_wrapper == true then {is_parallel_wrapper: true, parallel_branches: $parallel_branches} else {} end)
                + (if $parallel_branch != "" then {parallel_branch: $parallel_branch, parallel_wrapper: $parallel_wrapper} else {} end)
                + (if $parallel_path != "" then {parallel_path: $parallel_path} else {} end)')
        fi

        if [[ "$is_parallel_wrapper" == "true" ]]; then
            local wrapper_emit_after_idx
            wrapper_emit_after_idx=$(echo "$_wrapper_last_branch_index" | jq -r --arg w "$stage_name" '.[$w] // empty' 2>/dev/null)
            if [[ "$wrapper_emit_after_idx" =~ ^[0-9]+$ && "$i" -ge "$wrapper_emit_after_idx" ]]; then
                result=$(echo "$result" | jq --argjson entry "$stage_entry" '. + [$entry]')
            else
                deferred_wrappers=$(echo "$deferred_wrappers" | jq --arg w "$stage_name" --argjson e "$stage_entry" '. + {($w): $e}')
            fi
        else
            result=$(echo "$result" | jq --argjson entry "$stage_entry" '. + [$entry]')
        fi

        local wrappers_to_emit
        wrappers_to_emit=$(echo "$_wrapper_last_branch_index" | jq -r --argjson idx "$i" \
            'to_entries[] | select(.value == $idx) | .key' 2>/dev/null) || true
        while IFS= read -r emit_wrapper; do
            [[ -z "$emit_wrapper" ]] && continue
            local wrapper_entry
            wrapper_entry=$(echo "$deferred_wrappers" | jq -c --arg w "$emit_wrapper" '.[$w] // empty')
            if [[ -n "$wrapper_entry" && "$wrapper_entry" != "null" ]]; then
                result=$(echo "$result" | jq --argjson entry "$wrapper_entry" '. + [$entry]')
                deferred_wrappers=$(echo "$deferred_wrappers" | jq --arg w "$emit_wrapper" 'del(.[$w])')
            fi
        done <<< "$wrappers_to_emit"

        i=$((i + 1))
    done

    local remaining_wrappers
    remaining_wrappers=$(echo "$deferred_wrappers" | jq -r 'keys[]?' 2>/dev/null) || true
    while IFS= read -r rw; do
        [[ -z "$rw" ]] && continue
        local rw_entry
        rw_entry=$(echo "$deferred_wrappers" | jq -c --arg w "$rw" '.[$w] // empty')
        if [[ -n "$rw_entry" && "$rw_entry" != "null" ]]; then
            result=$(echo "$result" | jq --argjson entry "$rw_entry" '. + [$entry]')
        fi
    done <<< "$remaining_wrappers"

    echo "$result"
}
