# Checks whether status line follow mode should render interactive output.
# BUILDGIT_FORCE_TTY=1 is test-only and allows deterministic TTY-path tests.
_status_stdout_is_tty() {
    if [[ "${BUILDGIT_FORCE_NOT_TTY:-}" == "1" ]]; then
        return 1
    fi
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
        stage_agent_map=$(_build_stage_agent_map "$console_output" "$job_name" "$build_number" 2>/dev/null) || stage_agent_map="{}"
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
                NOT_EXECUTED)
                    # Branch skipped by a when{} gate: never synthesize it as running.
                    continue
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

