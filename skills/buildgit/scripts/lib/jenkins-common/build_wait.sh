# =============================================================================
# Build wait: how long a build waited before doing work
# =============================================================================

# Resolve when a running build started doing work, into
# _FOLLOW_WORK_START_RESULT: the first stage's start time, empty while the
# pipeline has not started a stage (waiting for an executor or a lock), or
# <fallback_ts> (the build trigger time) when wfapi stage data is unavailable.
# A known first-stage start never changes, so it is cached per job/build; call
# this outside a command substitution to keep the cache.
_FOLLOW_WORK_START_CACHE=""
_FOLLOW_WORK_START_RESULT=""
_resolve_follow_work_start() {
    local job_name="$1"
    local build_number="$2"
    local fallback_ts="$3"
    local cache_key="${job_name}#${build_number}="
    _FOLLOW_WORK_START_RESULT="$fallback_ts"

    local cached_line
    while IFS= read -r cached_line; do
        if [[ "$cached_line" == "$cache_key"* ]]; then
            _FOLLOW_WORK_START_RESULT="${cached_line#"$cache_key"}"
            return 0
        fi
    done <<< "$_FOLLOW_WORK_START_CACHE"

    if ! [[ "$build_number" =~ ^[1-9][0-9]*$ ]]; then
        return 0
    fi
    local job_path response
    job_path=$(jenkins_job_path "$job_name")
    [[ -z "$job_path" ]] && return 0
    response=$(jenkins_api "${job_path}/${build_number}/wfapi/describe" 2>/dev/null) || response=""
    [[ -z "$response" ]] && return 0

    local first_start
    first_start=$(echo "$response" | jq -r '
        if (.stages | type) != "array" then "unavailable"
        else ([.stages[] | (.startTimeMillis // 0) | select(. > 0)] | min // "")
        end
    ' 2>/dev/null) || first_start="unavailable"

    if [[ "$first_start" =~ ^[1-9][0-9]*$ ]]; then
        _FOLLOW_WORK_START_CACHE+="${cache_key}${first_start}"$'\n'
        _FOLLOW_WORK_START_RESULT="$first_start"
    elif [[ -z "$first_start" ]]; then
        _FOLLOW_WORK_START_RESULT=""
    fi
}

# Shortest wait worth reporting; shorter waits display as "----".
_BUILD_WAIT_DISPLAY_MIN_MS=10000

# Compute how long a build waited before doing work, into _BUILD_WAIT_MS and
# _BUILD_WAIT_STATE. The wait is the time the build's queue item spent blocked
# or buildable (for example behind disableConcurrentBuilds(), from the metrics
# plugin's TimeInQueueAction; the SCM quiet period is not counted) plus the
# time from the build start to its first stage (a pipeline-level lock() or the
# pipeline agent's executor). _BUILD_WAIT_STATE is:
#   done     - the build reached its first stage (or finished without one)
#   waiting  - still before its first stage; _BUILD_WAIT_MS is the wait so far
#   unknown  - neither queue nor stage data is available
_BUILD_WAIT_MS=""
_BUILD_WAIT_STATE="unknown"
_compute_build_wait() {
    local job_name="$1"
    local build_number="$2"
    local build_json="$3"
    _BUILD_WAIT_MS=""
    _BUILD_WAIT_STATE="unknown"

    local queue_ms timestamp_ms building duration_ms
    queue_ms=$(echo "$build_json" | jq -r '
        [.actions[]? | select(._class? == "jenkins.metrics.impl.TimeInQueueAction")
         | (.blockedDurationMillis // 0) + (.buildableDurationMillis // 0)]
        | first // empty' 2>/dev/null) || queue_ms=""
    timestamp_ms=$(echo "$build_json" | jq -r '.timestamp // 0' 2>/dev/null) || timestamp_ms=0
    building=$(echo "$build_json" | jq -r '.building // false' 2>/dev/null) || building=false
    duration_ms=$(echo "$build_json" | jq -r '.duration // 0' 2>/dev/null) || duration_ms=0
    [[ "$queue_ms" =~ ^[0-9]+$ ]] || queue_ms=""

    _resolve_follow_work_start "$job_name" "$build_number" "unavailable"
    local work_start="$_FOLLOW_WORK_START_RESULT"
    local pre_stage_ms=""
    if [[ "$work_start" =~ ^[1-9][0-9]*$ && "$timestamp_ms" =~ ^[1-9][0-9]*$ ]]; then
        pre_stage_ms=$((work_start - timestamp_ms))
        _BUILD_WAIT_STATE="done"
    elif [[ -z "$work_start" && "$timestamp_ms" =~ ^[1-9][0-9]*$ ]]; then
        if [[ "$building" == "true" ]]; then
            pre_stage_ms=$(( $(date +%s) * 1000 - timestamp_ms ))
            _BUILD_WAIT_STATE="waiting"
        else
            # Finished without starting a stage: all of it was spent waiting.
            [[ "$duration_ms" =~ ^[0-9]+$ ]] || duration_ms=0
            pre_stage_ms="$duration_ms"
            _BUILD_WAIT_STATE="done"
        fi
    elif [[ -n "$queue_ms" ]]; then
        # No pipeline stage data: the queue time is the whole wait.
        pre_stage_ms=0
        _BUILD_WAIT_STATE="done"
    else
        return 0
    fi

    [[ "$pre_stage_ms" -lt 0 ]] && pre_stage_ms=0
    _BUILD_WAIT_MS=$(( ${queue_ms:-0} + pre_stage_ms ))
}

# Header value for the computed wait: "25m 43s", "----" for a wait under
# _BUILD_WAIT_DISPLAY_MIN_MS, "still waiting (2m 10s so far)", or empty when
# the wait is unknown.
_format_build_wait_display() {
    case "$_BUILD_WAIT_STATE" in
        done)
            if [[ "$_BUILD_WAIT_MS" -lt "$_BUILD_WAIT_DISPLAY_MIN_MS" ]]; then
                echo "----"
            else
                format_duration "$_BUILD_WAIT_MS"
            fi
            ;;
        waiting)
            echo "still waiting ($(format_duration "$_BUILD_WAIT_MS") so far)"
            ;;
    esac
}
