# Jenkins API Functions
# =============================================================================

# Global variable set by verify_job_exists
JOB_URL=""

# Make authenticated GET request to Jenkins API
# Usage: jenkins_api "/job/myjob/api/json"
# Returns: Response body (or empty string on failure)
# Note: Uses -f flag so curl returns non-zero on HTTP errors
jenkins_api() {
    local endpoint="$1"
    local url="${JENKINS_URL}${endpoint}"

    curl -s -f -g -u "${JENKINS_USER_ID}:${JENKINS_API_TOKEN}" "$url"
}

# Make authenticated GET request and return body with HTTP status code
# Usage: jenkins_api_with_status "/job/myjob/api/json"
# Returns: Response body followed by newline and HTTP status code
# Example output:
#   {"_class":"hudson.model.FreeStyleProject",...}
#   200
jenkins_api_with_status() {
    local endpoint="$1"
    local url="${JENKINS_URL}${endpoint}"

    curl -s -g -w "\n%{http_code}" -u "${JENKINS_USER_ID}:${JENKINS_API_TOKEN}" "$url"
}

# Make authenticated GET request saving response headers and body to files.
# Used for logText/progressive{Text,Html}, whose X-Text-Size, X-More-Data and
# X-ConsoleAnnotator response headers drive incremental console fetching.
# Usage: jenkins_api_progressive "/job/x/1/logText/progressiveText?start=0" headers_file body_file [console_annotator]
# Returns: curl exit status (non-zero on HTTP errors)
jenkins_api_progressive() {
    local endpoint="$1"
    local headers_file="$2"
    local body_file="$3"
    local console_annotator="${4:-}"
    local url="${JENKINS_URL}${endpoint}"

    if [[ -n "$console_annotator" ]]; then
        curl -s -f -g -u "${JENKINS_USER_ID}:${JENKINS_API_TOKEN}" \
            -H "X-ConsoleAnnotator: ${console_annotator}" \
            -D "$headers_file" -o "$body_file" "$url"
    else
        curl -s -f -g -u "${JENKINS_USER_ID}:${JENKINS_API_TOKEN}" \
            -D "$headers_file" -o "$body_file" "$url"
    fi
}

# Verify Jenkins connectivity and authentication
# Tests connection to Jenkins root API endpoint
# Returns: 0 on success, 1 on failure (with error logged)
verify_jenkins_connection() {

    local response
    local http_code

    # Test basic connectivity
    response=$(jenkins_api_with_status "/api/json")
    http_code=$(echo "$response" | tail -1)

    case "$http_code" in
        200)
            bg_log_success "Connected to Jenkins"
            return 0
            ;;
        401)
            log_error "Jenkins authentication failed (401)"
            log_info "Check JENKINS_USER_ID and JENKINS_API_TOKEN"
            return 1
            ;;
        403)
            log_error "Jenkins permission denied (403)"
            log_info "User may not have required permissions"
            return 1
            ;;
        *)
            log_error "Failed to connect to Jenkins (HTTP $http_code)"
            log_info "Check JENKINS_URL: $JENKINS_URL"
            return 1
            ;;
    esac
}

# Verify that a Jenkins job exists and set JOB_URL global
# Usage: verify_job_exists "my-job-name"
# Sets: JOB_URL global variable to the full job URL
# Returns: 0 on success, 1 on failure (with error logged)
verify_job_exists() {
    local job_name="$1"
    bg_log_info "Verifying job '$job_name' exists..."

    local response
    local http_code
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        log_error "Invalid Jenkins job name: '$job_name'"
        return 1
    fi

    response=$(jenkins_api_with_status "${job_path}/api/json")
    http_code=$(echo "$response" | tail -1)

    case "$http_code" in
        200)
            bg_log_success "Job '$job_name' found"
            JOB_URL="${JENKINS_URL}${job_path}"
            return 0
            ;;
        404)
            log_error "Jenkins job '$job_name' not found"
            log_info "Verify the job name is correct"
            return 1
            ;;
        *)
            log_error "Failed to verify job (HTTP $http_code)"
            return 1
            ;;
    esac
}

# =============================================================================
# Build Trigger Functions
# =============================================================================

# Trigger a new build for a Jenkins job
# Usage: trigger_build "job-name"
# Returns: 0 on success (build queued), 1 on failure
# Outputs: Queue item URL on stdout if successful
#
# Jenkins returns 201 Created with Location header containing queue item URL
# e.g., Location: http://jenkins/queue/item/123/
trigger_build() {
    local job_name="$1"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        log_error "Invalid Jenkins job name: '$job_name'"
        return 1
    fi

    local response http_code location_header

    # POST to the build endpoint
    # Use -D to capture headers to a temp file
    local header_file
    header_file=$(mktemp)

    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -u "${JENKINS_USER_ID}:${JENKINS_API_TOKEN}" \
        -D "$header_file" \
        "${JENKINS_URL}${job_path}/build")

    case "$http_code" in
        201)
            # Build queued successfully - extract Location header
            location_header=$(grep -i "^Location:" "$header_file" | sed 's/^Location:[[:space:]]*//' | tr -d '\r')
            rm -f "$header_file"

            if [[ -n "$location_header" ]]; then
                echo "$location_header"
            fi
            return 0
            ;;
        403)
            rm -f "$header_file"
            log_error "Permission denied to trigger build (403)"
            log_info "User may not have 'Build' permission for job '$job_name'"
            return 1
            ;;
        404)
            rm -f "$header_file"
            log_error "Job not found (404): $job_name"
            return 1
            ;;
        405)
            rm -f "$header_file"
            log_error "Build cannot be triggered (405)"
            log_info "Job may be disabled or not support builds"
            return 1
            ;;
        *)
            rm -f "$header_file"
            log_error "Failed to trigger build (HTTP $http_code)"
            return 1
            ;;
    esac
}

