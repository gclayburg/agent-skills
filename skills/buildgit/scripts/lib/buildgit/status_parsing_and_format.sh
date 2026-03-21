# Parse status command options
# Sets: STATUS_JSON_MODE, STATUS_FOLLOW_MODE, STATUS_ONCE_MODE, STATUS_LINE_MODE, STATUS_LINE_COUNT, STATUS_ALL_MODE, STATUS_NO_TESTS, STATUS_PROBE_ALL
_parse_status_options() {
    STATUS_JSON_MODE=false
    STATUS_FOLLOW_MODE=false
    STATUS_ONCE_MODE=false
    STATUS_ONCE_TIMEOUT=10
    STATUS_N_SET=false
    STATUS_LINE_MODE=false
    STATUS_LINE_COUNT="1"
    STATUS_ALL_MODE=false
    STATUS_NO_TESTS=false
    STATUS_BUILD_NUMBER=""
    STATUS_FORMAT_EXPLICIT=false
    STATUS_PRIOR_JOBS=0
    STATUS_PRIOR_JOBS_EXPLICIT=false
    STATUS_CONSOLE_TEXT_MODE=false
    STATUS_CONSOLE_TEXT_STAGE=""
    STATUS_LIST_STAGES_MODE=false
    STATUS_PROBE_ALL=false
    _LINE_FORMAT_STRING="$_DEFAULT_LINE_FORMAT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            --json)
                STATUS_JSON_MODE=true
                shift
                ;;
            -f|--follow)
                STATUS_FOLLOW_MODE=true
                shift
                ;;
            --probe-all)
                STATUS_PROBE_ALL=true
                shift
                ;;
            --once)
                STATUS_ONCE_MODE=true
                shift
                ;;
            --once=*)
                STATUS_ONCE_MODE=true
                local _once_val="${1#--once=}"
                if ! [[ "$_once_val" =~ ^[0-9]+$ ]]; then
                    _usage_error "--once value must be a non-negative integer"
                fi
                STATUS_ONCE_TIMEOUT="$_once_val"
                shift
                ;;
            -l|--line)
                STATUS_LINE_MODE=true
                shift
                ;;
            --line=*)
                _usage_error "--line does not accept a value; use -n <count> to specify number of builds"
                ;;
            -n)
                shift
                if [[ -z "${1:-}" ]] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
                    _usage_error "-n requires a positive integer argument"
                fi
                STATUS_LINE_COUNT="$1"
                STATUS_N_SET=true
                shift
                ;;
            -[0-9]*)
                # Relative build number shorthand (e.g. -1, -2, -0)
                if ! [[ "$1" =~ ^-[0-9]+$ ]]; then
                    _usage_error "Unknown option for status command: $1"
                fi
                if [[ -n "$STATUS_BUILD_NUMBER" ]]; then
                    _usage_error "Unexpected argument: $1 (build number already set to $STATUS_BUILD_NUMBER)"
                fi
                STATUS_BUILD_NUMBER="$1"
                shift
                ;;
            -a|--all)
                STATUS_ALL_MODE=true
                shift
                ;;
            --console-text)
                STATUS_CONSOLE_TEXT_MODE=true
                if [[ $# -gt 1 ]] && [[ "${2:-}" != -* ]]; then
                    if [[ -n "$STATUS_BUILD_NUMBER" ]] || ! [[ "${2:-}" =~ ^(0|[1-9][0-9]*|-[0-9]+)$ ]]; then
                        STATUS_CONSOLE_TEXT_STAGE="$2"
                        shift 2
                        continue
                    fi
                fi
                shift
                ;;
            --list-stages)
                STATUS_LIST_STAGES_MODE=true
                shift
                ;;
            --no-tests)
                STATUS_NO_TESTS=true
                shift
                ;;
            --format)
                shift
                if [[ -z "${1:-}" ]]; then
                    _usage_error "--format requires a format string argument"
                fi
                _LINE_FORMAT_STRING="$1"
                STATUS_LINE_MODE=true
                STATUS_FORMAT_EXPLICIT=true
                shift
                ;;
            --format=*)
                _LINE_FORMAT_STRING="${1#--format=}"
                STATUS_LINE_MODE=true
                STATUS_FORMAT_EXPLICIT=true
                shift
                ;;
            --prior-jobs)
                shift
                STATUS_PRIOR_JOBS=$(_parse_prior_jobs_value "${1:-}" "--prior-jobs")
                STATUS_PRIOR_JOBS_EXPLICIT=true
                shift
                ;;
            --prior-jobs=*)
                STATUS_PRIOR_JOBS=$(_parse_prior_jobs_value "${1#--prior-jobs=}" "--prior-jobs")
                STATUS_PRIOR_JOBS_EXPLICIT=true
                shift
                ;;
            -*)
                _usage_error "Unknown option for status command: $1"
                ;;
            *)
                # Positional argument: build number
                if [[ -n "$STATUS_BUILD_NUMBER" ]]; then
                    _usage_error "Unexpected argument: $1 (build number already set to $STATUS_BUILD_NUMBER)"
                fi
                if ! [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; then
                    _usage_error "Invalid build number: $1 (must be a non-negative integer)"
                fi
                STATUS_BUILD_NUMBER="$1"
                shift
                ;;
        esac
    done
}

