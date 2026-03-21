_parse_timing_options() {
    TIMING_BUILD_NUMBER=""
    TIMING_BUILD_SET=false
    TIMING_JSON=false
    TIMING_COUNT=1
    TIMING_TESTS=false
    TIMING_BY_STAGE=false
    TIMING_COMPARE=false
    TIMING_COMPARE_A=""
    TIMING_COMPARE_B=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                TIMING_JSON=true
                shift
                ;;
            --tests)
                TIMING_TESTS=true
                shift
                ;;
            --by-stage)
                TIMING_BY_STAGE=true
                shift
                ;;
            --compare)
                TIMING_COMPARE=true
                if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                    _usage_error "--compare requires two build numbers"
                fi
                if ! [[ "${2}" =~ ^(0|-0|[1-9][0-9]*|-[1-9][0-9]*)$ ]]; then
                    _usage_error "--compare build numbers must be absolute or relative integers"
                fi
                if ! [[ "${3}" =~ ^(0|-0|[1-9][0-9]*|-[1-9][0-9]*)$ ]]; then
                    _usage_error "--compare build numbers must be absolute or relative integers"
                fi
                TIMING_COMPARE_A="$2"
                TIMING_COMPARE_B="$3"
                shift 3
                ;;
            -n)
                if [[ -z "${2:-}" ]]; then
                    _usage_error "-n requires a value"
                fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    _usage_error "-n value must be a positive integer"
                fi
                TIMING_COUNT="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE_MODE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                _usage_error "Unknown option for timing command: $1"
                ;;
            *)
                if [[ "$TIMING_COMPARE" == "true" ]]; then
                    _usage_error "Cannot combine --compare with a positional build number"
                fi
                if [[ "$TIMING_BUILD_SET" == "true" ]]; then
                    _usage_error "timing accepts at most one build number"
                fi
                TIMING_BUILD_NUMBER="$1"
                TIMING_BUILD_SET=true
                shift
                ;;
        esac
    done
}

_resolve_timing_build_number() {
    local job_name="$1"
    local requested_build="${2:-}"

    if [[ "$requested_build" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$requested_build"
        return 0
    fi

    if [[ "$requested_build" =~ ^-[1-9][0-9]*$ ]]; then
        local relative_offset="${requested_build#-}"
        local latest_build_number
        latest_build_number=$(get_last_build_number "$job_name")
        if [[ ! "$latest_build_number" =~ ^[0-9]+$ ]] || [[ "$latest_build_number" == "0" ]]; then
            return 1
        fi

        local resolved_build_number=$((latest_build_number - relative_offset))
        if [[ "$resolved_build_number" -lt 1 ]]; then
            return 1
        fi

        printf '%s\n' "$resolved_build_number"
        return 0
    fi

    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        return 1
    fi

    local build_number
    build_number=$(jenkins_api "${job_path}/lastSuccessfulBuild/buildNumber" 2>/dev/null) || build_number=""
    build_number=$(printf '%s' "$build_number" | tr -d '\r\n[:space:]')

    if [[ ! "$build_number" =~ ^[0-9]+$ ]] || [[ "$build_number" == "0" ]]; then
        return 1
    fi

    printf '%s\n' "$build_number"
    return 0
}

_fetch_test_report_timing() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo ""
        return 1
    fi

    local response http_code body
    response=$(jenkins_api_with_status "${job_path}/${build_number}/testReport/api/json?tree=duration,suites[name,duration,cases[className,name,duration,status]]" || true)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200)
            printf '%s\n' "$body"
            return 0
            ;;
        404)
            echo ""
            return 0
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