# Wait for a queued build to start executing
# Usage: wait_for_queue_item "queue-item-url" [timeout_seconds]
# Returns: Build number on stdout when build starts, or exits on timeout
# Polls the queue item API until the build starts
wait_for_queue_item() {
    local queue_url="$1"
    local timeout="${2:-120}"
    local expected_build_number="${3:-}"
    local elapsed=0
    local poll_interval=2
    local queue_confirmed=false
    local queue_line_active=false
    WAIT_FOR_QUEUE_ITEM_WHY=""
    WAIT_FOR_QUEUE_ITEM_IN_QUEUE_SINCE=""
    WAIT_FOR_QUEUE_ITEM_ID=""

    # Extract queue item ID from URL and construct API endpoint
    local queue_api_url
    if [[ "$queue_url" =~ /queue/item/([0-9]+) ]]; then
        queue_api_url="${JENKINS_URL}/queue/item/${BASH_REMATCH[1]}/api/json"
    else
        # Assume it's already a full URL, append /api/json
        queue_api_url="${queue_url%/}/api/json"
    fi

    while true; do
        local response
        response=$(curl -s -f -u "${JENKINS_USER_ID}:${JENKINS_API_TOKEN}" "$queue_api_url" 2>/dev/null) || true

        if [[ -n "$response" ]]; then
            queue_confirmed=true
            WAIT_FOR_QUEUE_ITEM_WHY=$(echo "$response" | jq -r '.why // empty' 2>/dev/null)
            WAIT_FOR_QUEUE_ITEM_IN_QUEUE_SINCE=$(echo "$response" | jq -r '.inQueueSince // empty' 2>/dev/null)
            WAIT_FOR_QUEUE_ITEM_ID=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

            # Check if build has started (has executable.number)
            local build_number
            build_number=$(echo "$response" | jq -r '.executable.number // empty' 2>/dev/null)

            if [[ -n "$build_number" && "$build_number" != "null" ]]; then
                if [[ "$queue_line_active" == "true" ]]; then
                    printf '\r\033[K\n' >&2
                fi
                echo "$build_number"
                return 0
            fi

            # Check if cancelled
            local cancelled
            cancelled=$(echo "$response" | jq -r '.cancelled // false' 2>/dev/null)
            if [[ "$cancelled" == "true" ]]; then
                log_error "Build was cancelled while in queue"
                return 1
            fi

            if [[ -n "$WAIT_FOR_QUEUE_ITEM_WHY" ]]; then
                local msg
                if [[ -n "$expected_build_number" && "$expected_build_number" =~ ^[0-9]+$ ]]; then
                    msg="Build #${expected_build_number} is QUEUED — ${WAIT_FOR_QUEUE_ITEM_WHY}"
                else
                    msg="Build is QUEUED — ${WAIT_FOR_QUEUE_ITEM_WHY}"
                fi
                local queue_is_tty=false
                if [[ "${BUILDGIT_FORCE_TTY:-}" == "1" ]]; then
                    queue_is_tty=true
                elif [[ "${BUILDGIT_FORCE_TTY:-}" != "0" && -t 1 ]]; then
                    queue_is_tty=true
                fi
                if [[ "$queue_is_tty" == "true" ]]; then
                    printf '\r\033[K[%s] ℹ %s' "$(date +%H:%M:%S)" "$msg" >&2
                    queue_line_active=true
                else
                    log_info "$msg" >&2
                fi
            fi
        fi

        if [[ "$queue_confirmed" != "true" && "$elapsed" -ge "$timeout" ]]; then
            log_error "Timeout: Build did not start within ${timeout} seconds"
            return 1
        fi

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done
}

# =============================================================================
# Build Information Functions
# =============================================================================

# Get build information as JSON from Jenkins API
# Usage: get_build_info "job-name" "build-number"
# Returns: JSON with number, result, building, timestamp, duration, url fields
#          Empty string on failure
get_build_info() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo ""
        return 0
    fi
    jenkins_api "${job_path}/${build_number}/api/json" 2>/dev/null || echo ""
}

