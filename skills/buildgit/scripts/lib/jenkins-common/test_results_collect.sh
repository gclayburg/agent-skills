# =============================================================================
# Test Results Functions
# =============================================================================

# Track builds that already emitted a test-results communication warning.
_TEST_RESULTS_WARNED_BUILDS=""

_test_results_warn_key() {
    local job_name="$1"
    local build_number="$2"
    echo "${job_name}#${build_number}"
}

_note_test_results_comm_failure() {
    local job_name="$1"
    local build_number="$2"
    local key
    key=$(_test_results_warn_key "$job_name" "$build_number")
    if [[ ",${_TEST_RESULTS_WARNED_BUILDS}," == *",${key},"* ]]; then
        return 0
    fi
    _TEST_RESULTS_WARNED_BUILDS="${_TEST_RESULTS_WARNED_BUILDS},${key}"
    log_error "Could not retrieve test results (communication error)"
}

display_test_results_comm_error() {
    local warning_text="⚠ Communication error retrieving test results"
    if [[ -n "${COLOR_YELLOW}" ]]; then
        warning_text="${COLOR_YELLOW}${warning_text}${COLOR_RESET}"
    fi
    echo ""
    echo "Test Results: ${warning_text}"
}

# Fetch test results from Jenkins test report API
# Usage: fetch_test_results "job-name" "build-number"
# Returns: JSON test report on success, empty string if not available
# Spec: test-failure-display-spec.md, Section: Test Report Detection (1.1-1.2)
fetch_test_results() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo ""
        return 0
    fi

    local response
    local http_code
    local body

    # Query the test report API
    response=$(jenkins_api_with_status "${job_path}/${build_number}/testReport/api/json" || true)

    # Split response into body and status code
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
        http_code="000"
    fi

    case "$http_code" in
        200)
            # Test report available - return the JSON
            echo "$body"
            return 0
            ;;
        404)
            # No test report available - silently return empty
            # This is expected for builds without junit results
            echo ""
            return 0
            ;;
        000)
            # Communication failure (DNS/network/sandbox/connection issue)
            echo ""
            return 2
            ;;
        *)
            # Other HTTP errors are treated as communication failures
            echo ""
            return 2
            ;;
    esac
}

_map_downstream_stage_labels() {
    local console_output="$1"
    local stages_json="$2"

    local result="{}"
    local claimed_positive_downstreams="{}"
    local stage_count
    stage_count=$(echo "$stages_json" | jq 'length' 2>/dev/null) || stage_count=0

    local i=0
    while [[ "$i" -lt "$stage_count" ]]; do
        local stage_name
        stage_name=$(echo "$stages_json" | jq -r ".[$i].name // empty" 2>/dev/null)
        i=$((i + 1))
        [[ -z "$stage_name" ]] && continue

        local stage_logs downstream selected_downstream ds_job ds_build
        stage_logs=$(extract_stage_logs "$console_output" "$stage_name")
        [[ -z "$stage_logs" ]] && continue

        downstream=$(detect_all_downstream_builds "$stage_logs")
        [[ -z "$downstream" ]] && continue

        selected_downstream=$(_select_downstream_build_for_stage "$stage_name" "$downstream" "$stage_logs")
        ds_job=$(echo "$selected_downstream" | awk '{print $1}')
        ds_build=$(echo "$selected_downstream" | awk '{print $2}')
        [[ -z "$ds_job" || -z "$ds_build" ]] && continue

        local downstream_key selected_score already_claimed_by_positive
        downstream_key="${ds_job}#${ds_build}"
        selected_score=$(_downstream_stage_job_match_score "$stage_name" "$ds_job")
        already_claimed_by_positive=$(echo "$claimed_positive_downstreams" | jq -r --arg key "$downstream_key" '.[$key] // false' 2>/dev/null)
        if [[ "$selected_score" -le 0 && "$already_claimed_by_positive" == "true" ]]; then
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
    done

    echo "$result"
}