# Format epoch milliseconds as local YYYY-MM-DD
_format_local_date() {
    local epoch_ms="$1"
    if [[ -z "$epoch_ms" || "$epoch_ms" == "null" || ! "$epoch_ms" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    local epoch_seconds=$((epoch_ms / 1000))
    if [[ "$(uname)" == "Darwin" ]]; then
        date -r "$epoch_seconds" "+%Y-%m-%d" 2>/dev/null || echo "unknown"
    else
        date -d "@$epoch_seconds" "+%Y-%m-%d" 2>/dev/null || echo "unknown"
    fi
}

# Format epoch milliseconds as local YYYY-MM-DD HH:MM
_format_local_datetime_minute() {
    local epoch_ms="$1"
    if [[ -z "$epoch_ms" || "$epoch_ms" == "null" || ! "$epoch_ms" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    local epoch_seconds=$((epoch_ms / 1000))
    if [[ "$(uname)" == "Darwin" ]]; then
        date -r "$epoch_seconds" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown"
    else
        date -d "@$epoch_seconds" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown"
    fi
}

# Format epoch milliseconds as local ISO 8601 with timezone offset
_format_local_datetime_iso8601() {
    local epoch_ms="$1"
    if [[ -z "$epoch_ms" || "$epoch_ms" == "null" || ! "$epoch_ms" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    local epoch_seconds=$((epoch_ms / 1000))
    if [[ "$(uname)" == "Darwin" ]]; then
        date -r "$epoch_seconds" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || echo "unknown"
    else
        date -d "@$epoch_seconds" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || echo "unknown"
    fi
}

# Format relative age for an epoch seconds timestamp.
# Returns: just now, N minutes ago, N hours ago, N days ago, N weeks ago, or N months ago
_format_relative_time() {
    local epoch_seconds="$1"
    if [[ -z "$epoch_seconds" || ! "$epoch_seconds" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi

    local now age
    now=$(date +%s)
    age=$((now - epoch_seconds))
    if [[ "$age" -lt 0 ]]; then
        age=0
    fi

    if [[ "$age" -lt 60 ]]; then
        echo "just now"
    elif [[ "$age" -lt 3600 ]]; then
        local minutes=$((age / 60))
        if [[ "$minutes" -eq 1 ]]; then
            echo "1 minute ago"
        else
            echo "${minutes} minutes ago"
        fi
    elif [[ "$age" -lt 86400 ]]; then
        local hours=$((age / 3600))
        if [[ "$hours" -eq 1 ]]; then
            echo "1 hour ago"
        else
            echo "${hours} hours ago"
        fi
    elif [[ "$age" -lt 2592000 ]]; then
        local days=$((age / 86400))
        if [[ "$days" -eq 1 ]]; then
            echo "1 day ago"
        else
            echo "${days} days ago"
        fi
    elif [[ "$age" -lt 7776000 ]]; then
        local weeks=$((age / 604800))
        if [[ "$weeks" -eq 1 ]]; then
            echo "1 week ago"
        else
            echo "${weeks} weeks ago"
        fi
    else
        local months=$((age / 2592000))
        if [[ "$months" -eq 1 ]]; then
            echo "1 month ago"
        else
            echo "${months} months ago"
        fi
    fi
}

# Extract git commit SHA and branch name from build JSON actions array.
# Sets globals: _LINE_COMMIT_SHA (7-char short SHA or "unknown")
#               _LINE_BRANCH_NAME (short branch name, refs/remotes/origin/ stripped, or "unknown")
# Spec: 2026-02-23_status-line-template-spec.md
_extract_git_info_from_build() {
    local build_json="$1"
    _LINE_COMMIT_SHA="unknown"
    _LINE_BRANCH_NAME="unknown"

    # Primary: class-based git SCM action
    local sha
    sha=$(echo "$build_json" | jq -r '
        .actions[]? |
        select(._class? | test("hudson.plugins.git"; "i") // false) |
        .lastBuiltRevision?.SHA1 // empty
    ' 2>/dev/null | head -1) || true

    # Fallback: any action that has lastBuiltRevision
    if [[ -z "$sha" ]]; then
        sha=$(echo "$build_json" | jq -r '
            .actions[]? |
            select(.lastBuiltRevision?) |
            .lastBuiltRevision.SHA1 // empty
        ' 2>/dev/null | head -1) || true
    fi

    if [[ -n "$sha" && "$sha" != "null" && "${#sha}" -ge 7 ]]; then
        _LINE_COMMIT_SHA="${sha:0:7}"
    fi

    # Primary: class-based git SCM action for branch
    local branch
    branch=$(echo "$build_json" | jq -r '
        .actions[]? |
        select(._class? | test("hudson.plugins.git"; "i") // false) |
        .lastBuiltRevision?.branch[0]?.name // empty
    ' 2>/dev/null | head -1) || true

    # Fallback: any action with lastBuiltRevision.branch
    if [[ -z "$branch" ]]; then
        branch=$(echo "$build_json" | jq -r '
            .actions[]? |
            select(.lastBuiltRevision?) |
            .lastBuiltRevision.branch[0].name // empty
        ' 2>/dev/null | head -1) || true
    fi

    if [[ -n "$branch" && "$branch" != "null" ]]; then
        branch="${branch#refs/remotes/origin/}"
        _LINE_BRANCH_NAME="$branch"
    fi
}

# Apply a format string with status-line placeholder substitution.
# Arguments: format_string status job_name build_number tests_display duration
#            date iso8601 relative commit_sha branch_name
# Spec: 2026-02-23_status-line-template-spec.md
_apply_line_format() {
    local fmt="$1"
    local val_s="$2"
    local val_j="$3"
    local val_n="$4"
    local val_t="$5"
    local val_d="$6"
    local val_D="$7"
    local val_I="$8"
    local val_r="$9"
    local val_c="${10}"
    local val_b="${11}"

    local result=""
    local i=0
    local len="${#fmt}"
    while [[ "$i" -lt "$len" ]]; do
        local ch="${fmt:$i:1}"
        if [[ "$ch" == "%" && "$((i + 1))" -lt "$len" ]]; then
            local next="${fmt:$((i+1)):1}"
            case "$next" in
                s) result+="$val_s" ;;
                j) result+="$val_j" ;;
                n) result+="$val_n" ;;
                t) result+="$val_t" ;;
                d) result+="$val_d" ;;
                D) result+="$val_D" ;;
                I) result+="$val_I" ;;
                r) result+="$val_r" ;;
                c) result+="$val_c" ;;
                b) result+="$val_b" ;;
                %) result+="%" ;;
                *) result+="%${next}" ;;
            esac
            i=$((i + 2))
        else
            result+="$ch"
            i=$((i + 1))
        fi
    done
    echo "$result"
}

# Fast one-line status output for snapshot mode.
# Returns: 0 for SUCCESS, 1 for non-SUCCESS or in-progress.
_format_status_line_field() {
    local status="$1"
    local status_color=""
    local status_field
    status_field=$(printf "%-11.11s" "$status")

    case "$status" in
        SUCCESS)     status_color="${COLOR_GREEN}" ;;
        FAILURE)     status_color="${COLOR_RED}" ;;
        NOT_BUILT)   status_color="${COLOR_RED}" ;;
        UNSTABLE)    status_color="${COLOR_YELLOW}" ;;
        ABORTED)     status_color="${COLOR_DIM}" ;;
        IN_PROGRESS) status_color="${COLOR_BLUE}" ;;
        *)           status_color="${COLOR_RED}" ;;
    esac

    if [[ -n "$status_color" ]]; then
        echo "${status_color}${status_field}${COLOR_RESET}"
    else
        echo "${status_field}"
    fi
}

