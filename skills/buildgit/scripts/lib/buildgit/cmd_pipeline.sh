_parse_pipeline_options() {
    PIPELINE_BUILD_NUMBER=""
    PIPELINE_BUILD_SET=false
    PIPELINE_JSON=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                PIPELINE_JSON=true
                shift
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
                _usage_error "Unknown option for pipeline command: $1"
                ;;
            *)
                if [[ "$PIPELINE_BUILD_SET" == "true" ]]; then
                    _usage_error "pipeline accepts at most one build number"
                fi
                PIPELINE_BUILD_NUMBER="$1"
                PIPELINE_BUILD_SET=true
                shift
                ;;
        esac
    done
}

_resolve_pipeline_build_number() {
    local job_name="$1"
    local requested_build="${2:-}"

    if [[ -n "$requested_build" && "$requested_build" != "0" ]]; then
        printf '%s\n' "$requested_build"
        return 0
    fi

    local build_number
    build_number=$(get_last_build_number "$job_name")
    build_number=$(printf '%s' "$build_number" | tr -d '\r\n[:space:]')
    if [[ ! "$build_number" =~ ^[0-9]+$ ]] || [[ "$build_number" == "0" ]]; then
        return 1
    fi

    printf '%s\n' "$build_number"
}

_fetch_pipeline_computers() {
    if declare -F _fetch_computers >/dev/null 2>&1; then
        _fetch_computers
        return 0
    fi

    jenkins_api "/computer/api/json?tree=computer[displayName,assignedLabels[name]]"
}