_find_downstream_stage_label() {
    local downstream_job="$1"
    local downstream_build="$2"
    local stage_map_json="$3"
    local stages_json="$4"

    local mapped_stage
    mapped_stage=$(echo "$stage_map_json" | jq -r \
        --arg job "$downstream_job" \
        --argjson build "$downstream_build" \
        'to_entries[]
         | select(.value.job == $job and (.value.build // 0) == $build)
         | .key' 2>/dev/null | head -1)

    if [[ -n "$mapped_stage" && "$mapped_stage" != "null" ]]; then
        echo "$mapped_stage"
        return 0
    fi

    local stage_count
    stage_count=$(echo "$stages_json" | jq 'length' 2>/dev/null) || stage_count=0

    local best_stage=""
    local best_score=0
    local i=0
    while [[ "$i" -lt "$stage_count" ]]; do
        local stage_name score
        stage_name=$(echo "$stages_json" | jq -r ".[$i].name // empty" 2>/dev/null)
        i=$((i + 1))
        [[ -z "$stage_name" ]] && continue
        score=$(_downstream_stage_job_match_score "$stage_name" "$downstream_job")
        if [[ "$score" -gt "$best_score" ]]; then
            best_stage="$stage_name"
            best_score="$score"
        fi
    done

    if [[ -n "$best_stage" ]]; then
        echo "$best_stage"
    else
        echo "$downstream_job"
    fi
}

# Merge two JSON arrays without passing payloads on the command line (ARG_MAX safe).
# Usage: _jq_merge_json_arrays "$left" "$right"
# Prints merged compact JSON array on stdout.
_jq_merge_json_arrays() {
    local left="${1:-[]}"
    local right="${2:-[]}"

    if [[ -z "$left" || "$left" == "null" ]]; then
        left='[]'
    fi
    if [[ -z "$right" || "$right" == "null" ]]; then
        right='[]'
    fi

    if [[ "$left" == "[]" ]]; then
        printf '%s' "$right"
        return 0
    fi
    if [[ "$right" == "[]" ]]; then
        printf '%s' "$left"
        return 0
    fi

    { printf '%s' "$left"; printf '%s' "$right"; } | jq -c -s 'add'
}

# Build a JSON object with two large JSON-valued fields (ARG_MAX safe).
# Usage: _jq_object_with_json_fields total passed failed skipped failed_tests_json breakdown_json
# Prints compact JSON object on stdout.
_jq_object_with_json_fields() {
    local total="$1" passed="$2" failed="$3" skipped="$4"
    local failed_tests_json="$5" breakdown_json="$6"
    local failed_file breakdown_file

    failed_file=$(mktemp "${TMPDIR:-/tmp}/buildgit-failed.XXXXXX")
    breakdown_file=$(mktemp "${TMPDIR:-/tmp}/buildgit-breakdown.XXXXXX")
    printf '%s' "${failed_tests_json:-[]}" > "$failed_file"
    printf '%s' "${breakdown_json:-[]}" > "$breakdown_file"

    jq -cn \
        --argjson total "$total" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson skipped "$skipped" \
        --slurpfile failed_tests "$failed_file" \
        --slurpfile breakdown "$breakdown_file" \
        '{
            total: $total,
            passed: $passed,
            failed: $failed,
            skipped: $skipped,
            failed_tests: $failed_tests[0],
            breakdown: $breakdown[0]
        }'

    rm -f "$failed_file" "$breakdown_file"
}

# Build test-results JSON with a large failed_tests array (ARG_MAX safe).
# Usage: _jq_test_results_object total passed failed skipped failed_tests_json
_jq_test_results_object() {
    local total="$1" passed="$2" failed="$3" skipped="$4"
    local failed_tests_json="$5"
    local failed_file

    failed_file=$(mktemp "${TMPDIR:-/tmp}/buildgit-failed.XXXXXX")
    printf '%s' "${failed_tests_json:-[]}" > "$failed_file"

    jq -cn \
        --argjson total "$total" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson skipped "$skipped" \
        --slurpfile failed_tests "$failed_file" \
        '{
            total: $total,
            passed: $passed,
            failed: $failed,
            skipped: $skipped,
            failed_tests: $failed_tests[0]
        }'

    rm -f "$failed_file"
}

_collect_downstream_test_results_recursive() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"
    local depth="$4"
    local stage_label="$5"
    local is_root="${6:-false}"

    local test_json="" fetch_rc=0
    if test_json=$(fetch_test_results "$job_name" "$build_number"); then
        fetch_rc=0
    else
        fetch_rc=$?
        test_json=""
    fi

    if [[ "$fetch_rc" -eq 2 && "$is_root" == "true" ]]; then
        return 2
    fi

    local collected_json
    collected_json=$(printf '%s' "$test_json" | jq -Rsc \
        --arg job "$job_name" \
        --arg stage "${stage_label:-$job_name}" \
        --argjson build_number "$build_number" \
        --argjson depth "$depth" \
        '[{
            job: $job,
            stage: $stage,
            build_number: $build_number,
            depth: $depth,
            test_json: .
        }]')

    local downstream_lines
    downstream_lines=$(detect_all_downstream_builds "$console_output")
    if [[ -z "$downstream_lines" ]]; then
        echo "$collected_json"
        return 0
    fi

    local stages_json stage_map_json
    stages_json=$(get_all_stages "$job_name" "$build_number")
    stage_map_json=$(_map_downstream_stage_labels "$console_output" "$stages_json")

    while IFS=' ' read -r downstream_job downstream_build; do
        [[ -z "$downstream_job" || -z "$downstream_build" ]] && continue

        local downstream_stage downstream_console child_json
        downstream_stage=$(_find_downstream_stage_label "$downstream_job" "$downstream_build" "$stage_map_json" "$stages_json")
        downstream_console=$(get_console_output "$downstream_job" "$downstream_build" 2>/dev/null || true)
        child_json=$(_collect_downstream_test_results_recursive \
            "$downstream_job" \
            "$downstream_build" \
            "$downstream_console" \
            "$((depth + 1))" \
            "$downstream_stage" \
            "false")

        collected_json=$(_jq_merge_json_arrays "$collected_json" "$child_json")
    done <<< "$downstream_lines"

    echo "$collected_json"
}

