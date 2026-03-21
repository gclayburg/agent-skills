_parse_queue_options() {
    QUEUE_JSON=false
    QUEUE_VERBOSE=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                QUEUE_JSON=true
                shift
                ;;
            -v|--verbose)
                QUEUE_VERBOSE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                _usage_error "Unknown option for queue command: $1"
                ;;
        esac
    done
}

_fetch_queue() {
    jenkins_api "/queue/api/json?tree=items[id,stuck,blocked,buildable,why,inQueueSince,task[name,url]]"
}

_queue_now_ms() {
    if [[ -n "${QUEUE_NOW_MS:-}" ]]; then
        printf '%s\n' "$QUEUE_NOW_MS"
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

_format_queue_duration() {
    local in_queue_since="${1:-0}"

    if [[ -z "$in_queue_since" || "$in_queue_since" == "null" || ! "$in_queue_since" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return 0
    fi

    local now_ms queued_ms
    now_ms=$(_queue_now_ms)
    queued_ms=$((now_ms - in_queue_since))
    if [[ "$queued_ms" -lt 0 ]]; then
        queued_ms=0
    fi

    printf '%s ago\n' "$(format_duration "$queued_ms")"
}

_queue_item_label() {
    local count="$1"

    if [[ "$count" == "1" ]]; then
        echo "item"
    else
        echo "items"
    fi
}

_render_queue_human() {
    local queue_json="$1"
    local item_count
    item_count=$(printf '%s\n' "$queue_json" | jq -r '.items | length')

    if [[ "$item_count" -eq 0 ]]; then
        echo "Queue: empty"
        return 0
    fi

    echo "Queue: ${item_count} $(_queue_item_label "$item_count")"

    local item_payload first_item=true
    while IFS= read -r item_payload; do
        [[ -n "$item_payload" ]] || continue

        if [[ "$first_item" != "true" ]]; then
            echo ""
        fi
        first_item=false

        local item_json prefix job_name queued_since why
        item_json=$(printf '%s' "$item_payload" | base64 --decode)
        prefix=""

        if [[ "$QUEUE_VERBOSE" == "true" ]]; then
            if [[ "$(printf '%s\n' "$item_json" | jq -r '.stuck // false')" == "true" ]]; then
                prefix="${prefix}[STUCK] "
            fi
            if [[ "$(printf '%s\n' "$item_json" | jq -r '.blocked // false')" == "true" ]]; then
                prefix="${prefix}[BLOCKED] "
            fi
        fi

        job_name=$(printf '%s\n' "$item_json" | jq -r '.task.name // "unknown"')
        queued_since=$(printf '%s\n' "$item_json" | jq -r '.inQueueSince // 0')
        why=$(printf '%s\n' "$item_json" | jq -r '.why // "No queue reason available"')

        printf '%s%s (%s)\n' "$prefix" "$job_name" "$(_format_queue_duration "$queued_since")"
        printf '  %s\n' "$why"
    done < <(printf '%s\n' "$queue_json" | jq -r '.items[] | @base64')
}

_render_queue_json() {
    local queue_json="$1"
    local now_ms
    now_ms=$(_queue_now_ms)

    printf '%s\n' "$queue_json" | jq --argjson now "$now_ms" '
        .items = (
            (.items // [])
            | map(
                . + {
                    queuedDuration: (
                        ($now - (.inQueueSince // $now))
                        | if . < 0 then 0 else . end
                    )
                }
            )
        )
        | .count = (.items | length)
    '
}

cmd_queue() {
    _parse_queue_options "$@"

    if ! validate_dependencies; then
        bg_log_error "Cannot inspect Jenkins queue - missing dependencies (jq, curl)"
        bg_log_essential "Suggestion: Install jq and curl, then retry"
        return 1
    fi

    if ! validate_environment; then
        bg_log_error "Cannot inspect Jenkins queue - environment not configured"
        bg_log_essential "Suggestion: Set JENKINS_URL, JENKINS_USER_ID, and JENKINS_API_TOKEN"
        return 1
    fi

    bg_log_info "Verifying Jenkins connectivity..."
    if ! verify_jenkins_connection; then
        bg_log_error "Cannot inspect Jenkins queue - cannot connect to Jenkins"
        bg_log_essential "Suggestion: Check JENKINS_URL and credentials"
        return 1
    fi

    local queue_json
    queue_json=$(_fetch_queue)
    if [[ -z "$queue_json" ]]; then
        queue_json='{"items":[]}'
    fi

    if [[ "$QUEUE_JSON" == "true" ]]; then
        _render_queue_json "$queue_json"
    else
        _render_queue_human "$queue_json"
    fi
}