_build_node_label_map() {
    local computers_json="${1:-}"

    if [[ -z "$computers_json" ]]; then
        echo "{}"
        return 0
    fi

    printf '%s\n' "$computers_json" | jq -c '
        reduce (.computer[]? // empty) as $computer (
            {};
            . + {
                (($computer.displayName // "") | tostring): {
                    labels: [
                        $computer.assignedLabels[]?.name?
                        | select(type == "string" and length > 0)
                    ],
                    primaryLabel: (
                        [
                            $computer.assignedLabels[]?.name?
                            | select(type == "string" and length > 0)
                        ][0] // ""
                    )
                }
            }
        )
    ' 2>/dev/null || echo "{}"
}

_classify_pipeline_stages() {
    local stages_json="$1"
    local blue_nodes_json="$2"
    local stage_agent_map_json="$3"
    local node_label_map_json="$4"

    if [[ -z "$blue_nodes_json" || "$blue_nodes_json" == "[]" ]]; then
        jq -n \
            --argjson wf_stages "$stages_json" \
            --argjson agent_map "$stage_agent_map_json" \
            --argjson label_map "$node_label_map_json" '
            def resolved_label($agent):
                if $agent == "" then
                    ""
                else
                    ($label_map[$agent].primaryLabel // $agent)
                end;

            {
                parallelStructureAvailable: false,
                stages: [
                    $wf_stages[]?
                    | ($agent_map[.name] // "") as $agent
                    | {
                        name,
                        type: "sequential",
                        agent: $agent,
                        agentLabel: resolved_label($agent),
                        status: (.status // ""),
                        durationMillis: (.durationMillis // 0),
                        children: []
                    }
                ],
                graph: {
                    edges: [
                        range(0; (($wf_stages | length) - 1))
                        | {
                            from: ($wf_stages[.].name // ""),
                            to: ($wf_stages[. + 1].name // "")
                        }
                    ]
                }
            }
        ' 2>/dev/null || echo '{"parallelStructureAvailable":false,"stages":[],"graph":{"edges":[]}}'
        return 0
    fi

    jq -n \
        --argjson wf_stages "$stages_json" \
        --argjson blue_nodes "$blue_nodes_json" \
        --argjson agent_map "$stage_agent_map_json" \
        --argjson label_map "$node_label_map_json" '
        def node_by_id($id):
            first($blue_nodes[]? | select((.id // "" | tostring) == ($id | tostring)));
        def children_of($id):
            [ $blue_nodes[]? | select((.firstParent // "" | tostring) == ($id | tostring)) ];
        def stage_meta($name):
            first($wf_stages[]? | select((.name // "") == $name)) // {};
        def resolved_label($agent):
            if $agent == "" then
                ""
            else
                ($label_map[$agent].primaryLabel // $agent)
            end;
        def build_node($node):
            if ($node.type // "") == "PARALLEL" then
                {
                    name: ($node.name // ""),
                    type: "parallel",
                    branches: (children_of($node.id) | map(build_node(.)))
                }
            else
                ($agent_map[$node.name] // "") as $agent
                | {
                    name: ($node.name // ""),
                    type: "sequential",
                    agent: $agent,
                    agentLabel: resolved_label($agent),
                    status: (stage_meta($node.name).status // ""),
                    durationMillis: (stage_meta($node.name).durationMillis // 0),
                    children: (children_of($node.id) | map(build_node(.)))
                }
            end;

        {
            parallelStructureAvailable: true,
            stages: [
                $blue_nodes[]?
                | select(
                    ((.firstParent // "") == "")
                    or (node_by_id(.firstParent) == null)
                )
                | build_node(.)
            ],
            graph: {
                edges: [
                    $blue_nodes[]?
                    | select((.firstParent // "") != "")
                    | {
                        from: (node_by_id(.firstParent).name // ""),
                        to: (.name // "")
                    }
                    | select(.from != "" and .to != "")
                ]
            }
        }
    ' 2>/dev/null || echo '{"parallelStructureAvailable":true,"stages":[],"graph":{"edges":[]}}'
}

_enrich_pipeline_stages_with_tests() {
    local classified_json="$1"
    local stage_tests_map_json="$2"

    if [[ -z "$classified_json" ]]; then
        echo '{"parallelStructureAvailable":false,"stages":[],"graph":{"edges":[]}}'
        return 0
    fi

    if [[ -z "$stage_tests_map_json" || "$stage_tests_map_json" == "{}" ]]; then
        printf '%s\n' "$classified_json"
        return 0
    fi

    jq -n \
        --argjson classified "$classified_json" \
        --argjson stage_tests "$stage_tests_map_json" '
        def enrich($node):
            (if ($node.type // "") == "parallel" then
                $node + {
                    branches: [
                        ($node.branches // [])[]?
                        | enrich(.)
                    ]
                }
            else
                $node + {
                    children: [
                        ($node.children // [])[]?
                        | enrich(.)
                    ]
                }
            end) as $enriched
            | ($enriched.name // "") as $node_name
            | if ($stage_tests | has($node_name)) then
                $enriched + { testSuites: ($stage_tests[$node_name] // []) }
              else
                $enriched
              end;

        $classified + {
            stages: [
                ($classified.stages // [])[]?
                | enrich(.)
            ]
        }
    ' 2>/dev/null || printf '%s\n' "$classified_json"
}

_render_pipeline_node_human() {
    local node_json="$1"
    local prefix="${2:-}"
    local is_last="${3:-true}"
    local connector="├─"
    local next_prefix="${prefix}│  "
    local type label name child_count child_key

    if [[ "$is_last" == "true" ]]; then
        connector="└─"
        next_prefix="${prefix}   "
    fi

    type=$(printf '%s\n' "$node_json" | jq -r '.type // "sequential"')
    name=$(printf '%s\n' "$node_json" | jq -r '.name // "unknown"')

    if [[ "$type" == "parallel" ]]; then
        local suite_count_p
        suite_count_p=$(printf '%s\n' "$node_json" | jq -r '(.testSuites // []) | length' 2>/dev/null) || suite_count_p=0
        if [[ "$suite_count_p" -gt 0 ]]; then
            printf '%s%s %s -- parallel\n' "$prefix" "$connector" "$name"
            local total_tests_p cumulative_duration_p
            total_tests_p=$(printf '%s\n' "$node_json" | jq -r '[.testSuites[]?.tests // 0] | add // 0' 2>/dev/null) || total_tests_p=0
            cumulative_duration_p=$(printf '%s\n' "$node_json" | jq -r '[.testSuites[]?.durationMs // 0] | add // 0' 2>/dev/null) || cumulative_duration_p=0
            printf '%s%s suites, %s tests, %s cumulative\n' \
                "$next_prefix" \
                "$suite_count_p" \
                "$total_tests_p" \
                "$(format_stage_duration "$cumulative_duration_p")"
        else
            child_count=$(printf '%s\n' "$node_json" | jq -r '(.branches // []) | length')
            printf '%s%s %s -- parallel fork (%s branches)\n' "$prefix" "$connector" "$name" "$child_count"
        fi
        child_key="branches"
    else
        label=$(printf '%s\n' "$node_json" | jq -r '.agentLabel // empty')
        if [[ -n "$label" ]]; then
            printf '%s%s %s [%s] -- sequential\n' "$prefix" "$connector" "$name" "$label"
        else
            printf '%s%s %s -- sequential\n' "$prefix" "$connector" "$name"
        fi
        local suite_count total_tests cumulative_duration
        suite_count=$(printf '%s\n' "$node_json" | jq -r '(.testSuites // []) | length' 2>/dev/null) || suite_count=0
        if [[ "$suite_count" -gt 0 ]]; then
            total_tests=$(printf '%s\n' "$node_json" | jq -r '[.testSuites[]?.tests // 0] | add // 0' 2>/dev/null) || total_tests=0
            cumulative_duration=$(printf '%s\n' "$node_json" | jq -r '[.testSuites[]?.durationMs // 0] | add // 0' 2>/dev/null) || cumulative_duration=0
            printf '%s%s suites, %s tests, %s cumulative\n' \
                "$next_prefix" \
                "$suite_count" \
                "$total_tests" \
                "$(format_stage_duration "$cumulative_duration")"
        fi
        child_key="children"
    fi

    local child_count_value child_index=0 child_json
    child_count_value=$(printf '%s\n' "$node_json" | jq -r --arg key "$child_key" '.[$key] | length')
    while IFS= read -r child_json; do
        [[ -n "$child_json" ]] || continue
        child_index=$((child_index + 1))
        if [[ "$child_index" -eq "$child_count_value" ]]; then
            _render_pipeline_node_human "$child_json" "$next_prefix" "true"
        else
            _render_pipeline_node_human "$child_json" "$next_prefix" "false"
        fi
    done < <(printf '%s\n' "$node_json" | jq -c --arg key "$child_key" '.[$key][]?')
}

_render_pipeline_human() {
    local pipeline_json="$1"

    local build_number
    build_number=$(printf '%s\n' "$pipeline_json" | jq -r '.build.number // 0')

    printf 'Build #%s pipeline:\n' "$build_number"
    if [[ "$(printf '%s\n' "$pipeline_json" | jq -r '.parallelStructureAvailable')" != "true" ]]; then
        echo "(parallel structure unavailable)"
    fi

    local root_count root_index=0 node_json
    root_count=$(printf '%s\n' "$pipeline_json" | jq -r '.stages | length')
    if [[ "$root_count" -eq 0 ]]; then
        echo "No stages found"
        return 0
    fi

    while IFS= read -r node_json; do
        [[ -n "$node_json" ]] || continue
        root_index=$((root_index + 1))
        if [[ "$root_index" -eq "$root_count" ]]; then
            _render_pipeline_node_human "$node_json" "" "true"
        else
            _render_pipeline_node_human "$node_json" "" "false"
        fi
    done < <(printf '%s\n' "$pipeline_json" | jq -c '.stages[]?')
}

_render_pipeline_json() {
    local pipeline_json="$1"
    printf '%s\n' "$pipeline_json" | jq '.'
}

_render_pipeline_for_build() {
    local job_name="$1"
    local build_number="$2"

    local stages_json blue_nodes_json computers_json node_label_map_json
    local console_output stage_agent_map_json classified_json stage_tests_map_json

    stages_json=$(get_all_stages "$job_name" "$build_number")
    blue_nodes_json=$(get_blue_ocean_nodes "$job_name" "$build_number")
    computers_json=$(_fetch_pipeline_computers 2>/dev/null) || computers_json=""
    node_label_map_json=$(_build_node_label_map "$computers_json")
    console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || console_output=""
    stage_agent_map_json=$(_build_stage_agent_map "$console_output")
    classified_json=$(_classify_pipeline_stages "$stages_json" "$blue_nodes_json" "$stage_agent_map_json" "$node_label_map_json")
    stage_tests_map_json=$(fetch_stage_test_suites "$job_name" "$build_number")
    classified_json=$(_enrich_pipeline_stages_with_tests "$classified_json" "$stage_tests_map_json")

    jq -n \
        --argjson build_number "$build_number" \
        --argjson classified "$classified_json" '
        {
            build: {
                number: $build_number
            },
            parallelStructureAvailable: ($classified.parallelStructureAvailable // false),
            stages: ($classified.stages // []),
            graph: ($classified.graph // {"edges":[]})
        }
    '
}

cmd_pipeline() {
    _parse_pipeline_options "$@"

    if ! _validate_jenkins_setup "inspect Jenkins pipeline structure" "status"; then
        return 1
    fi

    local resolved_build pipeline_json
    if ! resolved_build=$(_resolve_pipeline_build_number "$_VALIDATED_JOB_NAME" "$PIPELINE_BUILD_NUMBER"); then
        bg_log_error "Cannot inspect Jenkins pipeline structure - could not resolve build number"
        return 1
    fi

    pipeline_json=$(_render_pipeline_for_build "$_VALIDATED_JOB_NAME" "$resolved_build") || return 1

    if [[ "$PIPELINE_JSON" == "true" ]]; then
        _render_pipeline_json "$pipeline_json"
    else
        _render_pipeline_human "$pipeline_json"
    fi
}