# =============================================================================
# Session console cache (build monitoring)
# =============================================================================
# Every monitor poll reads the console logs of the build and of each
# downstream build. Downloading them whole on each poll costs tens of MB on a
# large monorepo build and stretches a 5s poll to minutes, which delays
# noticing that the build has finished. While BUILDGIT_CONSOLE_CACHE_DIR is
# set, get_console_output/get_console_html read through this cache instead:
#   - a finished build's log is downloaded once and reused for the session;
#   - a running build's log is extended with logText/progressive{Text,Html}
#     ?start=N, so a poll downloads only what was appended since the last one;
#   - within one poll iteration (BUILDGIT_ITER_CACHE_DIR) each log is
#     refreshed at most once.
# Jenkins behavior this relies on (verified against a live Jenkins):
#   - progressiveText sends raw log bytes, with ConsoleNotes embedded and each
#     "\n" sent as "\r\n". Stripping the notes and the trailing "\r" of each
#     line reproduces consoleText byte for byte.
#   - For a running pipeline build, progressiveText returns at most 10000
#     lines per request but reports X-Text-Size at the END of the log, so the
#     next offset is computed from the body (bytes - lines), never taken from
#     that header.
#   - progressiveHtml is capped the same way, but its X-Text-Size is the true
#     offset reached, and X-ConsoleAnnotator carries annotator state (node
#     spans, ANSI colors) into the next request.
#   - X-More-Data: true is sent while the log can still grow.

# A response that stops short of X-Text-Size is treated as line-capped only
# when it carries at least this many lines (Jenkins caps at 10000).
_CONSOLE_PROGRESSIVE_MIN_CAPPED_LINES=1000

_console_session_cache_begin() {
    _console_session_cache_end
    BUILDGIT_CONSOLE_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/buildgit-console-cache.XXXXXX")"
    export BUILDGIT_CONSOLE_CACHE_DIR
}

_console_session_cache_end() {
    if [[ -n "${BUILDGIT_CONSOLE_CACHE_DIR:-}" ]]; then
        rm -rf "$BUILDGIT_CONSOLE_CACHE_DIR" 2>/dev/null || true
        unset BUILDGIT_CONSOLE_CACHE_DIR
    fi
}

# Print the value of one response header (last occurrence, case-insensitive).
# Usage: _progressive_header headers_file "X-Text-Size"
_progressive_header() {
    local headers_file="$1"
    local header_name="$2"

    tr -d '\r' < "$headers_file" 2>/dev/null | awk -v name="$header_name" '
        BEGIN { name = tolower(name) }
        {
            i = index($0, ":")
            if (i > 0 && tolower(substr($0, 1, i - 1)) == name) {
                value = substr($0, i + 1)
                sub(/^[ \t]+/, "", value)
            }
        }
        END { print value }
    '
}

# Convert progressiveText output to consoleText form (see quirks above).
_console_strip_progressive_text() {
    LC_ALL=C sed $'s/\x1b\\[8mha:[^\x1b]*\x1b\\[0m//g; s/\r$//'
}

# Append newly available text-log bytes to "$base".
# Usage: _console_session_refresh_text job_path build_number base
# Returns: 0 when the cache is consistent with Jenkins, 1 on fetch failure
_console_session_refresh_text() {
    local job_path="$1"
    local build_number="$2"
    local base="$3"
    local headers="${base}.hdr"
    local body="${base}.body"
    local offset
    offset=$(cat "${base}.offset" 2>/dev/null) || offset=0
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0

    local rounds=0
    while [[ $rounds -lt 200 ]]; do
        rounds=$((rounds + 1))
        if ! jenkins_api_progressive "${job_path}/${build_number}/logText/progressiveText?start=${offset}" "$headers" "$body"; then
            rm -f "$headers" "$body"
            return 1
        fi
        local text_size more_data body_lines commit_bytes
        text_size=$(_progressive_header "$headers" "X-Text-Size")
        more_data=$(_progressive_header "$headers" "X-More-Data")
        if [[ ! "$text_size" =~ ^[0-9]+$ ]]; then
            rm -f "$headers" "$body"
            return 1
        fi
        if [[ "$text_size" -lt "$offset" ]]; then
            # The log shrank (build replaced?) - start over from scratch.
            : > "$base"
            offset=0
            echo "$offset" > "${base}.offset"
            continue
        fi
        body_lines=$(wc -l < "$body" | tr -d ' ')
        local partial_tail=false
        if [[ "$more_data" == "true" && -s "$body" && -n "$(tail -c 1 "$body")" ]]; then
            # A running build's last line may still be growing; commit whole
            # lines only and pick the rest up on a later poll.
            partial_tail=true
            head -n "$body_lines" "$body" > "${body}.lines"
            mv "${body}.lines" "$body"
        fi
        commit_bytes=$(wc -c < "$body" | tr -d ' ')
        local next_offset=$((offset + commit_bytes - body_lines))
        # An uncapped response ends exactly at X-Text-Size. Falling short is
        # expected only for a partial last line or a line-capped response;
        # anything else means the offset model does not hold for this log,
        # so drop the entry and let the caller fetch consoleText whole.
        if [[ "$next_offset" -gt "$text_size" ]] \
            || { [[ "$next_offset" -lt "$text_size" && "$partial_tail" != "true" ]] \
                 && [[ "$body_lines" -lt "$_CONSOLE_PROGRESSIVE_MIN_CAPPED_LINES" ]]; }; then
            rm -f "$base" "${base}.offset" "$headers" "$body"
            : > "${base}.nocache"
            return 1
        fi
        if [[ "$commit_bytes" -gt 0 ]]; then
            _console_strip_progressive_text < "$body" >> "$base"
        fi
        offset="$next_offset"
        echo "$offset" > "${base}.offset"
        rm -f "$headers" "$body"
        if [[ "$more_data" != "true" && "$offset" -eq "$text_size" ]]; then
            : > "${base}.done"
            break
        fi
        # Keep reading only while a capped response stopped short of the end.
        if [[ "$partial_tail" == "true" || "$commit_bytes" -eq 0 || "$offset" -ge "$text_size" ]]; then
            break
        fi
    done
    return 0
}

