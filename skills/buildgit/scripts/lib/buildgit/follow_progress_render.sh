_render_follow_line_progress_bar_determinate() {
    local pct_clamped="$1"
    if [[ "$pct_clamped" -ge 100 ]]; then
        echo "[====================]"
        return 0
    fi

    local filled=$((pct_clamped * 20 / 100))
    if [[ "$filled" -lt 1 ]]; then
        filled=1
    fi
    local eq_count=$((filled - 1))
    local spaces=$((20 - filled))
    local eq_part=""
    local space_part=""
    if [[ "$eq_count" -gt 0 ]]; then
        eq_part=$(printf "%${eq_count}s" "" | tr ' ' '=')
    fi
    if [[ "$spaces" -gt 0 ]]; then
        space_part=$(printf "%${spaces}s" "")
    fi
    echo "[${eq_part}>${space_part}]"
}

_render_follow_line_progress_bar_unknown() {
    local frame="$1"
    local max_start=15
    local cycle=$((max_start * 2))
    local pos=$((frame % cycle))
    if [[ "$pos" -gt "$max_start" ]]; then
        pos=$((cycle - pos))
    fi

    local prefix=""
    local suffix=""
    if [[ "$pos" -gt 0 ]]; then
        prefix=$(printf "%${pos}s" "")
    fi
    local suffix_len=$((20 - pos - 5))
    if [[ "$suffix_len" -gt 0 ]]; then
        suffix=$(printf "%${suffix_len}s" "")
    fi
    echo "[${prefix}<===>${suffix}]"
}

_get_running_builds_for_progress() {
    local job_name="$1"
    local primary_build_number="$2"
    local primary_build_json="$3"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo "[]"
        return 0
    fi

    local response running_builds primary_running primary_timestamp
    response=$(jenkins_api "${job_path}/api/json?tree=builds[number,building,timestamp,result]{0,10}" 2>/dev/null) || true
    if [[ -n "$response" ]]; then
        running_builds=$(echo "$response" | jq -c '[.builds[]? | select(.building == true) | {number: (.number // 0), timestamp: (.timestamp // 0)}]' 2>/dev/null) || running_builds="[]"
    else
        running_builds="[]"
    fi

    primary_running=$(echo "$primary_build_json" | jq -r '.building // false' 2>/dev/null) || primary_running=false
    primary_timestamp=$(echo "$primary_build_json" | jq -r '.timestamp // 0' 2>/dev/null) || primary_timestamp=0
    if [[ "$primary_running" == "true" ]]; then
        running_builds=$(echo "$running_builds" | jq -c \
            --argjson pnum "$primary_build_number" \
            --argjson pts "$primary_timestamp" \
            'if any(.[]; .number == $pnum) then . else . + [{number: $pnum, timestamp: $pts}] end' 2>/dev/null) || running_builds="[]"
    fi

    echo "$running_builds" | jq -c --argjson pnum "$primary_build_number" \
        '(map(select(.number == $pnum)) | sort_by(.number)) + (map(select(.number != $pnum)) | sort_by(.number))' 2>/dev/null || echo "[]"
}

