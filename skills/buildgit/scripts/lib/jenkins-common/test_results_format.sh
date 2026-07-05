# Parse test report JSON and extract summary statistics
# Usage: parse_test_summary "$test_report_json"
# Returns: Four lines on stdout: total, passed, failed, skipped
# Spec: test-failure-display-spec.md, Section: Summary Statistics (2.1)
parse_test_summary() {
    local test_json="$1"

    # Handle empty or missing input
    if [[ -z "$test_json" ]]; then
        echo "0"
        echo "0"
        echo "0"
        echo "0"
        return 0
    fi

    # Extract counts using jq, defaulting to 0 for missing fields
    local fail_count pass_count skip_count total_count
    fail_count=$(echo "$test_json" | jq -r '.failCount // 0')
    pass_count=$(echo "$test_json" | jq -r '.passCount // 0')
    skip_count=$(echo "$test_json" | jq -r '.skipCount // 0')

    # Handle case where jq returns "null" string
    [[ "$fail_count" == "null" ]] && fail_count=0
    [[ "$pass_count" == "null" ]] && pass_count=0
    [[ "$skip_count" == "null" ]] && skip_count=0

    # Calculate total
    total_count=$((pass_count + fail_count + skip_count))

    # Output four lines
    echo "$total_count"
    echo "$pass_count"
    echo "$fail_count"
    echo "$skip_count"
}