# Append newly available annotated-HTML log to "$base".
# Usage: _console_session_refresh_html job_path build_number base
# Returns: 0 when the cache is consistent with Jenkins, 1 on fetch failure
_console_session_refresh_html() {
    local job_path="$1"
    local build_number="$2"
    local base="$3"
    local headers="${base}.hdr"
    local body="${base}.body"
    local offset annotator
    offset=$(cat "${base}.offset" 2>/dev/null) || offset=0
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    annotator=$(cat "${base}.annotator" 2>/dev/null) || annotator=""

    local rounds=0
    while [[ $rounds -lt 200 ]]; do
        rounds=$((rounds + 1))
        if ! jenkins_api_progressive "${job_path}/${build_number}/logText/progressiveHtml?start=${offset}" "$headers" "$body" "$annotator"; then
            rm -f "$headers" "$body"
            return 1
        fi
        local text_size more_data
        text_size=$(_progressive_header "$headers" "X-Text-Size")
        more_data=$(_progressive_header "$headers" "X-More-Data")
        if [[ ! "$text_size" =~ ^[0-9]+$ ]]; then
            rm -f "$headers" "$body"
            return 1
        fi
        if [[ "$text_size" -lt "$offset" ]]; then
            : > "$base"
            offset=0
            annotator=""
            echo "$offset" > "${base}.offset"
            rm -f "${base}.annotator"
            continue
        fi
        if [[ "$more_data" == "true" && -s "$body" ]]; then
            # Each chunk ends with the closing tag of its last node span. A
            # chunk ending mid-line cannot be resumed at a known offset, so
            # it is dropped and re-read on a later poll.
            local chunk_tail
            chunk_tail=$(tail -c 32 "$body"; printf 'x')
            chunk_tail="${chunk_tail%x}"
            while [[ "$chunk_tail" == *"</span>" ]]; do
                chunk_tail="${chunk_tail%</span>}"
            done
            if [[ "$chunk_tail" != *$'\n' ]]; then
                rm -f "$headers" "$body"
                break
            fi
        fi
        cat "$body" >> "$base"
        local advanced=true
        [[ "$text_size" -eq "$offset" ]] && advanced=false
        offset="$text_size"
        echo "$offset" > "${base}.offset"
        annotator=$(_progressive_header "$headers" "X-ConsoleAnnotator")
        if [[ -n "$annotator" ]]; then
            printf '%s' "$annotator" > "${base}.annotator"
        fi
        rm -f "$headers" "$body"
        if [[ "$more_data" != "true" ]]; then
            : > "${base}.done"
            break
        fi
        [[ "$advanced" == "true" ]] || break
    done
    return 0
}

# Return 0 when the session cache already holds the complete (final) text log
# of a build, i.e. Jenkins reported the build finished when it was fetched.
# Usage: _console_session_log_complete "job-name" "build-number"
_console_session_log_complete() {
    local job_name="$1"
    local build_number="$2"
    [[ -n "${BUILDGIT_CONSOLE_CACHE_DIR:-}" ]] || return 1
    local safe_job_name
    safe_job_name=$(printf '%s' "$job_name" | tr '/ ' '__')
    [[ -f "${BUILDGIT_CONSOLE_CACHE_DIR}/text_${safe_job_name}_${build_number}.done" ]]
}

_console_session_cache_is_fresh() {
    local base="$1"
    local iter_marker="$2"
    [[ -f "${base}.done" ]] || [[ -n "$iter_marker" && -f "$iter_marker" ]]
}