_build_timing_test_suites() {
    local test_report_json="${1:-}"

    if [[ -z "$test_report_json" ]]; then
        echo "[]"
        return 0
    fi

    printf '%s\n' "$test_report_json" | jq -c '
        [
            (.suites // [])[]?
            | {
                name: (.name // "unknown"),
                durationMillis: (
                    ((.duration // 0) | tonumber? // 0) * 1000 | floor
                ),
                testCount: ((.cases // []) | length)
            }
            | select(.testCount > 0)
        ]
        | sort_by(.durationMillis)
        | reverse
    ' 2>/dev/null || echo "[]"
}

_build_timing_stages_json() {
    local stages_json="$1"
    local stage_agent_map_json="$2"
    local test_suites_json="${3:-[]}"
    local node_label_map_json="${4:-"{}"}"

    printf '%s\n' "$stages_json" | jq -c \
        --argjson agent_map "$stage_agent_map_json" \
        --argjson test_suites "$test_suites_json" \
        --argjson label_map "$node_label_map_json" '
        def resolve_label($agent):
            if $agent == "" then ""
            else ($label_map[$agent].primaryLabel // $agent)
            end;
        [
            .[]?
            | ($agent_map[.name] // "") as $agent
            | . + {
                agent: resolve_label($agent)
            }
        ]
    ' 2>/dev/null || echo "[]"
}

_build_parallel_groups() {
    local stages_json="$1"
    local blue_nodes_json="$2"

    jq -n \
        --argjson stages "$stages_json" \
        --argjson nodes "$blue_nodes_json" '
        def node_by_name($name):
            first($nodes[]? | select((.name // "") == $name));
        def node_name_by_id($id):
            first($nodes[]? | select((.id // "" | tostring) == ($id | tostring))) | (.name // "");
        def raw_parallel_group($stage):
            (node_by_name($stage.name)) as $node
            | if $node == null or ($node.firstParent // "") == "" then
                ""
              else
                node_name_by_id($node.firstParent)
              end;
        def is_parallel_group_name($name):
            if $name == "" then
                false
            else
                ([$stages[]? | select(raw_parallel_group(.) == $name)] | length) > 1
            end;

        ($stages | map(
            . + {
                parallelGroup: (
                    (raw_parallel_group(.)) as $group
                    | if is_parallel_group_name($group) then $group else null end
                )
            }
        )) as $enriched
        | {
            stages: $enriched,
            parallelGroups: (
                $enriched
                | map(select(.parallelGroup != null))
                | group_by(.parallelGroup)
                | map({
                    name: .[0].parallelGroup,
                    wallDurationMillis: (map(.durationMillis // 0) | max // 0),
                    bottleneck: (max_by(.durationMillis // 0) | .name),
                    stages: map({
                        name,
                        status,
                        durationMillis,
                        agent
                    })
                })
            )
        }
    ' 2>/dev/null || echo '{"stages":[],"parallelGroups":[]}'
}

_get_parallel_group_for_stage() {
    local stage_name="$1"
    local groups_json="$2"

    printf '%s\n' "$groups_json" | jq -r \
        --arg stage_name "$stage_name" '
        first(
            .parallelGroups[]?
            | select(any(.stages[]?; (.name // "") == $stage_name))
            | .name
        ) // ""
    ' 2>/dev/null || echo ""
}

_identify_bottleneck() {
    local group_json="$1"

    printf '%s\n' "$group_json" | jq -r '.bottleneck // ""' 2>/dev/null || echo ""
}

_format_timing_stage_line() {
    local stage_json="$1"
    local slowest_stage="${2:-}"
    local include_tests="${3:-false}"

    local stage_name duration_ms agent file_count test_count suffix
    stage_name=$(printf '%s\n' "$stage_json" | jq -r '.name // "unknown"')
    duration_ms=$(printf '%s\n' "$stage_json" | jq -r '.durationMillis // 0')
    agent=$(printf '%s\n' "$stage_json" | jq -r '.agent // empty')
    file_count=$(printf '%s\n' "$stage_json" | jq -r '.fileCount // 0')
    test_count=$(printf '%s\n' "$stage_json" | jq -r '.testCount // 0')
    suffix=""

    if [[ -n "$agent" ]]; then
        suffix="  ${agent}"
    fi

    if [[ "$include_tests" == "true" && ( "$file_count" -gt 0 || "$test_count" -gt 0 ) ]]; then
        suffix="${suffix}  (${file_count} files, ${test_count} tests)"
    fi

    if [[ -n "$slowest_stage" && "$stage_name" == "$slowest_stage" ]]; then
        suffix="${suffix}  <- slowest"
    fi

    printf '  %s  %s%s\n' "$stage_name" "$(format_stage_duration "$duration_ms")" "$suffix"
}

_render_timing_human() {
    local timing_json="$1"
    local include_tests="${2:-false}"

    local build_number total_duration sequential_count group_count
    build_number=$(printf '%s\n' "$timing_json" | jq -r '.build.number // 0')
    total_duration=$(printf '%s\n' "$timing_json" | jq -r '.build.totalDurationMillis // 0')
    sequential_count=$(printf '%s\n' "$timing_json" | jq -r '[.stages[]? | select(.parallelGroup == null)] | length')
    group_count=$(printf '%s\n' "$timing_json" | jq -r '.parallelGroups | length')

    printf 'Build #%s - total %s\n' "$build_number" "$(format_duration "$total_duration")"

    if [[ "$sequential_count" -gt 0 ]]; then
        echo "Sequential stages:"
        while IFS= read -r stage_json; do
            [[ -n "$stage_json" ]] || continue
            _format_timing_stage_line "$stage_json" "" "$include_tests"
        done < <(printf '%s\n' "$timing_json" | jq -c '.stages[]? | select(.parallelGroup == null)')
    fi

    if [[ "$group_count" -gt 0 ]]; then
        while IFS= read -r group_json; do
            [[ -n "$group_json" ]] || continue
            local group_name wall_duration bottleneck
            group_name=$(printf '%s\n' "$group_json" | jq -r '.name // "Parallel"')
            wall_duration=$(printf '%s\n' "$group_json" | jq -r '.wallDurationMillis // 0')
            bottleneck=$(_identify_bottleneck "$group_json")
            printf 'Parallel group: %s (wall %s, bottleneck: %s)\n' \
                "$group_name" "$(format_stage_duration "$wall_duration")" "$bottleneck"
            while IFS= read -r stage_json; do
                [[ -n "$stage_json" ]] || continue
                _format_timing_stage_line "$stage_json" "$bottleneck" "$include_tests"
            done < <(printf '%s\n' "$timing_json" | jq -c --arg group_name "$group_name" '
                .stages[]? | select((.parallelGroup // "") == $group_name)
            ')
        done < <(printf '%s\n' "$timing_json" | jq -c '.parallelGroups[]?')
    fi

    if [[ "$include_tests" == "true" ]]; then
        local test_suite_count
        test_suite_count=$(printf '%s\n' "$timing_json" | jq -r '.testSuites | length')
        if [[ "$test_suite_count" -gt 0 ]]; then
            echo "Test suite timing (top 10 slowest):"
            printf '%s\n' "$timing_json" | jq -c '.testSuites[:10][]?' | while IFS= read -r suite_json; do
                local suite_name suite_duration suite_tests
                suite_name=$(printf '%s\n' "$suite_json" | jq -r '.name // "unknown"')
                suite_duration=$(printf '%s\n' "$suite_json" | jq -r '.durationMillis // 0')
                suite_tests=$(printf '%s\n' "$suite_json" | jq -r '.testCount // 0')
                printf '  %s  %s  (%s tests)\n' "$suite_name" "$(format_stage_duration "$suite_duration")" "$suite_tests"
            done
        fi
    fi
}

_render_timing_json() {
    local timing_json="$1"
    printf '%s\n' "$timing_json" | jq '.'
}

_format_timing_value() {
    local duration_ms="${1:-0}"

    if [[ "$duration_ms" -eq 0 ]]; then
        printf '0s\n'
        return 0
    fi

    format_stage_duration "$duration_ms"
}

_format_timing_delta() {
    local duration_ms="${1:-0}"
    local sign=""
    local abs_duration="$duration_ms"

    if [[ "$duration_ms" -eq 0 ]]; then
        printf '0s\n'
        return 0
    fi

    if [[ "$duration_ms" -lt 0 ]]; then
        sign="-"
        abs_duration=$(( -duration_ms ))
    else
        sign="+"
    fi

    printf '%s%s\n' "$sign" "$(_format_timing_value "$abs_duration")"
}

_timing_value_for_entry() {
    local timing_json="$1"
    local entry_name="$2"

    printf '%s\n' "$timing_json" | jq -r --arg entry_name "$entry_name" '
        first(
            .parallelGroups[]?
            | select((.name // "") == $entry_name)
            | .wallDurationMillis
        ) // first(
            .stages[]?
            | select((.name // "") == $entry_name)
            | .durationMillis
        ) // 0
    ' 2>/dev/null || echo "0"
}

# Returns entry names in hierarchical order: sequential stages at top level,
# parallel groups followed by their member stages.
# Also outputs a second field (tab-separated) indicating depth: 0=top, 1=child.
_collect_timing_entry_names() {
    local timings_json="$1"

    printf '%s\n' "$timings_json" | jq -r '
        # Collect all unique sequential stage names, parallel group names,
        # and parallel member names across all builds
        reduce .[]? as $timing (
            {seq: [], groups: [], members: {}};

            # Sequential stages (parallelGroup == null)
            reduce ($timing.stages[]? | select(.parallelGroup == null) | (.name // "")) as $name (
                .;
                if $name == "" or (.seq | index($name)) then . else .seq += [$name] end
            )
            # Parallel groups and their member stages
            | reduce ($timing.parallelGroups[]?) as $group (
                .;
                ($group.name // "") as $gname
                | if $gname == "" then .
                  else
                    (if .groups | index($gname) then . else .groups += [$gname] end)
                    | reduce ($group.stages[]? | (.name // "")) as $mname (
                        .;
                        if $mname == "" then .
                        else .members[$gname] = ((.members[$gname] // []) + (if (.members[$gname] // []) | index($mname) then [] else [$mname] end))
                        end
                    )
                  end
            )
        )
        # Output in hierarchical order: for each entry, emit name\tdepth
        | .seq as $seq | .groups as $groups | .members as $members
        | [
            ($seq[]? | . as $name
                | if ($groups | index($name)) then
                    # This sequential name is also a parallel group — emit group + members instead
                    empty
                  else
                    "\($name)\t0"
                  end
            ),
            ($groups[]? | . as $gname |
                "\($gname)\t0",
                (($members[$gname] // [])[]? | "\(.)\t1")
            )
          ]
        | .[]
    ' 2>/dev/null
}

_render_timing_compare_human() {
    local timing_a_json="$1"
    local timing_b_json="$2"
    local timings_json
    timings_json=$(jq -n --argjson a "$timing_a_json" --argjson b "$timing_b_json" '[$a, $b]')

    local build_a build_b total_a total_b total_delta
    build_a=$(printf '%s\n' "$timing_a_json" | jq -r '.build.number // 0')
    build_b=$(printf '%s\n' "$timing_b_json" | jq -r '.build.number // 0')
    total_a=$(printf '%s\n' "$timing_a_json" | jq -r '.build.totalDurationMillis // 0')
    total_b=$(printf '%s\n' "$timing_b_json" | jq -r '.build.totalDurationMillis // 0')
    total_delta=$((total_b - total_a))

    printf 'Timing comparison: Build #%s vs #%s\n' "$build_a" "$build_b"
    printf '%-22s %10s %10s %10s\n' "" "#${build_a}" "#${build_b}" "Delta"
    printf '%-22s %10s %10s %10s\n' \
        "Total" \
        "$(format_duration "$total_a")" \
        "$(format_duration "$total_b")" \
        "$(_format_timing_delta "$total_delta")"

    local entry_line entry_name entry_depth entry_a entry_b entry_delta
    while IFS=$'\t' read -r entry_name entry_depth; do
        [[ -n "$entry_name" ]] || continue
        entry_a=$(_timing_value_for_entry "$timing_a_json" "$entry_name")
        entry_b=$(_timing_value_for_entry "$timing_b_json" "$entry_name")
        entry_delta=$((entry_b - entry_a))
        if [[ "${entry_depth:-0}" == "1" ]]; then
            printf '    %-18s %10s %10s %10s\n' \
                "$entry_name" \
                "$(_format_timing_value "$entry_a")" \
                "$(_format_timing_value "$entry_b")" \
                "$(_format_timing_delta "$entry_delta")"
        else
            printf '  %-20s %10s %10s %10s\n' \
                "$entry_name" \
                "$(_format_timing_value "$entry_a")" \
                "$(_format_timing_value "$entry_b")" \
                "$(_format_timing_delta "$entry_delta")"
        fi
    done < <(_collect_timing_entry_names "$timings_json")
}

_render_timing_compare_json() {
    local timing_a_json="$1"
    local timing_b_json="$2"

    jq -n --argjson a "$timing_a_json" --argjson b "$timing_b_json" '
        def stage_map($timing):
            (
                [
                    ($timing.stages[]? | {
                        key: (.name // ""),
                        value: (.durationMillis // 0)
                    }),
                    ($timing.parallelGroups[]? | {
                        key: (.name // ""),
                        value: (.wallDurationMillis // 0)
                    })
                ]
                | flatten
                | map(select(.key != ""))
                | from_entries
            );

        (stage_map($a)) as $map_a
        | (stage_map($b)) as $map_b
        | (($map_a + $map_b) | keys_unsorted) as $stage_names
        | {
            builds: [$a, $b],
            deltas: {
                total: (($b.build.totalDurationMillis // 0) - ($a.build.totalDurationMillis // 0)),
                stages: (
                    reduce $stage_names[] as $stage_name (
                        {};
                        . + {
                            ($stage_name): (($map_b[$stage_name] // 0) - ($map_a[$stage_name] // 0))
                        }
                    )
                )
            }
        }
    '
}

_render_timing_multi_table_human() {
    local builds_array_json="$1"
    local entry_names=()
    local entry_name entry_depth

    while IFS=$'\t' read -r entry_name entry_depth; do
        [[ -n "$entry_name" ]] || continue
        entry_names+=("$entry_name")
    done < <(_collect_timing_entry_names "$builds_array_json")

    printf '%-8s %-10s' "Build" "Total"
    local header_name
    for header_name in "${entry_names[@]}"; do
        printf ' %-12s' "${header_name:0:12}"
    done
    printf '\n'

    local build_json build_number total_duration value
    while IFS= read -r build_json; do
        [[ -n "$build_json" ]] || continue
        build_number=$(printf '%s\n' "$build_json" | jq -r '.build.number // 0')
        total_duration=$(printf '%s\n' "$build_json" | jq -r '.build.totalDurationMillis // 0')
        printf '%-8s %-10s' "#${build_number}" "$(format_duration "$total_duration")"
        for entry_name in "${entry_names[@]}"; do
            value=$(_timing_value_for_entry "$build_json" "$entry_name")
            printf ' %-12s' "$(_format_timing_value "$value")"
        done
        printf '\n'
    done < <(printf '%s\n' "$builds_array_json" | jq -c '.[]?')
}

_render_timing_by_stage_human() {
    local timing_json="$1"
    local stage_tests_map_json="$2"

    _render_timing_human "$timing_json" "false"

    local stage_count
    stage_count=$(printf '%s\n' "$stage_tests_map_json" | jq -r 'keys | length' 2>/dev/null) || stage_count=0
    if [[ "$stage_count" -eq 0 ]]; then
        return 0
    fi

    echo "Test suite timing by stage:"
    while IFS= read -r stage_name; do
        [[ -n "$stage_name" ]] || continue

        local stage_meta stage_duration stage_agent
        stage_meta=$(printf '%s\n' "$timing_json" | jq -c --arg stage_name "$stage_name" '
            (
                first(.stages[]? | select((.name // "") == $stage_name))
                | {
                    durationMillis: (.durationMillis // 0),
                    agent: (.agent // "")
                }
            ) // (
                first(.parallelGroups[]? | select((.name // "") == $stage_name))
                | {
                    durationMillis: (.wallDurationMillis // 0),
                    agent: ""
                }
            ) // {
                durationMillis: 0,
                agent: ""
            }
        ' 2>/dev/null) || stage_meta='{"durationMillis":0,"agent":""}'
        stage_duration=$(printf '%s\n' "$stage_meta" | jq -r '.durationMillis // 0' 2>/dev/null) || stage_duration=0
        stage_agent=$(printf '%s\n' "$stage_meta" | jq -r '.agent // empty' 2>/dev/null) || stage_agent=""

        if [[ -n "$stage_agent" ]]; then
            printf '  %s (wall %s, %s):\n' "$stage_name" "$(format_stage_duration "$stage_duration")" "$stage_agent"
        else
            printf '  %s (wall %s):\n' "$stage_name" "$(format_stage_duration "$stage_duration")"
        fi

        while IFS= read -r suite_json; do
            [[ -n "$suite_json" ]] || continue
            local suite_name suite_duration suite_tests
            suite_name=$(printf '%s\n' "$suite_json" | jq -r '.name // "unknown"' 2>/dev/null) || suite_name="unknown"
            suite_duration=$(printf '%s\n' "$suite_json" | jq -r '.durationMs // 0' 2>/dev/null) || suite_duration=0
            suite_tests=$(printf '%s\n' "$suite_json" | jq -r '.tests // 0' 2>/dev/null) || suite_tests=0
            printf '    %s  %s  (%s tests)\n' "$suite_name" "$(format_stage_duration "$suite_duration")" "$suite_tests"
        done < <(printf '%s\n' "$stage_tests_map_json" | jq -c --arg stage_name "$stage_name" '.[$stage_name][]?' 2>/dev/null)
    done < <(printf '%s\n' "$timing_json" | jq -r --argjson tests_by_stage "$stage_tests_map_json" '
        .stages[]?
        | (.name // "") as $stage_name
        | select($stage_name != "" and ($tests_by_stage | has($stage_name)))
        | $stage_name
    ' 2>/dev/null)
}

_build_timing_for_build() {
    local job_name="$1"
    local build_number="$2"

    local build_info_json total_duration stages_json blue_nodes_json console_output
    local stage_agent_map_json node_label_map_json computers_json
    local test_report_json test_suites_json grouped_json timing_json
    local stage_tests_map_json

    build_info_json=$(get_build_info "$job_name" "$build_number")
    total_duration=$(printf '%s\n' "$build_info_json" | jq -r '.duration // 0' 2>/dev/null) || total_duration=0
    stages_json=$(get_all_stages "$job_name" "$build_number")
    blue_nodes_json=$(get_blue_ocean_nodes "$job_name" "$build_number")
    console_output=$(get_console_output "$job_name" "$build_number")
    stage_agent_map_json=$(_build_stage_agent_map "$console_output")
    computers_json=""
    if declare -F _fetch_pipeline_computers >/dev/null 2>&1; then
        computers_json=$(_fetch_pipeline_computers 2>/dev/null) || computers_json=""
    fi
    node_label_map_json="{}"
    if declare -F _build_node_label_map >/dev/null 2>&1; then
        node_label_map_json=$(_build_node_label_map "$computers_json")
    fi

    test_report_json=""
    if [[ "$TIMING_TESTS" == "true" || "$TIMING_JSON" == "true" ]]; then
        test_report_json=$(_fetch_test_report_timing "$job_name" "$build_number" 2>/dev/null) || test_report_json=""
    fi
    test_suites_json=$(_build_timing_test_suites "$test_report_json")
    stages_json=$(_build_timing_stages_json "$stages_json" "$stage_agent_map_json" "$test_suites_json" "$node_label_map_json")
    grouped_json=$(_build_parallel_groups "$stages_json" "$blue_nodes_json")
    stage_tests_map_json="{}"
    if [[ "$TIMING_BY_STAGE" == "true" && "$TIMING_TESTS" == "true" ]]; then
        stage_tests_map_json=$(fetch_stage_test_suites "$job_name" "$build_number")
    fi

    timing_json=$(jq -n \
        --argjson build_number "$build_number" \
        --argjson total_duration "$total_duration" \
        --argjson stages "$(printf '%s\n' "$grouped_json" | jq '.stages // []')" \
        --argjson parallel_groups "$(printf '%s\n' "$grouped_json" | jq '.parallelGroups // []')" \
        --argjson test_suites "$test_suites_json" \
        --argjson tests_by_stage "$stage_tests_map_json" \
        --arg timing_by_stage "$TIMING_BY_STAGE" '
        {
            build: {
                number: $build_number,
                totalDurationMillis: $total_duration
            },
            stages: $stages,
            parallelGroups: $parallel_groups,
            testSuites: $test_suites
        }
        | if $timing_by_stage == "true" then . + {testsByStage: $tests_by_stage} else . end
    ')

    printf '%s\n' "$timing_json"
}

_render_single_timing_human() {
    local timing_json="$1"
    local stage_tests_map_json

    stage_tests_map_json=$(printf '%s\n' "$timing_json" | jq -c '.testsByStage // {}' 2>/dev/null) || stage_tests_map_json="{}"
    if [[ "$TIMING_BY_STAGE" == "true" && "$TIMING_TESTS" == "true" ]]; then
        _render_timing_by_stage_human "$timing_json" "$stage_tests_map_json"
    else
        _render_timing_human "$timing_json" "$TIMING_TESTS"
    fi
}

cmd_timing() {
    _parse_timing_options "$@"

    if ! _validate_jenkins_setup "inspect Jenkins build timing" "status"; then
        return 1
    fi

    if [[ "$TIMING_COMPARE" == "true" ]]; then
        local resolved_a resolved_b timing_a_json timing_b_json
        if ! resolved_a=$(_resolve_timing_build_number "$_VALIDATED_JOB_NAME" "$TIMING_COMPARE_A"); then
            bg_log_error "Cannot inspect Jenkins build timing - could not resolve compare build number '${TIMING_COMPARE_A}'"
            return 1
        fi
        if ! resolved_b=$(_resolve_timing_build_number "$_VALIDATED_JOB_NAME" "$TIMING_COMPARE_B"); then
            bg_log_error "Cannot inspect Jenkins build timing - could not resolve compare build number '${TIMING_COMPARE_B}'"
            return 1
        fi

        timing_a_json=$(_build_timing_for_build "$_VALIDATED_JOB_NAME" "$resolved_a") || return 1
        timing_b_json=$(_build_timing_for_build "$_VALIDATED_JOB_NAME" "$resolved_b") || return 1

        if [[ "$TIMING_JSON" == "true" ]]; then
            _render_timing_compare_json "$timing_a_json" "$timing_b_json" | jq '.'
        else
            _render_timing_compare_human "$timing_a_json" "$timing_b_json"
        fi
        return 0
    fi

    local resolved_build
    if ! resolved_build=$(_resolve_timing_build_number "$_VALIDATED_JOB_NAME" "$TIMING_BUILD_NUMBER"); then
        bg_log_error "Cannot inspect Jenkins build timing - could not resolve build number"
        return 1
    fi

    local start_build end_build
    end_build="$resolved_build"
    start_build=$((end_build - TIMING_COUNT + 1))
    if [[ "$start_build" -lt 1 ]]; then
        start_build=1
    fi

    local rendered_json="[]"
    local latest_timing_json=""
    local build_number
    for ((build_number = start_build; build_number <= end_build; build_number++)); do
        local build_render
        build_render=$(_build_timing_for_build "$_VALIDATED_JOB_NAME" "$build_number") || return 1
        rendered_json=$(printf '%s\n' "$rendered_json" | jq \
            --argjson build_render "$build_render" '. + [$build_render]')
        latest_timing_json="$build_render"
    done

    if [[ "$TIMING_JSON" == "true" ]]; then
        if [[ "$TIMING_COUNT" -eq 1 ]]; then
            printf '%s\n' "$rendered_json" | jq '.[0]'
        else
            printf '%s\n' "$rendered_json" | jq '.'
        fi
        return 0
    fi

    if [[ "$TIMING_COUNT" -gt 1 ]]; then
        _render_timing_multi_table_human "$rendered_json"
        if [[ "$TIMING_TESTS" == "true" ]]; then
            echo ""
            _render_single_timing_human "$latest_timing_json"
        fi
        return 0
    fi

    _render_single_timing_human "$latest_timing_json"
}