# Parse test report JSON and extract failed test details
# Usage: parse_failed_tests "$test_report_json"
# Returns: JSON array of failed test objects on stdout
# Spec: test-failure-display-spec.md, Section: Failed Test Details (2.2-2.3)
parse_failed_tests() {
    local test_json="$1"

    # Handle empty or missing input
    if [[ -z "$test_json" ]]; then
        echo "[]"
        return 0
    fi

    # Use jq to extract failed tests with all required fields
    # - Iterates through suites[].cases[]
    # - Filters for status == "FAILED"
    # - Extracts className, name, errorDetails, errorStackTrace, duration, age
    # - Handles missing fields with defaults
    # - Limits to MAX_FAILED_TESTS_DISPLAY
    # - Truncates errorDetails to MAX_ERROR_LENGTH
    local max_display="${MAX_FAILED_TESTS_DISPLAY:-10}"
    local max_error_len="${MAX_ERROR_LENGTH:-500}"
    local max_error_lines="${MAX_ERROR_LINES:-5}"
    local verbose_mode=false
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        verbose_mode=true
    fi

    echo "$test_json" | jq -r \
        --argjson max_display "$max_display" \
        --argjson max_error_len "$max_error_len" \
        --argjson max_error_lines "$max_error_lines" \
        --argjson verbose "$verbose_mode" '
        def maybe_truncate_text($value):
            if $value == null then
                null
            elif $verbose then
                ($value | tostring)
            else
                (($value | tostring)[:$max_error_len])
            end;

        def maybe_truncate_lines($value):
            if $value == null or ($value | tostring) == "" then
                null
            elif $verbose then
                ($value | tostring)
            else
                (($value | tostring | split("\n")) as $lines |
                    if ($lines | length) <= $max_error_lines then
                        ($value | tostring)
                    else
                        (($lines[:$max_error_lines] | join("\n")) + "\n...")
                    end)
            end;

        # Collect failed tests from BOTH direct suites path AND childReports path
        # This handles both freestyle jobs (.suites[].cases[]) and pipeline jobs (.childReports[].result.suites[].cases[])
        # Include both FAILED (recurring) and REGRESSION (newly broken) statuses
        # Spec: bug-no-testfail-stacktrace-shown-spec.md
        (
            [.suites[]?.cases[]? | select(.status == "FAILED" or .status == "REGRESSION")] +
            [.childReports[]?.result?.suites[]?.cases[]? | select(.status == "FAILED" or .status == "REGRESSION")]
        ) |

        # Remove duplicates (in case both paths exist)
        unique_by(.className + .name) |

        # Limit to max_display
        .[:$max_display] |

        # Transform each failed test
        map({
            className: (.className // "unknown"),
            name: (.name // "unknown"),
            errorDetails: (
                if (.errorDetails // "") == "" and (.errorStackTrace // "") == "" then
                    "No error details available"
                elif (.errorDetails // "") != "" then
                    maybe_truncate_text(.errorDetails)
                else
                    null
                end
            ),
            errorStackTrace: maybe_truncate_lines(.errorStackTrace // null),
            duration: (.duration // 0),
            age: (.age // 0),
            stdout: (if $verbose then (.stdout // null) else null end)
        })
    '
}

# Display test results in human-readable format
# Usage: display_test_results "$test_report_json"
# Outputs: Formatted test results section to stdout
# Spec: test-failure-display-spec.md, Section: Human-Readable Output (3.1-3.3)
display_test_results() {
    local test_json="$1"

    # Handle empty input - show placeholder
    # Spec: show-test-results-always-spec.md, Section 3
    if [[ -z "$test_json" ]]; then
        echo ""
        echo "=== Test Results ==="
        echo "  (no test results available)"
        echo "===================="
        return 0
    fi

    # Get summary statistics
    local summary
    summary=$(parse_test_summary "$test_json")

    local total passed failed skipped
    total=$(echo "$summary" | sed -n '1p')
    passed=$(echo "$summary" | sed -n '2p')
    failed=$(echo "$summary" | sed -n '3p')
    skipped=$(echo "$summary" | sed -n '4p')

    # Skip display if no tests at all
    if [[ "$total" -eq 0 ]]; then
        echo ""
        echo "=== Test Results ==="
        echo "  (no test results available)"
        echo "===================="
        return 0
    fi

    # Get failed test details
    local failed_tests
    failed_tests=$(parse_failed_tests "$test_json")

    # Count total failures in the original JSON (may be more than displayed)
    local total_failures
    total_failures=$(echo "$test_json" | jq -r '.failCount // 0')
    [[ "$total_failures" == "null" ]] && total_failures=0

    # Choose color based on failure count
    # Spec: show-test-results-always-spec.md, Section 2
    local section_color
    if [[ "$failed" -eq 0 ]]; then
        section_color="${COLOR_GREEN}"
    else
        section_color="${COLOR_YELLOW}"
    fi

    # Display header
    echo ""
    echo "${section_color}=== Test Results ===${COLOR_RESET}"

    # Display summary line
    echo "  ${section_color}Total: ${total} | Passed: ${passed} | Failed: ${failed} | Skipped: ${skipped}${COLOR_RESET}"

    # All tests passed - no failure details needed
    if [[ "$failed" -eq 0 ]]; then
        echo "${section_color}====================${COLOR_RESET}"
        return 0
    fi

    # Display failed tests header
    _display_failed_tests_array "$failed_tests" "$total_failures" "$section_color"
}

# Format test results as JSON for machine-readable output
# Usage: format_test_results_json "$test_report_json"
# Returns: JSON object with test summary and failed tests, or empty string if no data
# Spec: test-failure-display-spec.md, Section: JSON Output Enhancement (4.1-4.3)
format_test_results_json() {
    local test_json="$1"

    # Handle empty input - return empty string (caller should omit field)
    if [[ -z "$test_json" ]]; then
        echo ""
        return 0
    fi

    # Get summary statistics
    local summary
    summary=$(parse_test_summary "$test_json")

    local total passed failed skipped
    total=$(echo "$summary" | sed -n '1p')
    passed=$(echo "$summary" | sed -n '2p')
    failed=$(echo "$summary" | sed -n '3p')
    skipped=$(echo "$summary" | sed -n '4p')

    # Return empty if no tests at all
    if [[ "$total" -eq 0 ]]; then
        echo ""
        return 0
    fi

    # Get failed test details as JSON array
    local failed_tests_array
    failed_tests_array=$(parse_failed_tests "$test_json")

    # Transform the failed tests array to match expected JSON schema
    # Converting: className -> class_name, name -> test_name, duration -> duration_seconds
    local transformed_failed_tests
    local verbose_mode=false
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        verbose_mode=true
    fi

    transformed_failed_tests=$(echo "$failed_tests_array" | jq --argjson verbose "$verbose_mode" '
        map(
            {
                class_name: .className,
                test_name: .name,
                duration_seconds: .duration,
                age: .age,
                error_details: .errorDetails,
                error_stack_trace: .errorStackTrace
            } + (if $verbose then {stdout: .stdout} else {} end)
        )
    ')

    # Build the final JSON object
    _jq_test_results_object "$total" "$passed" "$failed" "$skipped" "$transformed_failed_tests"
}

# Format collected parent/downstream test results as JSON.
# Usage: format_hierarchical_test_results_json "$collected_results_json"
# Returns: JSON object with totals and failed_tests, plus breakdown for multi-job builds.
format_hierarchical_test_results_json() {
    local collected_json="$1"

    if ! has_downstream_builds "$collected_json"; then
        local parent_test_json
        parent_test_json=$(echo "$collected_json" | jq -r '.[0].test_json // empty')
        format_test_results_json "$parent_test_json"
        return 0
    fi

    local totals total_sum passed_sum failed_sum skipped_sum
    totals=$(aggregate_test_totals "$collected_json")
    total_sum=$(echo "$totals" | sed -n '1p')
    passed_sum=$(echo "$totals" | sed -n '2p')
    failed_sum=$(echo "$totals" | sed -n '3p')
    skipped_sum=$(echo "$totals" | sed -n '4p')

    local count aggregated_failed_tests
    count=$(echo "$collected_json" | jq 'length')
    aggregated_failed_tests='[]'

    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local test_json failed_tests
        test_json=$(echo "$collected_json" | jq -r ".[$i].test_json // empty")
        if [[ -n "$test_json" ]]; then
            failed_tests=$(parse_failed_tests "$test_json")
            aggregated_failed_tests=$(_jq_merge_json_arrays "$aggregated_failed_tests" "$failed_tests")
        fi
        i=$((i + 1))
    done

    local verbose_mode=false
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        verbose_mode=true
    fi

    local transformed_failed_tests
    transformed_failed_tests=$(echo "$aggregated_failed_tests" | jq --argjson verbose "$verbose_mode" '
        map(
            {
                class_name: .className,
                test_name: .name,
                duration_seconds: .duration,
                age: .age,
                error_details: .errorDetails,
                error_stack_trace: .errorStackTrace
            } + (if $verbose then {stdout: .stdout} else {} end)
        )
    ')

    local breakdown_json
    breakdown_json=$(echo "$collected_json" | jq --argjson verbose "$verbose_mode" '
        map(
            . as $entry |
            if ($entry.test_json // "") == "" then
                {
                    job: $entry.job,
                    stage: (if ($entry.depth // 0) > 0 then $entry.stage else null end),
                    build_number: $entry.build_number,
                    total: null,
                    passed: null,
                    failed: null,
                    skipped: null,
                    failed_tests: null
                }
            else
                (($entry.test_json | fromjson) as $test |
                {
                    job: $entry.job,
                    stage: (if ($entry.depth // 0) > 0 then $entry.stage else null end),
                    build_number: $entry.build_number,
                    total: (($test.passCount // 0) + ($test.failCount // 0) + ($test.skipCount // 0)),
                    passed: ($test.passCount // 0),
                    failed: ($test.failCount // 0),
                    skipped: ($test.skipCount // 0),
                    failed_tests: (
                        (
                            [
                                $test.suites[]?.cases[]?
                                | select(.status == "FAILED" or .status == "REGRESSION")
                            ] +
                            [
                                $test.childReports[]?.result?.suites[]?.cases[]?
                                | select(.status == "FAILED" or .status == "REGRESSION")
                            ]
                        )
                        | unique_by((.className // "unknown") + (.name // "unknown"))
                        | map(
                            {
                                class_name: (.className // "unknown"),
                                test_name: (.name // "unknown"),
                                duration_seconds: (.duration // 0),
                                age: (.age // 0),
                                error_details: (
                                    if (.errorDetails // "") == "" and (.errorStackTrace // "") == "" then
                                        "No error details available"
                                    elif (.errorDetails // "") != "" then
                                        (.errorDetails | tostring)
                                    else
                                        null
                                    end
                                ),
                                error_stack_trace: (.errorStackTrace // null)
                            } + (if $verbose then {stdout: (.stdout // null)} else {} end)
                        )
                    )
                })
            end
            | if .stage == null then del(.stage) else . end
        )
    ')

    _jq_object_with_json_fields \
        "$total_sum" "$passed_sum" "$failed_sum" "$skipped_sum" \
        "$transformed_failed_tests" "$breakdown_json"
}