# Read a build log through the session cache.
# Usage: _console_session_cache_get text|html "job-name" "build-number"
# Returns: 0 with the log on stdout, 1 (no output) when the caller should
#          fall back to an uncached full fetch
_console_session_cache_get() {
    local kind="$1"
    local job_name="$2"
    local build_number="$3"
    [[ -n "${BUILDGIT_CONSOLE_CACHE_DIR:-}" && -d "$BUILDGIT_CONSOLE_CACHE_DIR" ]] || return 1

    local job_path
    job_path=$(jenkins_job_path "$job_name")
    [[ -n "$job_path" ]] || return 1

    local safe_job_name base iter_marker=""
    safe_job_name=$(printf '%s' "$job_name" | tr '/ ' '__')
    base="${BUILDGIT_CONSOLE_CACHE_DIR}/${kind}_${safe_job_name}_${build_number}"
    if [[ -n "${BUILDGIT_ITER_CACHE_DIR:-}" && -d "$BUILDGIT_ITER_CACHE_DIR" ]]; then
        iter_marker="${BUILDGIT_ITER_CACHE_DIR}/console_fresh_${kind}_${safe_job_name}_${build_number}"
    fi
    # Set when this log broke the progressive offset model; fetch it whole.
    [[ -f "${base}.nocache" ]] && return 1

    if ! _console_session_cache_is_fresh "$base" "$iter_marker"; then
        # Background fetchers (parallel nested-stage expansion) can refresh
        # the same log concurrently; serialize with a mkdir lock.
        local waited=0
        while ! mkdir "${base}.lock" 2>/dev/null; do
            if [[ $waited -ge 300 ]]; then
                return 1
            fi
            sleep 0.1
            waited=$((waited + 1))
        done
        if ! _console_session_cache_is_fresh "$base" "$iter_marker"; then
            touch "$base"
            if ! "_console_session_refresh_${kind}" "$job_path" "$build_number" "$base"; then
                rmdir "${base}.lock" 2>/dev/null || true
                return 1
            fi
            if [[ -n "$iter_marker" ]]; then
                : > "$iter_marker"
            fi
        fi
        rmdir "${base}.lock" 2>/dev/null || true
    fi

    cat "$base" 2>/dev/null || true
    return 0
}

# Get console text output for a build
# Usage: get_console_output "job-name" "build-number"
# Returns: Console text, empty string on failure
get_console_output() {
    local job_name="$1"
    local build_number="$2"
    if [[ -n "${BUILDGIT_CONSOLE_CACHE_DIR:-}" ]] \
        && _console_session_cache_get text "$job_name" "$build_number"; then
        return 0
    fi
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo ""
        return 0
    fi
    jenkins_api "${job_path}/${build_number}/consoleText" 2>/dev/null || echo ""
}

get_console_output_cached() {
    local job_name="$1"
    local build_number="$2"

    if [[ -n "${BUILDGIT_ITER_CACHE_DIR:-}" && -d "$BUILDGIT_ITER_CACHE_DIR" ]]; then
        local safe_job_name cache_file output
        safe_job_name=$(printf '%s' "$job_name" | tr '/ ' '__')
        cache_file="${BUILDGIT_ITER_CACHE_DIR}/console_${safe_job_name}_${build_number}"

        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return 0
        fi

        output=$(get_console_output "$job_name" "$build_number")
        printf '%s' "$output" > "$cache_file"
        printf '%s' "$output"
        return 0
    fi

    get_console_output "$job_name" "$build_number"
}

# Get annotated HTML console output for a build (logText/progressiveHtml).
# Unlike consoleText, each flow-node block start carries nodeId/enclosingId/
# label attributes and log lines carry a pipeline-node-<id> class, which lets
# callers attribute "Running on <agent>" lines to their exact pipeline stage.
# Usage: get_console_html "job-name" "build-number"
# Returns: HTML console text, empty string on failure
get_console_html() {
    local job_name="$1"
    local build_number="$2"
    if [[ -n "${BUILDGIT_CONSOLE_CACHE_DIR:-}" ]] \
        && _console_session_cache_get html "$job_name" "$build_number"; then
        return 0
    fi
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo ""
        return 0
    fi
    jenkins_api "${job_path}/${build_number}/logText/progressiveHtml" 2>/dev/null || echo ""
}

get_console_html_cached() {
    local job_name="$1"
    local build_number="$2"

    if [[ -n "${BUILDGIT_ITER_CACHE_DIR:-}" && -d "$BUILDGIT_ITER_CACHE_DIR" ]]; then
        local safe_job_name cache_file output
        safe_job_name=$(printf '%s' "$job_name" | tr '/ ' '__')
        cache_file="${BUILDGIT_ITER_CACHE_DIR}/console_html_${safe_job_name}_${build_number}"

        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return 0
        fi

        output=$(get_console_html "$job_name" "$build_number")
        printf '%s' "$output" > "$cache_file"
        printf '%s' "$output"
        return 0
    fi

    get_console_html "$job_name" "$build_number"
}

_STAGE_CONSOLE_AVAILABLE_STAGES=""
_STAGE_CONSOLE_AMBIGUOUS_STAGES=""

_normalize_stage_name_for_lookup() {
    local stage_name="$1"
    printf '%s\n' "${stage_name#Branch: }"
}

_stage_lookup_label() {
    local stage_name="$1"
    printf '%s\n' "$stage_name" | tr '[:upper:]' '[:lower:]'
}

