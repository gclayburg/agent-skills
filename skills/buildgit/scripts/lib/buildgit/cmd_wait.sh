# buildgit wait: block until one build stops running, then report it.
# Spec: buildgit-wait-spec.md

# Exit code: `--timeout` expired while the build is still running. Same
# meaning as 2 elsewhere ("build is in progress").
: "${BUILDGIT_EXIT_IN_PROGRESS:=2}"
# BUILDGIT_EXIT_NO_NEW_BUILD (4, "nothing to wait for") is defined in
# monitor_helpers.sh next to BUILDGIT_EXIT_BAILED_ON_RED.

_parse_wait_options() {
    WAIT_BUILD_NUMBER=""
    WAIT_QUEUE=false
    WAIT_TIMEOUT=""
    WAIT_JSON=false
    WAIT_NO_TESTS=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --queue)
                WAIT_QUEUE=true
                shift
                ;;
            --timeout)
                if [[ -z "${2:-}" ]]; then
                    _usage_error "--timeout requires a number of seconds"
                fi
                WAIT_TIMEOUT="$2"
                shift 2
                ;;
            --timeout=*)
                WAIT_TIMEOUT="${1#--timeout=}"
                shift
                ;;
            --json)
                WAIT_JSON=true
                shift
                ;;
            --no-tests)
                WAIT_NO_TESTS=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -[0-9]*|[0-9]*)
                if [[ -n "$WAIT_BUILD_NUMBER" ]]; then
                    _usage_error "wait accepts only one build number"
                fi
                if ! [[ "$1" =~ ^-?[0-9]+$ ]]; then
                    _usage_error "Invalid build number: $1"
                fi
                WAIT_BUILD_NUMBER="$1"
                shift
                ;;
            *)
                _usage_error "Unknown option for wait command: $1"
                ;;
        esac
    done

    if [[ -n "$WAIT_TIMEOUT" ]] && ! [[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]]; then
        _usage_error "--timeout value must be a non-negative integer (seconds)"
    fi
    if [[ -z "$WAIT_TIMEOUT" ]]; then
        WAIT_TIMEOUT="${MAX_BUILD_TIME:-0}"
    fi
}

# Count queue items that belong to the job (task.url ends with its path).
# Echoes a number; echoes 0 when the queue cannot be read.
_wait_queued_count() {
    local job_name="$1"
    local job_path queue_json count

    job_path=$(jenkins_job_path "$job_name") || job_path=""
    [[ -z "$job_path" ]] && { echo 0; return 0; }

    queue_json=$(jenkins_api "/queue/api/json?tree=items[id,task[name,url]]" 2>/dev/null) || queue_json=""
    count=$(printf '%s\n' "$queue_json" | jq -r --arg p "${job_path}/" \
        '[(.items // [])[] | select(((.task.url // "") | endswith($p)))] | length' 2>/dev/null) || count=0
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}

# Seconds left before the deadline; 0 deadline means no limit (echo -1).
_wait_seconds_left() {
    local deadline="$1"
    if [[ "$deadline" -eq 0 ]]; then
        echo "-1"
        return 0
    fi
    local left=$((deadline - $(date +%s)))
    [[ "$left" -lt 0 ]] && left=0
    echo "$left"
}

# Poll until the build stops running or the deadline passes.
# Sets _WAIT_BUILD_JSON to the last build JSON read.
# Returns 0 when the build has stopped, 2 on timeout.
_wait_for_build_to_stop() {
    local job_name="$1"
    local build_number="$2"
    local deadline="$3"
    local announced=false

    _WAIT_BUILD_JSON=""
    while true; do
        local build_json building
        build_json=$(get_build_info "$job_name" "$build_number" 2>/dev/null) || build_json=""
        if [[ -n "$build_json" ]]; then
            _WAIT_BUILD_JSON="$build_json"
            building=$(printf '%s\n' "$build_json" | jq -r '.building // false' 2>/dev/null) || building="true"
            if [[ "$building" != "true" ]]; then
                # Keep stdout reserved for the requested row or JSON report.
                # A live wait can expose the verdict while that report is built.
                if [[ "$announced" == "true" && ( "$WAIT_JSON" == "true" || "$WAIT_NO_TESTS" != "true" ) ]]; then
                    local result
                    result=$(jq -r '.result // empty' <<< "$build_json") || result=""
                    if [[ -n "$result" ]]; then
                        bg_log_essential "Jenkins result for ${job_name} #${build_number}: ${result}" >&2
                    fi
                fi
                return 0
            fi
            if [[ "$announced" != "true" ]]; then
                local running_msg="" ts_ms
                ts_ms=$(printf '%s\n' "$build_json" | jq -r '.timestamp // 0' 2>/dev/null) || ts_ms=0
                if [[ "$ts_ms" =~ ^[0-9]+$ && "$ts_ms" -gt 0 ]]; then
                    local running_ms=$(( $(date +%s) * 1000 - ts_ms ))
                    [[ "$running_ms" -lt 0 ]] && running_ms=0
                    running_msg=" (running $(format_duration "$running_ms"))"
                fi
                log_info "Waiting for ${job_name} #${build_number} to finish${running_msg}..." >&2
                announced=true
            fi
        fi

        local left
        left=$(_wait_seconds_left "$deadline")
        if [[ "$left" -eq 0 ]]; then
            return "$BUILDGIT_EXIT_IN_PROGRESS"
        fi
        local nap="$POLL_INTERVAL"
        if [[ "$left" -gt 0 && "$left" -lt "$nap" ]]; then
            nap="$left"
        fi
        sleep "$nap"
    done
}