_status_line_for_build_json() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"
    local no_tests="${4:-false}"
    local status_raw status_display
    local fmt="${_LINE_FORMAT_STRING:-${_DEFAULT_LINE_FORMAT}}"

    local json_build_number
    json_build_number=$(echo "$build_json" | jq -r '.number // empty')
    if [[ -n "$json_build_number" ]]; then
        build_number="$json_build_number"
    fi

    local result building timestamp_ms duration_ms
    local commit_val="unknown" branch_val="unknown"
    result=$(echo "$build_json" | jq -r '.result // empty')
    building=$(echo "$build_json" | jq -r '.building // false')
    timestamp_ms=$(echo "$build_json" | jq -r '.timestamp // 0')
    duration_ms=$(echo "$build_json" | jq -r '.duration // 0')

    if [[ "$building" == "true" || -z "$result" ]]; then
        local now_ms elapsed_ms elapsed_display start_display
        now_ms=$(($(date +%s) * 1000))
        elapsed_ms=0
        if [[ "$timestamp_ms" =~ ^[0-9]+$ && "$timestamp_ms" -gt 0 ]]; then
            elapsed_ms=$((now_ms - timestamp_ms))
            if [[ "$elapsed_ms" -lt 0 ]]; then
                elapsed_ms=0
            fi
        fi

        elapsed_display=$(format_duration "$elapsed_ms")
        status_raw="IN_PROGRESS"
        status_display=$(_format_status_line_field "$status_raw")

        if [[ "$fmt" == "$_DEFAULT_LINE_FORMAT" || "$fmt" == *"%c"* || "$fmt" == *"%b"* ]]; then
            _extract_git_info_from_build "$build_json"
            commit_val="$_LINE_COMMIT_SHA"
            branch_val="$_LINE_BRANCH_NAME"
        fi

        if [[ "$fmt" == "$_DEFAULT_LINE_FORMAT" ]]; then
            # Default format: preserve existing "running for ... (started ...)" wording
            start_display=$(_format_local_datetime_minute "$timestamp_ms")
            echo "${status_display} #${build_number} id=${commit_val} Tests=?/?/? running for ${elapsed_display} (started ${start_display})"
        else
            # Custom format: apply format string; %D/%I/%r are start-time values
            local date_val iso_val rel_val
            date_val=$(_format_local_date "$timestamp_ms")
            iso_val=$(_format_local_datetime_iso8601 "$timestamp_ms")
            rel_val=$(_format_relative_time "$((timestamp_ms / 1000))")
            _apply_line_format "$fmt" "$status_display" "$job_name" "$build_number" "?/?/?" \
                "$elapsed_display" "$date_val" "$iso_val" "$rel_val" "$commit_val" "$branch_val"
        fi
        return 1
    fi

    local tests_display tests_fail_count tests_color tests_field
    local tests_comm_error=false
    tests_display="?/?/?"
    tests_fail_count=""
    if [[ "$no_tests" != "true" ]]; then
        local test_results_json passed failed skipped test_results_rc=0
        if test_results_json=$(fetch_test_results "$job_name" "$build_number"); then
            test_results_rc=0
        else
            test_results_rc=$?
            test_results_json=""
        fi
        if [[ "$test_results_rc" -eq 2 ]]; then
            tests_display="!err!"
            tests_comm_error=true
            _note_test_results_comm_failure "$job_name" "$build_number"
        else
            local console_output downstream_lines
            console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null || true)
            downstream_lines=""
            if [[ -n "$console_output" ]]; then
                downstream_lines=$(detect_all_downstream_builds "$console_output")
            fi

            if [[ -n "$downstream_lines" ]]; then
                local collected_results collected_rc=0 totals
                if collected_results=$(collect_downstream_test_results "$job_name" "$build_number" "$console_output"); then
                    collected_rc=0
                else
                    collected_rc=$?
                    collected_results=""
                fi

                if [[ "$collected_rc" -eq 2 ]]; then
                    tests_display="!err!"
                    tests_comm_error=true
                    _note_test_results_comm_failure "$job_name" "$build_number"
                elif [[ -n "$collected_results" ]]; then
                    totals=$(aggregate_test_totals "$collected_results")
                    passed=$(echo "$totals" | sed -n '2p')
                    failed=$(echo "$totals" | sed -n '3p')
                    skipped=$(echo "$totals" | sed -n '4p')
                    if [[ "$passed" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ && "$skipped" =~ ^[0-9]+$ ]]; then
                        tests_display="${passed}/${failed}/${skipped}"
                        tests_fail_count="$failed"
                    fi
                fi
            elif [[ -n "$test_results_json" ]]; then
                passed=$(echo "$test_results_json" | jq -r '.passCount // 0')
                failed=$(echo "$test_results_json" | jq -r '.failCount // 0')
                skipped=$(echo "$test_results_json" | jq -r '.skipCount // 0')
                if [[ "$passed" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ && "$skipped" =~ ^[0-9]+$ ]]; then
                    tests_display="${passed}/${failed}/${skipped}"
                    tests_fail_count="$failed"
                fi
            fi
        fi
    fi

    local completion_ms completion_seconds duration_display date_display iso_display relative_display
    completion_ms="$timestamp_ms"
    if [[ "$timestamp_ms" =~ ^[0-9]+$ && "$duration_ms" =~ ^[0-9]+$ ]]; then
        completion_ms=$((timestamp_ms + duration_ms))
    fi
    completion_seconds=$((completion_ms / 1000))
    duration_display=$(format_duration "$duration_ms")
    date_display=$(_format_local_date "$completion_ms")
    iso_display=$(_format_local_datetime_iso8601 "$completion_ms")
    relative_display=$(_format_relative_time "$completion_seconds")

    status_raw="$result"
    status_display=$(_format_status_line_field "$status_raw")

    if [[ "$fmt" == "$_DEFAULT_LINE_FORMAT" || "$fmt" == *"%c"* || "$fmt" == *"%b"* ]]; then
        _extract_git_info_from_build "$build_json"
        commit_val="$_LINE_COMMIT_SHA"
        branch_val="$_LINE_BRANCH_NAME"
    fi

    if [[ "$fmt" == "$_DEFAULT_LINE_FORMAT" ]]; then
        # Default format: preserve existing colorized Tests=label/value output
        tests_field="Tests=${tests_display}"
        if [[ "$tests_display" != "?/?/?" ]]; then
            tests_color="${COLOR_GREEN}"
            if [[ "$tests_comm_error" == "true" ]]; then
                tests_color="${COLOR_YELLOW}"
            elif [[ "$tests_fail_count" =~ ^[0-9]+$ && "$tests_fail_count" -gt 0 ]]; then
                tests_color="${COLOR_YELLOW}"
            fi
            if [[ -n "$tests_color" ]]; then
                tests_field="${tests_color}${tests_field}${COLOR_RESET}"
            fi
        fi
        echo "${status_display} #${build_number} id=${commit_val} ${tests_field} Took ${duration_display} on ${iso_display} (${relative_display})"
    else
        # Custom format: %t outputs colorized value only (label is part of format string)
        local tests_colorized="$tests_display"
        if [[ "$tests_display" != "?/?/?" ]]; then
            tests_color="${COLOR_GREEN}"
            if [[ "$tests_comm_error" == "true" ]]; then
                tests_color="${COLOR_YELLOW}"
            elif [[ "$tests_fail_count" =~ ^[0-9]+$ && "$tests_fail_count" -gt 0 ]]; then
                tests_color="${COLOR_YELLOW}"
            fi
            if [[ -n "$tests_color" ]]; then
                tests_colorized="${tests_color}${tests_display}${COLOR_RESET}"
            fi
        fi
        _apply_line_format "$fmt" "$status_display" "$job_name" "$build_number" "$tests_colorized" \
            "$duration_display" "$date_display" "$iso_display" "$relative_display" "$commit_val" "$branch_val"
    fi

    if [[ "$result" == "SUCCESS" ]]; then
        return 0
    fi
    return 1
}