# Collect test results for a build and any downstream builds detected from console output.
# Usage: collect_downstream_test_results "job-name" "build-number" "console-output"
# Returns: JSON array of per-job test result objects on stdout.
#          Each object has: job, stage, build_number, depth, test_json
#          The first array element is always the parent build.
# Exit code: 0 on success, 2 if the parent build had a communication error.
collect_downstream_test_results() {
    local job_name="$1"
    local build_number="$2"
    local console_output="$3"

    _collect_downstream_test_results_recursive "$job_name" "$build_number" "$console_output" 0 "$job_name" "true"
}

# Aggregate totals across collected downstream test results.
# Usage: aggregate_test_totals "$collected_results_json"
# Returns: Four lines on stdout: total_sum, passed_sum, failed_sum, skipped_sum
aggregate_test_totals() {
    local results_json="$1"

    echo "$results_json" | jq -r '
        [.[] | select(.test_json != "") | .test_json | fromjson |
            {p: (.passCount // 0), f: (.failCount // 0), s: (.skipCount // 0)}] |
        {total: (map(.p + .f + .s) | add // 0),
         passed: (map(.p) | add // 0),
         failed: (map(.f) | add // 0),
         skipped: (map(.s) | add // 0)} |
        "\(.total)\n\(.passed)\n\(.failed)\n\(.skipped)"
    '
}

# Check whether collected test results include downstream builds.
# Usage: has_downstream_builds "$collected_results_json"
# Returns: 0 when downstream builds exist, 1 otherwise.
has_downstream_builds() {
    local results_json="$1"
    local count
    count=$(echo "$results_json" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -gt 1 ]]
}

_indent_spaces() {
    local count="$1"
    local spaces=""
    local i=0

    while [[ "$i" -lt "$count" ]]; do
        spaces="${spaces} "
        i=$((i + 1))
    done

    printf '%s' "$spaces"
}

_format_hierarchical_test_results_line() {
    local label="$1"
    local label_width="$2"
    local job_name="$3"
    local job_width="$4"
    local total="$5"
    local total_width="$6"
    local passed="$7"
    local passed_width="$8"
    local failed="$9"
    local failed_width="${10}"
    local skipped="${11}"
    local skipped_width="${12}"

    local formatted_line=""
    printf -v formatted_line \
        "%-*s  %-*s  %*s  %*s/%*s/%*s" \
        "$label_width" "$label" \
        "$job_width" "$job_name" \
        "$total_width" "$total" \
        "$passed_width" "$passed" \
        "$failed_width" "$failed" \
        "$skipped_width" "$skipped"

    echo "$formatted_line"
}

_display_failed_tests_array() {
    local failed_tests="$1"
    local total_failures="$2"
    local section_color="$3"

    local max_display="${MAX_FAILED_TESTS_DISPLAY:-10}"
    local max_error_lines="${MAX_ERROR_LINES:-5}"
    local verbose_mode=false
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        verbose_mode=true
    fi

    failed_tests=$(echo "$failed_tests" | jq --argjson max_display "$max_display" '.[:$max_display]')

    echo ""
    echo "  ${COLOR_RED}FAILED TESTS:${COLOR_RESET}"

    local test_count
    test_count=$(echo "$failed_tests" | jq 'length')

    local i=0
    while [[ "$i" -lt "$test_count" ]]; do
        local class_name test_name error_details error_stack stdout_text age

        class_name=$(echo "$failed_tests" | jq -r ".[$i].className")
        test_name=$(echo "$failed_tests" | jq -r ".[$i].name")
        error_details=$(echo "$failed_tests" | jq -r ".[$i].errorDetails // empty")
        error_stack=$(echo "$failed_tests" | jq -r ".[$i].errorStackTrace // empty")
        stdout_text=$(echo "$failed_tests" | jq -r ".[$i].stdout // empty")
        age=$(echo "$failed_tests" | jq -r ".[$i].age // 0")

        local age_suffix=""
        if [[ "$age" -gt 1 ]]; then
            age_suffix=" ${COLOR_YELLOW}(failing for ${age} builds)${COLOR_RESET}"
        fi

        echo "  ${COLOR_RED}✗${COLOR_RESET} ${class_name}::${test_name}${age_suffix}"

        if [[ -n "$error_details" && "$error_details" != "null" ]]; then
            echo "    Error: ${error_details}"
        fi

        if [[ -n "$error_stack" && "$error_stack" != "null" ]]; then
            local line_count
            line_count=$(echo "$error_stack" | wc -l | tr -d ' ')

            if [[ "$verbose_mode" == "true" || "$line_count" -le "$max_error_lines" ]]; then
                echo "$error_stack" | while IFS= read -r line; do
                    echo "    ${line}"
                done
            else
                echo "$error_stack" | head -"$max_error_lines" | while IFS= read -r line; do
                    echo "    ${line}"
                done
                echo "    ..."
            fi
        fi

        if [[ "$verbose_mode" == "true" && -n "$stdout_text" && "$stdout_text" != "null" ]]; then
            echo "    Stdout:"
            echo "$stdout_text" | while IFS= read -r line; do
                echo "      ${line}"
            done
        fi

        i=$((i + 1))
    done

    if [[ "$total_failures" -gt "$max_display" ]]; then
        local remaining=$((total_failures - max_display))
        echo "  ${COLOR_YELLOW}... and ${remaining} more failed tests${COLOR_RESET}"
    fi

    echo "${section_color}====================${COLOR_RESET}"
}

display_hierarchical_test_results() {
    local collected_json="$1"

    if ! has_downstream_builds "$collected_json"; then
        local parent_test_json
        parent_test_json=$(echo "$collected_json" | jq -r '.[0].test_json // empty')
        display_test_results "$parent_test_json"
        return 0
    fi

    local totals total_sum passed_sum failed_sum skipped_sum
    totals=$(aggregate_test_totals "$collected_json")
    total_sum=$(echo "$totals" | sed -n '1p')
    passed_sum=$(echo "$totals" | sed -n '2p')
    failed_sum=$(echo "$totals" | sed -n '3p')
    skipped_sum=$(echo "$totals" | sed -n '4p')

    local section_color="${COLOR_GREEN}"
    if [[ "$failed_sum" -gt 0 ]]; then
        section_color="${COLOR_YELLOW}"
    fi

    local count
    count=$(echo "$collected_json" | jq 'length')

    local -a line_labels line_jobs line_colors line_totals line_passed line_failed line_skipped
    local max_label_width=6
    local max_job_width=0
    local max_total_width=5   # "Total" header word is 5 chars minimum
    local max_passed_width=${#passed_sum}
    local max_failed_width=${#failed_sum}
    local max_skipped_width=${#skipped_sum}

    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local stage_label depth job build_number test_json indent label job_display summary total passed failed skipped line_color

        stage_label=$(echo "$collected_json" | jq -r ".[$i].stage // .[$i].job // empty")
        depth=$(echo "$collected_json" | jq -r ".[$i].depth // 0")
        job=$(echo "$collected_json" | jq -r ".[$i].job // empty")
        build_number=$(echo "$collected_json" | jq -r ".[$i].build_number // empty")
        test_json=$(echo "$collected_json" | jq -r ".[$i].test_json // empty")
        indent=$(_indent_spaces $((depth * 2)))
        label="${indent}${stage_label}"
        job_display="${job} #${build_number}"

        if [[ -z "$test_json" ]]; then
            total="?"
            passed="?"
            failed="?"
            skipped="?"
            line_color=""
        else
            summary=$(parse_test_summary "$test_json")
            total=$(echo "$summary" | sed -n '1p')
            passed=$(echo "$summary" | sed -n '2p')
            failed=$(echo "$summary" | sed -n '3p')
            skipped=$(echo "$summary" | sed -n '4p')

            if [[ "$failed" -gt 0 ]]; then
                line_color="${COLOR_YELLOW}"
            else
                line_color="${COLOR_GREEN}"
            fi
        fi

        line_labels[$i]="$label"
        line_jobs[$i]="$job_display"
        line_colors[$i]="$line_color"
        line_totals[$i]="$total"
        line_passed[$i]="$passed"
        line_failed[$i]="$failed"
        line_skipped[$i]="$skipped"

        if [[ "${#label}" -gt "$max_label_width" ]]; then
            max_label_width=${#label}
        fi
        if [[ "${#job_display}" -gt "$max_job_width" ]]; then
            max_job_width=${#job_display}
        fi
        if [[ "${#total}" -gt "$max_total_width" ]]; then
            max_total_width=${#total}
        fi
        if [[ "${#passed}" -gt "$max_passed_width" ]]; then
            max_passed_width=${#passed}
        fi
        if [[ "${#failed}" -gt "$max_failed_width" ]]; then
            max_failed_width=${#failed}
        fi
        if [[ "${#skipped}" -gt "$max_skipped_width" ]]; then
            max_skipped_width=${#skipped}
        fi

        i=$((i + 1))
    done

    # Header: right-align "Total" over the total column, then append P/F/S label
    local header_padding
    header_padding=$((max_label_width + 2 + max_job_width + 2 + max_total_width - 19))
    if [[ "$header_padding" -lt 6 ]]; then
        header_padding=6
    fi
    local header_line
    printf -v header_line "=== Test Results ===%${header_padding}s  Passed/Failed/Skipped" "Total"
    echo ""
    echo "${section_color}${header_line}${COLOR_RESET}"

    i=0
    while [[ "$i" -lt "$count" ]]; do
        local rendered_line
        rendered_line=$(_format_hierarchical_test_results_line \
            "${line_labels[$i]}" "$max_label_width" \
            "${line_jobs[$i]}" "$max_job_width" \
            "${line_totals[$i]}" "$max_total_width" \
            "${line_passed[$i]}" "$max_passed_width" \
            "${line_failed[$i]}" "$max_failed_width" \
            "${line_skipped[$i]}" "$max_skipped_width")

        if [[ -n "${line_colors[$i]}" ]]; then
            echo "${line_colors[$i]}${rendered_line}${COLOR_RESET}"
        else
            echo "$rendered_line"
        fi

        i=$((i + 1))
    done

    echo "--------------------"
    local totals_line
    totals_line=$(_format_hierarchical_test_results_line \
        "Totals" "$max_label_width" \
        "" "$max_job_width" \
        "$total_sum" "$max_total_width" \
        "$passed_sum" "$max_passed_width" \
        "$failed_sum" "$max_failed_width" \
        "$skipped_sum" "$max_skipped_width")
    echo "${section_color}${totals_line}${COLOR_RESET}"

    local aggregated_failed_tests='[]'
    local total_failures=0
    i=0
    while [[ "$i" -lt "$count" ]]; do
        if [[ "${line_failed[$i]}" =~ ^[0-9]+$ && "${line_failed[$i]}" -gt 0 ]]; then
            local test_json failed_tests
            test_json=$(echo "$collected_json" | jq -r ".[$i].test_json // empty")
            failed_tests=$(parse_failed_tests "$test_json")
            aggregated_failed_tests=$(_jq_merge_json_arrays "$aggregated_failed_tests" "$failed_tests")
            total_failures=$((total_failures + line_failed[$i]))
        fi
        i=$((i + 1))
    done

    if [[ "$total_failures" -gt 0 ]]; then
        _display_failed_tests_array "$aggregated_failed_tests" "$total_failures" "$section_color"
    else
        echo "${section_color}====================${COLOR_RESET}"
    fi
}
