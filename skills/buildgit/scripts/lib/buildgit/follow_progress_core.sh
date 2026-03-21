# Checks whether status line follow mode should render interactive output.
# BUILDGIT_FORCE_TTY=1 is test-only and allows deterministic TTY-path tests.
_status_stdout_is_tty() {
    if [[ "${BUILDGIT_FORCE_TTY:-}" == "1" ]]; then
        return 0
    fi
    [[ -t 1 ]]
}

_get_follow_progress_terminal_rows() {
    if [[ "${LINES:-}" =~ ^[1-9][0-9]*$ ]]; then
        echo "$LINES"
        return 0
    fi
    if command -v tput >/dev/null 2>&1; then
        local rows
        rows=$(tput lines 2>/dev/null) || rows=""
        if [[ "$rows" =~ ^[1-9][0-9]*$ ]]; then
            echo "$rows"
            return 0
        fi
    fi
    echo "24"
}

_get_follow_progress_terminal_cols() {
    if [[ "${COLUMNS:-}" =~ ^[1-9][0-9]*$ ]]; then
        echo "$COLUMNS"
        return 0
    fi
    if command -v tput >/dev/null 2>&1; then
        local cols
        cols=$(tput cols 2>/dev/null) || cols=""
        if [[ "$cols" =~ ^[1-9][0-9]*$ ]]; then
            echo "$cols"
            return 0
        fi
    fi
    echo "80"
}

_truncate_follow_progress_text() {
    local text="$1"
    local max_width="$2"

    if [[ "$max_width" -le 0 ]]; then
        echo ""
        return 0
    fi
    if [[ ${#text} -le "$max_width" ]]; then
        echo "$text"
        return 0
    fi
    if [[ "$max_width" -le 3 ]]; then
        printf '%.*s' "$max_width" "$text"
        return 0
    fi
    printf '%s...' "${text:0:$((max_width - 3))}"
}

_truncate_threads_format_value() {
    local value="$1"
    local width="$2"

    if [[ -z "$width" ]]; then
        printf '%s' "$value"
        return 0
    fi
    if [[ "$width" -le 0 ]]; then
        return 0
    fi
    if [[ ${#value} -le "$width" ]]; then
        printf '%s' "$value"
        return 0
    fi
    printf '%s' "${value:0:$width}"
}

_format_threads_placeholder_value() {
    local value="$1"
    local align="$2"
    local width="$3"

    value=$(_truncate_threads_format_value "$value" "$width")

    if [[ -z "$width" ]]; then
        printf '%s' "$value"
        return 0
    fi

    if [[ "$align" == "left" ]]; then
        printf "%-${width}s" "$value"
    else
        printf "%${width}s" "$value"
    fi
}

_apply_threads_format() {
    local format_string="$1"
    shift

    local agent_name="" stage_name="" progress_bar="" percent_display="" elapsed_display="" estimate_display=""
    while [[ $# -gt 1 ]]; do
        case "$1" in
            agent_name) agent_name="$2" ;;
            stage_name) stage_name="$2" ;;
            progress_bar) progress_bar="$2" ;;
            percent_display) percent_display="$2" ;;
            elapsed_display) elapsed_display="$2" ;;
            estimate_display) estimate_display="$2" ;;
        esac
        shift 2
    done

    local output="" idx=0 fmt_len=${#format_string}
    while [[ "$idx" -lt "$fmt_len" ]]; do
        local ch="${format_string:$idx:1}"
        if [[ "$ch" != "%" ]]; then
            output+="$ch"
            idx=$((idx + 1))
            continue
        fi

        idx=$((idx + 1))
        if [[ "$idx" -ge "$fmt_len" ]]; then
            output+="%"
            break
        fi

        local align="right"
        if [[ "${format_string:$idx:1}" == "-" ]]; then
            align="left"
            idx=$((idx + 1))
        fi

        local width=""
        while [[ "$idx" -lt "$fmt_len" ]]; do
            local digit="${format_string:$idx:1}"
            case "$digit" in
                [0-9])
                    width+="$digit"
                    idx=$((idx + 1))
                    ;;
                *)
                    break
                    ;;
            esac
        done

        if [[ "$idx" -ge "$fmt_len" ]]; then
            output+="%"
            if [[ "$align" == "left" ]]; then
                output+="-"
            fi
            output+="$width"
            break
        fi

        local token="${format_string:$idx:1}"
        local value="" recognized=true
        case "$token" in
            a) value="$agent_name" ;;
            S) value="$stage_name" ;;
            g) value="$progress_bar" ;;
            p) value="$percent_display" ;;
            e) value="$elapsed_display" ;;
            E) value="$estimate_display" ;;
            %) value="%" ;;
            *)
                recognized=false
                ;;
        esac

        if [[ "$recognized" == "true" ]]; then
            output+="$(_format_threads_placeholder_value "$value" "$align" "$width")"
        else
            output+="%"
            if [[ "$align" == "left" ]]; then
                output+="-"
            fi
            output+="$width$token"
        fi

        idx=$((idx + 1))
    done

    printf '%s\n' "$output"
}