_find_stage_console_match() {
    local stages_json="$1"
    local requested_stage_name="$2"
    local normalized_requested requested_lower normalized_lower

    normalized_requested=$(_normalize_stage_name_for_lookup "$requested_stage_name")
    requested_lower=$(_stage_lookup_label "$requested_stage_name")
    normalized_lower=$(_stage_lookup_label "$normalized_requested")
    _STAGE_CONSOLE_AMBIGUOUS_STAGES=""

    if [[ -z "$stages_json" || "$stages_json" == "[]" ]]; then
        return 1
    fi

    local match_json
    match_json=$(echo "$stages_json" | jq -c \
        --arg requested "$requested_stage_name" \
        --arg normalized "$normalized_requested" \
        --arg requested_lower "$requested_lower" \
        --arg normalized_lower "$normalized_lower" '
        def normalized_name($name): ($name | sub("^Branch: "; ""));
        def lowered($value): ($value | ascii_downcase);
        def exact_match:
            map(select((.name // "") == $requested or normalized_name(.name // "") == $normalized));
        def exact_ci_match:
            map(select(lowered(.name // "") == $requested_lower or lowered(normalized_name(.name // "")) == $normalized_lower));
        def contains_ci_match:
            map(select(
                lowered(.name // "") | contains($requested_lower) or contains($normalized_lower)
            ));
        def best_match:
            (exact_match) as $exact
            | if ($exact | length) > 0 then $exact
              else
                (exact_ci_match) as $exact_ci
                | if ($exact_ci | length) > 0 then $exact_ci else contains_ci_match end
              end;

        (best_match) as $matches
        | if ($matches | length) == 1 then
            {status: "ok", match: $matches[0]}
          elif ($matches | length) > 1 then
            {status: "ambiguous", matches: ($matches | map(.name))}
          else
            {status: "missing"}
          end
    ' 2>/dev/null) || return 1

    local match_status
    match_status=$(echo "$match_json" | jq -r '.status // "missing"' 2>/dev/null)
    case "$match_status" in
        ok)
            echo "$match_json" | jq -c '.match' 2>/dev/null
            return 0
            ;;
        ambiguous)
            _STAGE_CONSOLE_AMBIGUOUS_STAGES=$(echo "$match_json" | jq -r '.matches[]' 2>/dev/null || true)
            return 4
            ;;
        *)
            return 1
            ;;
    esac
}

_get_stage_console_descendants() {
    local stages_json="$1"
    local blue_nodes_json="$2"
    local root_stage_id="$3"

    if [[ -z "$stages_json" || "$stages_json" == "[]" || -z "$blue_nodes_json" || "$blue_nodes_json" == "[]" || -z "$root_stage_id" ]]; then
        echo "[]"
        return 0
    fi

    echo "$stages_json" | jq -c \
        --arg root_id "$root_stage_id" \
        --argjson nodes "$blue_nodes_json" '
        def node_by_id($id):
            first($nodes[] | select((.id // "" | tostring) == ($id | tostring)));
        def is_descendant_of($id):
            if ($id | tostring) == ($root_id | tostring) then
                true
            else
                (node_by_id($id)) as $node
                | if ($node == null) then
                    false
                  else
                    ($node.firstParent // "") as $parent
                    | if $parent == "" then
                        false
                      else
                        is_descendant_of($parent)
                      end
                  end
            end;

        [ .[] | select((.id // "") != "" and is_descendant_of(.id)) ]
    ' 2>/dev/null || echo "[]"
}

_get_stage_console_log_text() {
    local job_path="$1"
    local build_number="$2"
    local stage_id="$3"

    local response http_code body
    response=$(jenkins_api_with_status "${job_path}/${build_number}/execution/node/${stage_id}/wfapi/log" || true)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        return 1
    fi

    local body_type log_text
    body_type=$(echo "$body" | jq -r 'type // empty' 2>/dev/null) || true
    log_text=$(echo "$body" | jq -r 'if type == "object" then (.text // "") else empty end' 2>/dev/null) || true
    if [[ "$body_type" == "object" ]]; then
        printf '%s' "$log_text" | perl -0pe 's/<[^>]+>//g; s/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/\r//g'
    else
        printf '%s' "$body"
    fi
}

_get_stage_console_flow_nodes() {
    local job_path="$1"
    local build_number="$2"
    local stage_id="$3"

    if [[ -z "$job_path" || -z "$build_number" || -z "$stage_id" ]]; then
        echo "[]"
        return 0
    fi

    local response
    response=$(jenkins_api "${job_path}/${build_number}/execution/node/${stage_id}/wfapi/describe" 2>/dev/null) || true
    if [[ -z "$response" ]]; then
        echo "[]"
        return 0
    fi

    echo "$response" | jq -c '
        def flatten_nodes($nodes):
            [
                $nodes[]?
                | {id: (.id // ""), name: (.name // "")},
                  ((.stageFlowNodes // []) | flatten_nodes(.))[]
            ];
        flatten_nodes(.stageFlowNodes // [])
    ' 2>/dev/null || echo "[]"
}

_get_stage_console_candidate_nodes() {
    local job_path="$1"
    local build_number="$2"
    local stages_json="$3"
    local blue_nodes_json="$4"
    local root_stage_id="$5"

    local result_json descendant_stages_json descendant_count descendant_index
    result_json=$(_get_stage_console_flow_nodes "$job_path" "$build_number" "$root_stage_id")
    descendant_stages_json=$(_get_stage_console_descendants "$stages_json" "$blue_nodes_json" "$root_stage_id")
    descendant_count=$(echo "$descendant_stages_json" | jq 'length' 2>/dev/null || echo 0)
    descendant_index=0

    while [[ "$descendant_index" -lt "$descendant_count" ]]; do
        local descendant_json descendant_id descendant_flow_nodes_json
        descendant_json=$(echo "$descendant_stages_json" | jq -c ".[$descendant_index]" 2>/dev/null)
        descendant_id=$(echo "$descendant_json" | jq -r '.id // empty' 2>/dev/null)
        descendant_index=$((descendant_index + 1))

        if [[ -z "$descendant_id" || "$descendant_id" == "$root_stage_id" ]]; then
            continue
        fi

        descendant_flow_nodes_json=$(_get_stage_console_flow_nodes "$job_path" "$build_number" "$descendant_id")
        result_json=$(jq -cs '
            add
            | reduce .[] as $node (
                [];
                if (($node.id // "") == "") then
                    .
                elif any(.[]; (.id // "") == ($node.id // "")) then
                    .
                else
                    . + [$node]
                end
            )
        ' \
            <(printf '%s\n' "$result_json") \
            <(printf '%s\n' "[$descendant_json]") \
            <(printf '%s\n' "$descendant_flow_nodes_json") 2>/dev/null)
    done

    printf '%s\n' "${result_json:-[]}"
}

get_console_output_raw() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        return 1
    fi

    local response http_code body
    response=$(jenkins_api_with_status "${job_path}/${build_number}/consoleText" || true)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        printf '%s\n' "$body"
        return 0
    fi
    return 1
}

get_stage_console_output() {
    local job_name="$1"
    local build_number="$2"
    local requested_stage_name="$3"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        return 1
    fi

    local stages_json blue_nodes_json matched_stage_json matched_stage_id matched_stage_name
    stages_json=$(get_all_stages "$job_name" "$build_number")
    _STAGE_CONSOLE_AVAILABLE_STAGES=$(echo "$stages_json" | jq -r '.[].name' 2>/dev/null || true)
    matched_stage_json=$(_find_stage_console_match "$stages_json" "$requested_stage_name") || {
        local match_rc=$?
        if [[ "$match_rc" -eq 4 ]]; then
            return 4
        fi
        return 3
    }

    matched_stage_id=$(echo "$matched_stage_json" | jq -r '.id // empty' 2>/dev/null)
    matched_stage_name=$(echo "$matched_stage_json" | jq -r '.name // empty' 2>/dev/null)
    if [[ -z "$matched_stage_id" ]]; then
        return 3
    fi

    local direct_log_text
    if ! direct_log_text=$(_get_stage_console_log_text "$job_path" "$build_number" "$matched_stage_id"); then
        return 1
    fi

    if [[ -n "${direct_log_text//[$' \t\r\n']}" ]]; then
        printf '%s\n' "$direct_log_text"
        return 0
    fi

    blue_nodes_json=$(get_blue_ocean_nodes "$job_name" "$build_number" 2>/dev/null) || blue_nodes_json="[]"

    local candidate_nodes_json
    candidate_nodes_json=$(_get_stage_console_candidate_nodes "$job_path" "$build_number" "$stages_json" "$blue_nodes_json" "$matched_stage_id")

    local candidate_count candidate_index combined_output
    candidate_count=$(echo "$candidate_nodes_json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$candidate_count" -eq 0 ]]; then
        printf '%s\n' "$direct_log_text"
        return 0
    fi

    combined_output=""
    candidate_index=0
    while [[ "$candidate_index" -lt "$candidate_count" ]]; do
        local candidate_id candidate_name candidate_log
        candidate_id=$(echo "$candidate_nodes_json" | jq -r ".[$candidate_index].id // empty" 2>/dev/null)
        candidate_name=$(echo "$candidate_nodes_json" | jq -r ".[$candidate_index].name // empty" 2>/dev/null)
        candidate_index=$((candidate_index + 1))
        [[ -z "$candidate_id" || "$candidate_id" == "$matched_stage_id" ]] && continue
        if ! candidate_log=$(_get_stage_console_log_text "$job_path" "$build_number" "$candidate_id"); then
            return 1
        fi
        if [[ -z "${candidate_log//[$' \t\r\n']}" ]]; then
            continue
        fi
        combined_output+=$'\n'"===== ${matched_stage_name} -> ${candidate_name} ====="$'\n'
        combined_output+="$candidate_log"
        combined_output+=$'\n'
    done

    if [[ -n "${combined_output//[$' \t\r\n']}" ]]; then
        printf '%s' "$combined_output"
    else
        printf '%s\n' "$direct_log_text"
    fi
    return 0
}

# Get currently executing stage name from workflow API
# Usage: get_current_stage "job-name" "build-number"
# Returns: Stage name if a stage is IN_PROGRESS, empty string otherwise
get_current_stage() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        return 0
    fi

    local response
    response=$(jenkins_api "${job_path}/${build_number}/wfapi/describe" 2>/dev/null) || true

    if [[ -n "$response" ]]; then
        # Find the currently executing stage (status IN_PROGRESS)
        echo "$response" | jq -r '.stages[] | select(.status == "IN_PROGRESS") | .name' 2>/dev/null | head -1
    fi
}

# Fetch all stages with statuses and timing from wfapi/describe
# Usage: get_all_stages "job-name" "build-number"
# Returns: JSON array of stage objects on stdout
#          Each object has: name, status, startTimeMillis, durationMillis
#          Returns empty array [] on error or if no stages exist
# Spec: full-stage-print-spec.md, Section: API Data Source
get_all_stages() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo "[]"
        return 0
    fi

    local response
    response=$(jenkins_api "${job_path}/${build_number}/wfapi/describe" 2>/dev/null) || true

    if [[ -z "$response" ]]; then
        echo "[]"
        return 0
    fi

    # Extract stages array with required fields
    # Handle missing fields gracefully with defaults
    local stages_json
    stages_json=$(echo "$response" | jq -r '
        .stages // [] |
        map({
            id: (.id // ""),
            name: (.name // "unknown"),
            status: (.status // "NOT_EXECUTED"),
            startTimeMillis: (.startTimeMillis // 0),
            durationMillis: (.durationMillis // 0)
        })
    ' 2>/dev/null) || true

    if [[ -z "$stages_json" || "$stages_json" == "null" ]]; then
        echo "[]"
        return 0
    fi

    echo "$stages_json"
}

get_blue_ocean_nodes() {
    local job_name="$1"
    local build_number="$2"

    local response endpoint
    if [[ "$job_name" == */* ]]; then
        local top_job branch_job encoded_top encoded_branch
        top_job="${job_name%%/*}"
        branch_job="${job_name#*/}"
        encoded_top=$(printf '%s' "$top_job" | jq -sRr @uri)
        encoded_branch=$(printf '%s' "$branch_job" | jq -sRr @uri)
        endpoint="/blue/rest/organizations/jenkins/pipelines/${encoded_top}/branches/${encoded_branch}/runs/${build_number}/nodes/"
    else
        local encoded_job
        encoded_job=$(printf '%s' "$job_name" | jq -sRr @uri)
        endpoint="/blue/rest/organizations/jenkins/pipelines/${encoded_job}/runs/${build_number}/nodes/"
    fi

    response=$(jenkins_api "$endpoint" 2>/dev/null) || true
    if [[ -z "$response" ]]; then
        echo "[]"
        return 0
    fi

    echo "$response" | jq -c '
        map({
            id: (.id // ""),
            name: (.displayName // .name // ""),
            type: (.type // ""),
            firstParent: (.firstParent // ""),
            startTime: (.startTime // ""),
            durationMillis: (.durationInMillis // 0)
        })
    ' 2>/dev/null || echo "[]"
}

get_blue_ocean_node_steps() {
    local job_name="$1"
    local build_number="$2"
    local node_id="$3"

    local response endpoint
    if [[ "$job_name" == */* ]]; then
        local top_job branch_job encoded_top encoded_branch
        top_job="${job_name%%/*}"
        branch_job="${job_name#*/}"
        encoded_top=$(printf '%s' "$top_job" | jq -sRr @uri)
        encoded_branch=$(printf '%s' "$branch_job" | jq -sRr @uri)
        endpoint="/blue/rest/organizations/jenkins/pipelines/${encoded_top}/branches/${encoded_branch}/runs/${build_number}/nodes/${node_id}/steps/"
    else
        local encoded_job
        encoded_job=$(printf '%s' "$job_name" | jq -sRr @uri)
        endpoint="/blue/rest/organizations/jenkins/pipelines/${encoded_job}/runs/${build_number}/nodes/${node_id}/steps/"
    fi

    response=$(jenkins_api "$endpoint" 2>/dev/null) || true
    if [[ -z "$response" ]]; then
        echo "[]"
        return 0
    fi

    echo "$response" | jq -c '
        map({
            displayName: (.displayName // ""),
            displayDescription: (.displayDescription // "")
        })
    ' 2>/dev/null || echo "[]"
}

# Get first failed stage name from workflow API
# Usage: get_failed_stage "job-name" "build-number"
# Returns: Stage name if a stage is FAILED or UNSTABLE, empty string otherwise
get_failed_stage() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        return 0
    fi

    local response
    response=$(jenkins_api "${job_path}/${build_number}/wfapi/describe" 2>/dev/null) || true

    if [[ -n "$response" ]]; then
        echo "$response" | jq -r '.stages[] | select(.status == "FAILED" or .status == "UNSTABLE") | .name' 2>/dev/null | head -1
    fi
}

# Get the last build number for a job
# Usage: get_last_build_number "job-name"
# Returns: Build number (numeric), or 0 if no builds exist or on error
get_last_build_number() {
    local job_name="$1"
    local response
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo "0"
        return 0
    fi
    response=$(jenkins_api "${job_path}/api/json" 2>/dev/null) || true

    if [[ -n "$response" ]]; then
        # Suppress jq parse errors: this runs on every poll of the follow loop,
        # so an unparseable response must not spam the terminal.
        echo "$response" | jq -r '.lastBuild.number // 0' 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}