# Poll until no queue item for the job remains, or the deadline passes.
# Returns 0 when the queue is clear, 2 on timeout.
_wait_for_queue_to_clear() {
    local job_name="$1"
    local deadline="$2"
    local announced=false

    while true; do
        local queued
        queued=$(_wait_queued_count "$job_name")
        if [[ "$queued" -eq 0 ]]; then
            return 0
        fi
        if [[ "$announced" != "true" ]]; then
            log_info "Waiting for ${queued} queued build(s) of ${job_name} to leave the queue..." >&2
            announced=true
        fi
        local left
        left=$(_wait_seconds_left "$deadline")
        if [[ "$left" -eq 0 ]]; then
            return "$BUILDGIT_EXIT_IN_PROGRESS"
        fi
        local nap="$POLL_INTERVAL"
        if [[ "$left" -gt 0 && "$left" -lt "$nap" ]]; then
            nap="$left"
        fi
        sleep "$nap"
    done
}

# Print the result for a build (line row or status JSON).
_wait_report() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"

    if [[ "$WAIT_JSON" == "true" ]]; then
        _jenkins_status_check "$job_name" "true" "$build_number" || true
    else
        _status_line_for_build_json "$job_name" "$build_number" "$build_json" "$WAIT_NO_TESTS" || true
    fi
}

cmd_wait() {
    _parse_wait_options "$@"

    if ! _validate_jenkins_setup "wait for Jenkins build" "wait"; then
        return 1
    fi
    local job_name="$_VALIDATED_JOB_NAME"

    local deadline=0
    if [[ "$WAIT_TIMEOUT" -gt 0 ]]; then
        deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
    fi

    local build_number=""
    if [[ -n "$WAIT_BUILD_NUMBER" ]]; then
        if ! build_number=$(_resolve_status_build_number "$job_name" "$WAIT_BUILD_NUMBER"); then
            return 1
        fi
    fi
    if [[ -z "$build_number" ]]; then
        build_number=$(get_last_build_number "$job_name")
    fi

    if [[ "$build_number" == "0" || -z "$build_number" ]]; then
        if [[ "$WAIT_QUEUE" != "true" || "$(_wait_queued_count "$job_name")" -eq 0 ]]; then
            bg_log_error "No build to wait for: job '${job_name}' has no builds"
            return "$BUILDGIT_EXIT_NO_NEW_BUILD"
        fi
        build_number=""
    fi

    while true; do
        if [[ -n "$build_number" ]]; then
            local rc=0
            _wait_for_build_to_stop "$job_name" "$build_number" "$deadline" || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                bg_log_error "Timed out after ${WAIT_TIMEOUT}s: ${job_name} #${build_number} is still running"
                _wait_report "$job_name" "$build_number" "$_WAIT_BUILD_JSON"
                return "$BUILDGIT_EXIT_IN_PROGRESS"
            fi
        fi

        if [[ "$WAIT_QUEUE" != "true" ]]; then
            break
        fi

        local qrc=0
        _wait_for_queue_to_clear "$job_name" "$deadline" || qrc=$?
        if [[ "$qrc" -ne 0 ]]; then
            bg_log_error "Timed out after ${WAIT_TIMEOUT}s: ${job_name} still has queued builds"
            if [[ -n "$build_number" ]]; then
                _wait_report "$job_name" "$build_number" "$_WAIT_BUILD_JSON"
            fi
            return "$BUILDGIT_EXIT_IN_PROGRESS"
        fi

        # A queued item may have become a new build; wait for it as well.
        local latest
        latest=$(get_last_build_number "$job_name")
        if [[ "$latest" =~ ^[0-9]+$ && "$latest" -gt 0 && "$latest" != "$build_number" ]]; then
            build_number="$latest"
            continue
        fi
        break
    done

    if [[ -z "$build_number" ]]; then
        bg_log_error "No build to wait for: job '${job_name}' has no builds"
        return "$BUILDGIT_EXIT_NO_NEW_BUILD"
    fi

    local result
    result=$(printf '%s\n' "$_WAIT_BUILD_JSON" | jq -r '.result // "UNKNOWN"' 2>/dev/null) || result="UNKNOWN"
    _wait_report "$job_name" "$build_number" "$_WAIT_BUILD_JSON"
    if [[ "$result" == "SUCCESS" ]]; then
        return 0
    fi
    return 1
}