_get_last_successful_build_metadata() {
    local job_name="$1"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo ""
        return 0
    fi

    local response
    response=$(jenkins_api "${job_path}/lastSuccessfulBuild/api/json" 2>/dev/null) || true
    if [[ -z "$response" ]]; then
        echo ""
        return 0
    fi

    echo "$response"
}

# Fetch duration estimate (ms) from Jenkins lastSuccessfulBuild endpoint.
# Returns empty string when unavailable.
_get_last_successful_build_duration() {
    local job_name="$1"
    local response
    response=$(_get_last_successful_build_metadata "$job_name")
    if [[ -z "$response" ]]; then
        echo ""
        return 0
    fi

    local duration
    duration=$(echo "$response" | jq -r '.duration // empty' 2>/dev/null) || true
    if [[ "$duration" =~ ^[0-9]+$ ]]; then
        echo "$duration"
    else
        echo ""
    fi
}

_get_stage_duration_estimates_for_build() {
    local job_name="$1"
    local build_number="$2"
    if ! [[ "$build_number" =~ ^[1-9][0-9]*$ ]]; then
        echo "{}"
        return 0
    fi

    local nested_stages_json
    nested_stages_json=$(_get_nested_stages "$job_name" "$build_number" 2>/dev/null) || nested_stages_json="[]"
    if [[ -z "$nested_stages_json" || "$nested_stages_json" == "null" ]]; then
        echo "{}"
        return 0
    fi

    echo "$nested_stages_json" | jq -c '
        reduce .[] as $stage ({};
            if (($stage.durationMillis // 0) > 0) then
                . + { (($stage.name // "unknown")): ($stage.durationMillis // 0) }
            else
                .
            end
        )
    ' 2>/dev/null || echo "{}"
}

_prime_follow_progress_estimates() {
    local job_name="$1"
    _FOLLOW_BUILD_ESTIMATE_MS=""
    _FOLLOW_STAGE_ESTIMATES_JSON="{}"

    local last_success_json
    last_success_json=$(_get_last_successful_build_metadata "$job_name")
    if [[ -z "$last_success_json" ]]; then
        return 0
    fi

    local duration build_number
    duration=$(echo "$last_success_json" | jq -r '.duration // empty' 2>/dev/null) || duration=""
    build_number=$(echo "$last_success_json" | jq -r '.number // empty' 2>/dev/null) || build_number=""

    if [[ "$THREADS_MODE" == "true" ]]; then
        _FOLLOW_STAGE_ESTIMATES_JSON=$(_get_stage_duration_estimates_for_build "$job_name" "$build_number")
    fi

    if [[ "$duration" =~ ^[0-9]+$ ]]; then
        _FOLLOW_BUILD_ESTIMATE_MS="$duration"
    fi
}

_get_follow_active_stages() {
    local job_name="$1"
    local build_number="$2"
    if ! [[ "$build_number" =~ ^[1-9][0-9]*$ ]]; then
        echo "[]"
        return 0
    fi

    local nested_stages_json
    nested_stages_json=$(_get_nested_stages "$job_name" "$build_number" 2>/dev/null) || nested_stages_json="[]"
    if [[ -z "$nested_stages_json" || "$nested_stages_json" == "null" ]]; then
        echo "[]"
        return 0
    fi

    local base_stages_json console_output stage_agent_map pipeline_scope_agent wfapi_stage_details_json
    base_stages_json=$(get_all_stages "$job_name" "$build_number" 2>/dev/null) || base_stages_json="[]"
    [[ -z "$base_stages_json" || "$base_stages_json" == "null" ]] && base_stages_json="[]"
    wfapi_stage_details_json="[]"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -n "$job_path" ]]; then
        local wfapi_response
        wfapi_response=$(jenkins_api "${job_path}/${build_number}/wfapi/describe" 2>/dev/null) || true
        if [[ -n "$wfapi_response" ]]; then
            wfapi_stage_details_json=$(echo "$wfapi_response" | jq -c '.stages // []' 2>/dev/null) || wfapi_stage_details_json="[]"
        fi
    fi
    console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || console_output=""
    stage_agent_map="{}"
    pipeline_scope_agent=""
    local branch_to_wrapper_json substage_to_branch_json
    branch_to_wrapper_json="{}"
    substage_to_branch_json="{}"
    local blue_nodes_json
    blue_nodes_json="[]"
    if [[ -n "$console_output" ]]; then
        stage_agent_map=$(_build_stage_agent_map "$console_output" 2>/dev/null) || stage_agent_map="{}"
        pipeline_scope_agent=$(_extract_pre_stage_agent_from_console "$console_output" 2>/dev/null) || pipeline_scope_agent=""
        blue_nodes_json=$(get_blue_ocean_nodes "$job_name" "$build_number" 2>/dev/null) || blue_nodes_json="[]"
        [[ -z "$blue_nodes_json" || "$blue_nodes_json" == "null" ]] && blue_nodes_json="[]"

        local mapping_wrapper_names mapping_wrapper_name
        mapping_wrapper_names=$(echo "$base_stages_json" | jq -r '.[].name // empty' 2>/dev/null) || mapping_wrapper_names=""
        while IFS= read -r mapping_wrapper_name; do
            [[ -z "$mapping_wrapper_name" ]] && continue

            local mapping_branch_names mapping_branch_substages mapping_branch_name
            mapping_branch_names=$(_detect_parallel_branches "$console_output" "$mapping_wrapper_name")
            [[ -z "$mapping_branch_names" || "$mapping_branch_names" == "[]" ]] && continue

            mapping_branch_substages=$(_detect_branch_substages "$console_output" "$mapping_wrapper_name")
            [[ -z "$mapping_branch_substages" || "$mapping_branch_substages" == "null" ]] && mapping_branch_substages="{}"
            if [[ "$blue_nodes_json" != "[]" && "$wfapi_stage_details_json" != "[]" ]]; then
                local mapping_blue_branch_substages
                mapping_blue_branch_substages=$(_detect_branch_substages_from_blue_ocean "$wfapi_stage_details_json" "$blue_nodes_json" "$mapping_wrapper_name" "$mapping_branch_names")
                if [[ -n "$mapping_blue_branch_substages" && "$mapping_blue_branch_substages" != "{}" && "$mapping_blue_branch_substages" != "null" ]]; then
                    mapping_branch_substages="$mapping_blue_branch_substages"
                fi
            fi

            while IFS= read -r mapping_branch_name; do
                [[ -z "$mapping_branch_name" ]] && continue
                branch_to_wrapper_json=$(echo "$branch_to_wrapper_json" | jq -c \
                    --arg branch "$mapping_branch_name" \
                    --arg wrapper "$mapping_wrapper_name" \
                    '. + {($branch): $wrapper}' 2>/dev/null) || branch_to_wrapper_json="$branch_to_wrapper_json"

                local mapping_substage_name
                while IFS= read -r mapping_substage_name; do
                    [[ -z "$mapping_substage_name" ]] && continue
                    substage_to_branch_json=$(echo "$substage_to_branch_json" | jq -c \
                        --arg substage "$mapping_substage_name" \
                        --arg branch "$mapping_branch_name" \
                        '. + {($substage): $branch}' 2>/dev/null) || substage_to_branch_json="$substage_to_branch_json"
                done <<< "$(echo "$mapping_branch_substages" | jq -r --arg branch "$mapping_branch_name" '.[$branch] // [] | .[]' 2>/dev/null)"
            done <<< "$(echo "$mapping_branch_names" | jq -r '.[]' 2>/dev/null)"
        done <<< "$mapping_wrapper_names"
    fi

    local result="$nested_stages_json"
    if [[ "$substage_to_branch_json" != "{}" ]]; then
        result=$(echo "$result" | jq -c \
            --argjson substage_to_branch "$substage_to_branch_json" \
            --argjson branch_to_wrapper "$branch_to_wrapper_json" '
            map(
                (.name // "") as $original_name
                | ($substage_to_branch[$original_name] // "") as $branch_name
                | if $branch_name != "" and ($original_name | contains("->") | not) then
                    . + {
                        name: ($branch_name + "->" + $original_name),
                        parallel_branch: (if (.parallel_branch // "") != "" then .parallel_branch else $branch_name end),
                        parent_branch_stage: (if (.parent_branch_stage // "") != "" then .parent_branch_stage else $branch_name end),
                        parallel_wrapper: (if (.parallel_wrapper // "") != "" then .parallel_wrapper else ($branch_to_wrapper[$branch_name] // "") end)
                    }
                  else
                    .
                  end
            )
        ' 2>/dev/null) || result="$nested_stages_json"
    fi
    local base_stage_names_json
    base_stage_names_json=$(echo "$base_stages_json" | jq -c '[.[].name]' 2>/dev/null) || base_stage_names_json="[]"
    local wrapper_lines
    wrapper_lines=$(echo "$base_stages_json" | jq -r '.[] | [.name, (.status // ""), (.startTimeMillis // 0), (.durationMillis // 0)] | @tsv' 2>/dev/null) || wrapper_lines=""

    local wrapper_name wrapper_status wrapper_start_ms wrapper_duration_ms
    while IFS=$'\t' read -r wrapper_name wrapper_status wrapper_start_ms wrapper_duration_ms; do
        [[ -z "$wrapper_name" ]] && continue
        [[ -z "$console_output" ]] && continue

        local branch_names
        branch_names=$(_detect_parallel_branches "$console_output" "$wrapper_name")
        [[ -z "$branch_names" || "$branch_names" == "[]" ]] && continue

        local active_branch_count
        active_branch_count=$(echo "$result" | jq -r --argjson branches "$branch_names" '
            [
                .[]
                | select((.status // "") == "IN_PROGRESS")
                | select(
                    (.name as $stage_name | any($branches[]; . == $stage_name))
                    or
                    ((.parent_branch_stage // "") as $branch_name | $branch_name != "" and any($branches[]; . == $branch_name))
                )
            ] | length
        ' 2>/dev/null) || active_branch_count=0
        local later_non_branch_started
        later_non_branch_started=$(echo "$base_stages_json" | jq -r \
            --arg wrapper "$wrapper_name" \
            --argjson branches "$branch_names" '
                ([.[] | .name] | index($wrapper)) as $wrapper_idx
                | if $wrapper_idx == null then
                    0
                  else
                    [.[$wrapper_idx + 1:][]?
                     | select(.name != $wrapper)
                     | .name as $stage_name
                     | select(any($branches[]; . == $stage_name) | not)
                     | select((.status // "NOT_EXECUTED") != "NOT_EXECUTED")
                    ] | length
                  end
            ' 2>/dev/null) || later_non_branch_started=0

        if [[ "$wrapper_status" != "IN_PROGRESS" && "$active_branch_count" -le 0 && "$later_non_branch_started" -gt 0 ]]; then
            continue
        fi

        local branch_name
        while IFS= read -r branch_name; do
            [[ -z "$branch_name" ]] && continue

            local branch_base_status
            branch_base_status=$(echo "$base_stages_json" | jq -r --arg n "$branch_name" '.[] | select(.name == $n) | .status // empty' 2>/dev/null | head -1) || branch_base_status=""
            local branch_base_duration branch_estimate_ms
            branch_base_duration=$(echo "$base_stages_json" | jq -r --arg n "$branch_name" '.[] | select(.name == $n) | .durationMillis // 0' 2>/dev/null | head -1) || branch_base_duration=0
            branch_estimate_ms=$(echo "$_FOLLOW_STAGE_ESTIMATES_JSON" | jq -r --arg n "$branch_name" '.[$n] // empty' 2>/dev/null) || branch_estimate_ms=""

            local active_substage_json
            active_substage_json=$(echo "$base_stages_json" | jq -c \
                --arg branch "$branch_name" \
                --argjson substage_to_branch "$substage_to_branch_json" '
                [.[] | select((.status // "") == "IN_PROGRESS") | select(($substage_to_branch[.name // ""] // "") == $branch)][0] // empty
            ' 2>/dev/null) || active_substage_json=""
            if [[ -n "$active_substage_json" && "$active_substage_json" != "null" ]]; then
                local active_substage_name active_substage_display active_substage_present active_substage_agent active_substage_start_ms active_substage_duration_ms
                active_substage_name=$(echo "$active_substage_json" | jq -r '.name // empty' 2>/dev/null) || active_substage_name=""
                active_substage_display="${branch_name}->${active_substage_name}"
                active_substage_present=$(echo "$result" | jq -r --arg n "$active_substage_display" 'any(.[]; .name == $n and (.status // "") == "IN_PROGRESS")' 2>/dev/null) || active_substage_present="false"
                if [[ "$active_substage_present" != "true" ]]; then
                    active_substage_agent=$(echo "$active_substage_json" | jq -r '.agent // .execNode // .node // empty' 2>/dev/null) || active_substage_agent=""
                    if [[ -z "$active_substage_agent" ]]; then
                        active_substage_agent=$(echo "$stage_agent_map" | jq -r --arg n "$active_substage_name" '.[$n] // empty' 2>/dev/null) || active_substage_agent=""
                    fi
                    if [[ -z "$active_substage_agent" && -n "$pipeline_scope_agent" ]]; then
                        active_substage_agent="$pipeline_scope_agent"
                    fi
                    active_substage_start_ms=$(echo "$active_substage_json" | jq -r '.startTimeMillis // 0' 2>/dev/null) || active_substage_start_ms=0
                    active_substage_duration_ms=$(echo "$active_substage_json" | jq -r '.durationMillis // 0' 2>/dev/null) || active_substage_duration_ms=0
                    result=$(echo "$result" | jq -c \
                        --arg name "$active_substage_display" \
                        --arg branch "$branch_name" \
                        --arg wrapper "$wrapper_name" \
                        --arg parent_branch_stage "$branch_name" \
                        --arg agent "$active_substage_agent" \
                        --argjson start_ms "${active_substage_start_ms:-0}" \
                        --argjson duration_ms "${active_substage_duration_ms:-0}" \
                        '. + [{
                            name: $name,
                            status: "IN_PROGRESS",
                            startTimeMillis: $start_ms,
                            durationMillis: $duration_ms,
                            agent: $agent,
                            parallel_branch: $branch,
                            parallel_wrapper: $wrapper,
                            parent_branch_stage: $parent_branch_stage
                        }]' 2>/dev/null) || true
                fi
                continue
            fi

            local stale_substage_json
            stale_substage_json=$(echo "$result" | jq -c \
                --arg branch "$branch_name" \
                --argjson estimates "$_FOLLOW_STAGE_ESTIMATES_JSON" '
                [
                    .[]
                    | select((.parent_branch_stage // .parallel_branch // "") == $branch)
                    | select((.name // "") | contains("->"))
                    | select((.status // "") == "SUCCESS")
                    | . as $stage
                    | ($stage.name // "") as $stage_name
                    | ($stage_name | split("->") | last) as $substage_name
                    | ($stage.durationMillis // 0) as $duration
                    | ($estimates[$stage_name] // $estimates[$substage_name] // 0) as $estimate
                    | select(
                        ($duration | tonumber? // 0) <= 1000
                        or (
                            ($estimate | tonumber? // 0) > 0
                            and ($duration | tonumber? // 0) < (($estimate | tonumber? // 0) / 10)
                        )
                    )
                ] | last // empty
            ' 2>/dev/null) || stale_substage_json=""
            if [[ -n "$stale_substage_json" && "$stale_substage_json" != "null" ]]; then
                local stale_substage_name stale_substage_agent stale_substage_leaf_name
                stale_substage_name=$(echo "$stale_substage_json" | jq -r '.name // empty' 2>/dev/null) || stale_substage_name=""
                stale_substage_leaf_name="${stale_substage_name##*->}"
                stale_substage_agent=$(echo "$stale_substage_json" | jq -r '.agent // .execNode // .node // empty' 2>/dev/null) || stale_substage_agent=""
                if [[ -n "$stale_substage_name" ]]; then
                    local mapped_stale_substage_agent
                    mapped_stale_substage_agent=$(echo "$stage_agent_map" | jq -r --arg n "$stale_substage_leaf_name" '.[$n] // empty' 2>/dev/null) || mapped_stale_substage_agent=""
                    if [[ -n "$mapped_stale_substage_agent" ]]; then
                        stale_substage_agent="$mapped_stale_substage_agent"
                    fi
                    if [[ -z "$stale_substage_agent" && -n "$pipeline_scope_agent" ]]; then
                        stale_substage_agent="$pipeline_scope_agent"
                    fi
                    result=$(echo "$result" | jq -c \
                        --arg name "$stale_substage_name" \
                        --arg branch "$branch_name" \
                        --arg wrapper "$wrapper_name" \
                        --arg agent "$stale_substage_agent" '
                        map(
                            if (.name // "") == $name then
                                . + {
                                    status: "IN_PROGRESS",
                                    durationMillis: 0,
                                    agent: (if (.agent // "") != "" then .agent else $agent end),
                                    parallel_branch: (if (.parallel_branch // "") != "" then .parallel_branch else $branch end),
                                    parallel_wrapper: (if (.parallel_wrapper // "") != "" then .parallel_wrapper else $wrapper end),
                                    parent_branch_stage: (if (.parent_branch_stage // "") != "" then .parent_branch_stage else $branch end)
                                }
                            else
                                .
                            end
                        )
                    ' 2>/dev/null) || true
                    continue
                fi
            fi

            local branch_present
            branch_present=$(echo "$result" | jq -r --arg n "$branch_name" '
                any(.[];
                    (.status // "") == "IN_PROGRESS"
                    and (
                        (.name == $n)
                        or ((.parent_branch_stage // "") == $n)
                    )
                )
            ' 2>/dev/null) || branch_present="false"
            if [[ "$branch_present" == "true" ]]; then
                continue
            fi

            local stale_terminal_branch=false
            if [[ "$branch_base_status" == "SUCCESS" && "$later_non_branch_started" -le 0 ]]; then
                if ! [[ "$branch_base_duration" =~ ^-?[0-9]+$ ]]; then
                    stale_terminal_branch=true
                elif [[ "$branch_base_duration" -le 1000 ]]; then
                    stale_terminal_branch=true
                elif [[ "$branch_estimate_ms" =~ ^[1-9][0-9]*$ ]] && [[ "$branch_base_duration" -lt $((branch_estimate_ms / 10)) ]]; then
                    stale_terminal_branch=true
                fi
            fi

            case "$branch_base_status" in
                SUCCESS|FAILED|UNSTABLE|ABORTED|NOT_BUILT)
                    if [[ "$stale_terminal_branch" == "true" ]]; then
                        :
                    else
                    continue
                    fi
                    ;;
            esac

            local branch_agent
            if [[ -n "$pipeline_scope_agent" ]]; then
                branch_agent="$pipeline_scope_agent"
            else
                branch_agent=$(echo "$stage_agent_map" | jq -r --arg n "$branch_name" '.[$n] // empty' 2>/dev/null) || branch_agent=""
            fi
            result=$(echo "$result" | jq -c \
                --arg name "$branch_name" \
                --arg wrapper "$wrapper_name" \
                --arg agent "$branch_agent" \
                --argjson start_ms "${wrapper_start_ms:-0}" \
                '. + [{
                    name: $name,
                    status: "IN_PROGRESS",
                    startTimeMillis: $start_ms,
                    durationMillis: 0,
                    agent: $agent,
                    parallel_branch: $name,
                    parallel_wrapper: $wrapper,
                    synthetic_parallel_branch: true
                }]' 2>/dev/null) || true
        done <<< "$(echo "$branch_names" | jq -r '.[]' 2>/dev/null)"
    done <<< "$wrapper_lines"

    echo "$result" | jq -c '.' 2>/dev/null || echo "[]"
}

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
    _PROGRESS_BAR_LINE_COUNT=0
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
            _clear_follow_line_progress
            echo ""
        fi
        bg_log_error "Build #${build_number} did not complete within ${MAX_BUILD_TIME}s timeout"
        return 1
    fi

    if [[ "$showed_progress" == "true" ]]; then
        _clear_follow_line_progress
    fi

    _status_line_for_build_json "$job_name" "$build_number" "$build_json" "$no_tests"
}