_get_queued_builds_for_progress() {
    local job_name="$1"
    local max_running_build="$2"

    local queue_response queued
    queue_response=$(jenkins_api "/queue/api/json" 2>/dev/null) || true
    if [[ -z "$queue_response" ]]; then
        echo "[]"
        return 0
    fi

    queued=$(echo "$queue_response" | jq -c --arg job "$job_name" --argjson base "$max_running_build" '
        [.items[]?
         | select((.task.name // "") == $job)
         | select((.cancelled // false) != true)
         | select((.executable.number? // null) == null)
         | {id: (.id // 0), why: (.why // ""), inQueueSince: (.inQueueSince // 0)}
        ]
        | sort_by(.inQueueSince)
        | to_entries
        | map(.value + {number: ($base + .key + 1)})
    ' 2>/dev/null) || queued="[]"
    echo "$queued"
}

_render_follow_line_in_progress() {
    local job_name="$1"
    local build_number="$2"
    local timestamp_ms="$3"
    local estimate_ms="$4"
    local frame="${5:-0}"

    local now_ms elapsed_ms
    now_ms=$(($(date +%s) * 1000))
    elapsed_ms=0
    if [[ "$timestamp_ms" =~ ^[0-9]+$ && "$timestamp_ms" -gt 0 ]]; then
        elapsed_ms=$((now_ms - timestamp_ms))
        if [[ "$elapsed_ms" -lt 0 ]]; then
            elapsed_ms=0
        fi
    fi

    local elapsed_display
    elapsed_display=$(format_duration "$elapsed_ms")

    local line bar
    if [[ "$estimate_ms" =~ ^[1-9][0-9]*$ ]]; then
        local pct_raw pct_clamped estimate_display
        pct_raw=$((elapsed_ms * 100 / estimate_ms))
        pct_clamped="$pct_raw"
        if [[ "$pct_clamped" -lt 0 ]]; then
            pct_clamped=0
        fi
        if [[ "$pct_clamped" -gt 100 ]]; then
            pct_clamped=100
        fi
        bar=$(_render_follow_line_progress_bar_determinate "$pct_clamped")
        estimate_display=$(format_duration "$estimate_ms")
        local status_label
        status_label=$(printf '%-12s' "IN_PROGRESS")
        line="${status_label}Job ${job_name} #${build_number} ${bar} ${pct_raw}% ${elapsed_display} / ~${estimate_display}"
    else
        local status_label
        status_label=$(printf '%-12s' "IN_PROGRESS")
        bar=$(_render_follow_line_progress_bar_unknown "$frame")
        line="${status_label}Job ${job_name} #${build_number} ${bar} ${elapsed_display} / ~unknown"
    fi

    echo "$line"
}

_render_follow_line_queued() {
    local job_name="$1"
    local build_number="$2"
    local in_queue_since_ms="$3"
    local estimate_ms="$4"
    local frame="${5:-0}"

    local now_ms queue_elapsed_ms
    now_ms=$(($(date +%s) * 1000))
    queue_elapsed_ms=0
    if [[ "$in_queue_since_ms" =~ ^[0-9]+$ && "$in_queue_since_ms" -gt 0 ]]; then
        queue_elapsed_ms=$((now_ms - in_queue_since_ms))
        if [[ "$queue_elapsed_ms" -lt 0 ]]; then
            queue_elapsed_ms=0
        fi
    fi

    local queue_elapsed_display
    queue_elapsed_display=$(format_duration "$queue_elapsed_ms")

    local bar estimate_display status_label
    bar=$(_render_follow_line_progress_bar_unknown "$frame")
    status_label=$(printf '%-12s' "QUEUED")
    if [[ "$estimate_ms" =~ ^[1-9][0-9]*$ ]]; then
        estimate_display=$(format_duration "$estimate_ms")
        echo "${status_label}Job ${job_name} #${build_number} ${bar} ${queue_elapsed_display} in queue / ~${estimate_display}"
    else
        echo "${status_label}Job ${job_name} #${build_number} ${bar} ${queue_elapsed_display} in queue / ~unknown"
    fi
}

_render_follow_thread_progress_line() {
    local stage_json="$1"
    local estimates_json="$2"
    local frame="${3:-0}"
    local terminal_cols="${4:-80}"

    local stage_name agent_name start_ms duration_ms
    stage_name=$(echo "$stage_json" | jq -r '.name // "unknown"' 2>/dev/null) || stage_name="unknown"
    agent_name=$(echo "$stage_json" | jq -r '.agent // .execNode // .node // "unknown"' 2>/dev/null) || agent_name="unknown"
    start_ms=$(echo "$stage_json" | jq -r '.startTimeMillis // 0' 2>/dev/null) || start_ms=0
    duration_ms=$(echo "$stage_json" | jq -r '.durationMillis // 0' 2>/dev/null) || duration_ms=0

    local now_ms elapsed_ms
    now_ms=$(($(date +%s) * 1000))
    elapsed_ms=0
    if [[ "$duration_ms" =~ ^[1-9][0-9]*$ ]]; then
        elapsed_ms="$duration_ms"
    elif [[ "$start_ms" =~ ^[1-9][0-9]*$ ]]; then
        elapsed_ms=$((now_ms - start_ms))
        if [[ "$elapsed_ms" -lt 0 ]]; then
            elapsed_ms=0
        fi
    fi

    local estimate_ms
    estimate_ms=$(echo "$estimates_json" | jq -r --arg name "$stage_name" '.[$name] // empty' 2>/dev/null) || estimate_ms=""
    if [[ -z "$estimate_ms" && "$stage_name" == *"->"* ]]; then
        local substage_name
        substage_name="${stage_name##*->}"
        estimate_ms=$(echo "$estimates_json" | jq -r --arg name "$substage_name" '.[$name] // empty' 2>/dev/null) || estimate_ms=""
    fi

    local agent_display bar percent_display elapsed_display estimate_display
    agent_display="$agent_name"
    elapsed_display=$(format_duration "$elapsed_ms")
    if [[ "$estimate_ms" =~ ^[1-9][0-9]*$ ]]; then
        local pct_raw pct_clamped
        pct_raw=$((elapsed_ms * 100 / estimate_ms))
        pct_clamped="$pct_raw"
        if [[ "$pct_clamped" -lt 0 ]]; then
            pct_clamped=0
        fi
        if [[ "$pct_clamped" -gt 100 ]]; then
            pct_clamped=100
        fi
        bar=$(_render_follow_line_progress_bar_determinate "$pct_clamped")
        percent_display="${pct_raw}%"
        estimate_display="~$(format_duration "$estimate_ms")"
    else
        bar=$(_render_follow_line_progress_bar_unknown "$frame")
        percent_display="?"
        estimate_display="~unknown"
    fi

    local stage_display="$stage_name"
    if [[ "${_THREADS_FORMAT:-}" == "${_DEFAULT_THREADS_FORMAT:-}" ]]; then
        local fixed_prefix="  [$(_format_threads_placeholder_value "$agent_display" "left" "14")] "
        local default_tail=" ${bar} ${percent_display} ${elapsed_display} / ${estimate_display}"
        local available_name_width=$((terminal_cols - ${#fixed_prefix} - ${#default_tail}))
        if [[ "$available_name_width" -lt 1 ]]; then
            available_name_width=1
        fi
        stage_display=$(_truncate_follow_progress_text "$stage_display" "$available_name_width")
    fi

    local rendered_line
    rendered_line=$(_apply_threads_format "${_THREADS_FORMAT:-${_DEFAULT_THREADS_FORMAT:-}}" \
        agent_name "$agent_display" \
        stage_name "$stage_display" \
        progress_bar "$bar" \
        percent_display "$percent_display" \
        elapsed_display "$elapsed_display" \
        estimate_display "$estimate_display")
    rendered_line="${rendered_line%$'\n'}"

    if [[ "$terminal_cols" =~ ^[1-9][0-9]*$ ]] && [[ ${#rendered_line} -gt "$terminal_cols" ]]; then
        rendered_line="${rendered_line:0:$terminal_cols}"
    fi

    printf '%s\n' "$rendered_line"
}

_render_follow_thread_progress_lines() {
    local job_name="$1"
    local build_number="$2"
    local frame="${3:-0}"
    local stages_json="${4:-}"

    if [[ "$THREADS_MODE" != "true" ]]; then
        return 0
    fi

    if [[ -z "$stages_json" ]]; then
        stages_json=$(_get_follow_active_stages "$job_name" "$build_number")
    fi
    [[ -z "$stages_json" || "$stages_json" == "null" ]] && stages_json="[]"

    local active_stages
    active_stages=$(echo "$stages_json" | jq -c '[.[] | select((.status // "") == "IN_PROGRESS" and (.is_parallel_wrapper // false) != true)]' 2>/dev/null) || active_stages="[]"

    local active_count
    active_count=$(echo "$active_stages" | jq -r 'length' 2>/dev/null) || active_count=0
    if [[ "$active_count" -le 0 ]]; then
        return 0
    fi

    local terminal_rows terminal_cols max_stage_lines
    terminal_rows=$(_get_follow_progress_terminal_rows)
    terminal_cols=$(_get_follow_progress_terminal_cols)
    max_stage_lines=$((terminal_rows - 3))
    if [[ "$max_stage_lines" -le 0 ]]; then
        return 0
    fi

    local entries idx=0
    entries=$(echo "$active_stages" | jq -c '.[]' 2>/dev/null) || entries=""
    while IFS= read -r stage_entry; do
        [[ -z "$stage_entry" ]] && continue
        if [[ "$idx" -ge "$max_stage_lines" ]]; then
            break
        fi
        _render_follow_thread_progress_line "$stage_entry" "$_FOLLOW_STAGE_ESTIMATES_JSON" "$frame" "$terminal_cols"
        idx=$((idx + 1))
    done <<< "$entries"
}

_redraw_follow_line_progress_lines() {
    local old_count="${_PROGRESS_BAR_LINE_COUNT:-0}"
    local new_lines=("$@")
    local new_count="${#new_lines[@]}"
    local max_count="$old_count"
    if [[ "$new_count" -gt "$max_count" ]]; then
        max_count="$new_count"
    fi
    if [[ "$max_count" -le 0 ]]; then
        return 0
    fi

    local payload=""
    if [[ "$old_count" -gt 0 ]]; then
        payload+=$'\r'
        if [[ "$old_count" -gt 1 ]]; then
            payload+=$(printf '\033[%sA' "$((old_count - 1))")
        fi
    fi

    local idx
    for ((idx=0; idx<max_count; idx++)); do
        local line=""
        if [[ "$idx" -lt "$new_count" ]]; then
            line="${new_lines[$idx]}"
        fi
        payload+=$'\033[K'"$line"
        if [[ "$idx" -lt $((max_count - 1)) ]]; then
            payload+=$'\n'
        fi
    done

    if [[ "$old_count" -gt "$new_count" && "$new_count" -gt 0 ]]; then
        payload+=$(printf '\033[%sA' "$((old_count - new_count))")
    fi

    printf '%b' "$payload"
    _PROGRESS_BAR_LINE_COUNT="$new_count"
    _FOLLOW_PROGRESS_CACHED_LINES=("${new_lines[@]}")
    _FOLLOW_PROGRESS_CACHED_LINE_COUNT="$new_count"
    _FOLLOW_PROGRESS_CACHE_VALID=true
}

_build_follow_line_clear_payload() {
    local old_count="${1:-0}"
    if [[ "$old_count" -le 0 ]]; then
        return 0
    fi

    local payload=$'\r'
    if [[ "$old_count" -gt 1 ]]; then
        payload+=$(printf '\033[%sA' "$((old_count - 1))")
    fi

    local idx
    for ((idx=0; idx<old_count; idx++)); do
        payload+=$'\033[K'
        if [[ "$idx" -lt $((old_count - 1)) ]]; then
            payload+=$'\n'
        fi
    done

    if [[ "$old_count" -gt 1 ]]; then
        payload+=$(printf '\033[%sA' "$((old_count - 1))")
    fi
    printf '%b' "$payload"
}

_append_follow_line_rows_payload() {
    local lines=("$@")
    local count="${#lines[@]}"
    local idx
    for ((idx=0; idx<count; idx++)); do
        printf '%b' $'\033[K'
        printf '%s' "${lines[$idx]}"
        if [[ "$idx" -lt $((count - 1)) ]]; then
            printf '\n'
        fi
    done
}

_forget_follow_line_progress_cache() {
    _FOLLOW_PROGRESS_CACHED_LINES=()
    _FOLLOW_PROGRESS_CACHED_LINE_COUNT=0
    _FOLLOW_PROGRESS_CACHE_VALID=false
}

_print_above_follow_line_progress() {
    local output="$1"
    if [[ -z "$output" ]]; then
        return 0
    fi

    local old_count="${_PROGRESS_BAR_LINE_COUNT:-0}"
    if [[ "$old_count" -le 0 ]] || ! _status_stdout_is_tty; then
        printf '%s\n' "$output"
        return 0
    fi

    local restore_cached=false
    if [[ "$THREADS_MODE" == "true" && "${_FOLLOW_PROGRESS_CACHE_VALID:-false}" == "true" && "${_FOLLOW_PROGRESS_CACHED_LINE_COUNT:-0}" -gt 0 ]]; then
        restore_cached=true
    fi

    local payload=""
    payload+="$(_build_follow_line_clear_payload "$old_count")"
    payload+="$output"$'\n'
    if [[ "$restore_cached" == "true" ]]; then
        payload+="$(_append_follow_line_rows_payload "${_FOLLOW_PROGRESS_CACHED_LINES[@]}")"
        _PROGRESS_BAR_LINE_COUNT="${_FOLLOW_PROGRESS_CACHED_LINE_COUNT:-0}"
    else
        _PROGRESS_BAR_LINE_COUNT=0
    fi

    printf '%b' "$payload"
}

_display_follow_line_progress() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"
    local estimate_ms="$4"
    local frame="${5:-0}"
    local include_queue_lines="${6:-false}"
    local stages_json="${7:-}"

    local primary_ts
    primary_ts=$(echo "$build_json" | jq -r '.timestamp // 0' 2>/dev/null) || primary_ts=0

    local running_builds running_count max_running_build queued_builds
    running_builds=$(_get_running_builds_for_progress "$job_name" "$build_number" "$build_json")
    running_count=$(echo "$running_builds" | jq -r 'length' 2>/dev/null) || running_count=0
    max_running_build=$(echo "$running_builds" | jq -r 'if length == 0 then 0 else (map(.number) | max) end' 2>/dev/null) || max_running_build=0

    local lines=()
    if [[ "$THREADS_MODE" == "true" ]]; then
        local thread_lines
        thread_lines=$(_render_follow_thread_progress_lines "$job_name" "$build_number" "$frame" "$stages_json")
        if [[ -n "$thread_lines" ]]; then
            local thread_line
            while IFS= read -r thread_line; do
                [[ -z "$thread_line" ]] && continue
                lines+=("$thread_line")
            done <<< "$thread_lines"
        fi
    fi
    local primary_line
    primary_line=$(_render_follow_line_in_progress "$job_name" "$build_number" "$primary_ts" "$estimate_ms" "$frame")
    lines+=("$primary_line")

    if [[ "$running_count" -gt 0 ]]; then
        local running_lines
        running_lines=$(echo "$running_builds" | jq -r --argjson pnum "$build_number" '
            map(select(.number != $pnum) | .number as $n | .timestamp as $ts | "\($n)\t\($ts)")
            | .[]
        ' 2>/dev/null) || running_lines=""

        local running_line running_num running_ts
        while IFS=$'\t' read -r running_num running_ts; do
            if [[ -z "$running_num" ]]; then
                continue
            fi
            running_line=$(_render_follow_line_in_progress "$job_name" "$running_num" "$running_ts" "$estimate_ms" "$frame")
            lines+=("$running_line")
        done <<< "$running_lines"
    fi

    if [[ "$include_queue_lines" == "true" ]]; then
        queued_builds=$(_get_queued_builds_for_progress "$job_name" "$max_running_build")
        local queued_lines
        queued_lines=$(echo "$queued_builds" | jq -r '.[] | "\(.number)\t\(.inQueueSince)"' 2>/dev/null) || queued_lines=""
        local queued_line queued_num queued_since
        while IFS=$'\t' read -r queued_num queued_since; do
            if [[ -z "$queued_num" ]]; then
                continue
            fi
            queued_line=$(_render_follow_line_queued "$job_name" "$queued_num" "$queued_since" "$estimate_ms" "$frame")
            lines+=("$queued_line")
        done <<< "$queued_lines"
    fi

    _redraw_follow_line_progress_lines "${lines[@]}"
}

_clear_follow_line_progress() {
    local old_count="${_PROGRESS_BAR_LINE_COUNT:-0}"
    if [[ "$old_count" -le 0 ]]; then
        return 0
    fi

    _build_follow_line_clear_payload "$old_count"
    _PROGRESS_BAR_LINE_COUNT=0
}

_clear_follow_line_progress_final() {
    _clear_follow_line_progress
    _forget_follow_line_progress_cache
}

# Compact line-mode monitor for in-progress builds.
# On TTY, renders animated progress; on non-TTY, waits silently.
# Always prints a single completion line when build finishes.
# Arguments: job_name, build_number, [no_tests]
# Returns: status-line exit code (0=SUCCESS, 1=non-SUCCESS)
_monitor_build_line_mode() {
    local job_name="$1"
    local build_number="$2"
    local no_tests="${3:-false}"
    local include_queue_lines="${4:-false}"
    local interactive_line_mode=false
    if _status_stdout_is_tty; then
        interactive_line_mode=true
    fi

    local elapsed=0
    local line_frame=0
    local estimate_ms=""
    local showed_progress=false
    local build_json building

    if [[ "$interactive_line_mode" == "true" ]]; then
        _prime_follow_progress_estimates "$job_name"
        estimate_ms="${_FOLLOW_BUILD_ESTIMATE_MS:-}"
    fi

    while [[ $elapsed -lt $MAX_BUILD_TIME ]]; do
        build_json=$(get_build_info "$job_name" "$build_number")
        if [[ -z "$build_json" ]]; then
            sleep "$POLL_INTERVAL"
            elapsed=$((elapsed + POLL_INTERVAL))
            line_frame=$((line_frame + 1))
            continue
        fi

        building=$(echo "$build_json" | jq -r '.building // false')
        if [[ "$building" != "true" ]]; then
            break
        fi

        if [[ "$interactive_line_mode" == "true" ]]; then
            local stages_json=""
            if [[ "$THREADS_MODE" == "true" ]]; then
                stages_json=$(_get_follow_active_stages "$job_name" "$build_number")
            fi
            _display_follow_line_progress "$job_name" "$build_number" "$build_json" "$estimate_ms" "$line_frame" "$include_queue_lines" "$stages_json"
            showed_progress=true
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        line_frame=$((line_frame + 1))
    done

    if [[ "${building:-true}" == "true" ]]; then
        if [[ "$showed_progress" == "true" ]]; then
            _clear_follow_line_progress_final
            echo ""
        fi
        bg_log_error "Build #${build_number} did not complete within ${MAX_BUILD_TIME}s timeout"
        return 1
    fi

    if [[ "$showed_progress" == "true" ]]; then
        _clear_follow_line_progress_final
    fi

    _status_line_for_build_json "$job_name" "$build_number" "$build_json" "$no_tests"
}
