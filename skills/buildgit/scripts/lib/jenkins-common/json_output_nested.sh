# =============================================================================
# Nested/Downstream Stage Display Functions
# =============================================================================
# Spec: nested-jobs-display-spec.md

# Extract agent name from build console output
# Usage: _extract_agent_name "$console_output"
# Returns: agent name string, or empty
_extract_agent_name() {
    local console_output="$1"
    _extract_running_agent_from_console "$console_output" || true
}

# Extract a pipeline-scope agent from console output when Jenkins allocates the
# node before the first named stage.
# Usage: _extract_pre_stage_agent_from_console "$console_output"
# Returns: agent name string, or empty if the first stage starts before any
#          "Running on" line appears.
_extract_pre_stage_agent_from_console() {
    local console_output="$1"
    local stripped_console

    stripped_console=$(printf "%s\n" "$console_output" | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g')

    printf "%s\n" "$stripped_console" | awk '
        /^\[Pipeline\] \{ \(.+\)$/ { exit }
        /Running on[[:space:]]+.+[[:space:]]+in[[:space:]]+\// {
            agent_name = $0
            sub(/^.*Running on[[:space:]]+/, "", agent_name)
            sub(/[[:space:]]+in[[:space:]]+\/.*$/, "", agent_name)
            sub(/^[[:space:]]+/, "", agent_name)
            sub(/[[:space:]]+$/, "", agent_name)
            print agent_name
            exit
        }
    ' || true
}

# Convert "stage<TAB>agent" lines into a JSON object map.
# Usage: _stage_agent_pairs_to_json "$pairs"
_stage_agent_pairs_to_json() {
    local stage_agent_pairs="${1:-}"

    if [[ -z "$stage_agent_pairs" ]]; then
        echo "{}"
        return 0
    fi

    local stage_agent_map_json="{}"
    local stage_name agent_name
    while IFS=$'\t' read -r stage_name agent_name; do
        [[ -z "${stage_name:-}" ]] && continue
        stage_agent_map_json=$(echo "$stage_agent_map_json" | jq \
            --arg stage "$stage_name" \
            --arg agent "$agent_name" \
            '. + {($stage): $agent}')
    done <<< "$stage_agent_pairs"

    echo "$stage_agent_map_json"
}

# Check whether console output contains a "[Pipeline] parallel" block start.
# Pure-bash substring match: piping large console output into grep -q causes
# SIGPIPE under `set -o pipefail` when grep exits at the first match.
# Usage: _console_has_parallel_block "$console_output"
_console_has_parallel_block() {
    local console_output="${1:-}"
    [[ $'\n'"${console_output}" == *$'\n'"[Pipeline] parallel"* ]]
}

# Build a deterministic stage name -> agent name map from the annotated HTML
# console (logText/progressiveHtml). Each flow-node block start is annotated
# with nodeId/enclosingId/label, and each log line with pipeline-node-<id>, so
# every "Running on <agent>" line can be attributed to its exact enclosing
# stage — no ordering guesswork, which matters for parallel branches whose
# node-allocation lines interleave in plain consoleText.
# Usage: _build_stage_agent_map_from_html "job-name" "build-number"
# Returns: JSON object like {"Integration Tests":"agent8_sixcore"}, or {} when
#          the HTML console is unavailable or carries no annotations.
_build_stage_agent_map_from_html() {
    local job_name="${1:-}"
    local build_number="${2:-}"
    if [[ -z "$job_name" || -z "$build_number" ]]; then
        echo "{}"
        return 0
    fi

    local console_html
    console_html=$(get_console_html_cached "$job_name" "$build_number" 2>/dev/null) || console_html=""
    if [[ -z "$console_html" ]]; then
        echo "{}"
        return 0
    fi

    local stage_agent_pairs
    stage_agent_pairs=$(printf "%s\n" "$console_html" | awk '
        function getattr(line, name,    re, val) {
            re = name "=\"[^\"]*\""
            if (match(line, re) == 0) {
                return ""
            }
            val = substr(line, RSTART, RLENGTH)
            sub("^" name "=\"", "", val)
            sub(/"$/, "", val)
            return val
        }

        function decode_entities(s) {
            gsub(/&lt;/, "<", s)
            gsub(/&gt;/, ">", s)
            gsub(/&quot;/, "\"", s)
            gsub(/&#039;/, "\x27", s)
            gsub(/&amp;/, "\\&", s)
            return s
        }

        /class="pipeline-new-node"/ {
            node_id = getattr($0, "nodeId")
            if (node_id != "") {
                enclosing_id = getattr($0, "enclosingId")
                if (enclosing_id != "") {
                    enclosing[node_id] = enclosing_id
                }
                node_label = getattr($0, "label")
                if (node_label != "") {
                    label[node_id] = decode_entities(node_label)
                }
            }
        }

        /class="pipeline-node-[0-9]+"/ && /Running on/ {
            text = $0
            gsub(/<[^>]*>/, "", text)
            if (text !~ /Running on[[:space:]]+.+[[:space:]]+in[[:space:]]+\//) {
                next
            }
            if (match($0, /class="pipeline-node-[0-9]+"/) == 0) {
                next
            }
            line_node_id = substr($0, RSTART, RLENGTH)
            sub(/^class="pipeline-node-/, "", line_node_id)
            sub(/"$/, "", line_node_id)
            if (line_node_id in running_on_agent) {
                next
            }
            agent_name = text
            sub(/^.*Running on[[:space:]]+/, "", agent_name)
            sub(/[[:space:]]+in[[:space:]]+\/.*$/, "", agent_name)
            sub(/^[[:space:]]+/, "", agent_name)
            sub(/[[:space:]]+$/, "", agent_name)
            agent_name = decode_entities(agent_name)
            if (agent_name != "") {
                running_on_agent[line_node_id] = agent_name
                running_on_order[++running_on_count] = line_node_id
            }
        }

        END {
            for (idx = 1; idx <= running_on_count; idx++) {
                node_id = running_on_order[idx]
                cur = node_id
                depth = 0
                while (!(cur in label) && (cur in enclosing) && depth < 100) {
                    cur = enclosing[cur]
                    depth++
                }
                if (cur in label) {
                    stage_name = label[cur]
                    sub(/^Branch:[[:space:]]+/, "", stage_name)
                    if (!(stage_name in stage_agent_map)) {
                        stage_agent_map[stage_name] = running_on_agent[node_id]
                        printf "%s\t%s\n", stage_name, running_on_agent[node_id]
                    }
                }
            }
            # Nested stages{} under an agent-owning stage never emit their own
            # "Running on" line; they run inside the enclosing allocation. Any
            # labeled stage still unmapped inherits from the nearest enclosing
            # node allocation on its enclosingId chain.
            for (nid in label) {
                stage_name = label[nid]
                sub(/^Branch:[[:space:]]+/, "", stage_name)
                if (stage_name in stage_agent_map) {
                    continue
                }
                cur = nid
                depth = 0
                while ((cur in enclosing) && depth < 100) {
                    cur = enclosing[cur]
                    depth++
                    if (cur in running_on_agent) {
                        stage_agent_map[stage_name] = running_on_agent[cur]
                        printf "%s\t%s\n", stage_name, running_on_agent[cur]
                        break
                    }
                }
            }
        }
    ' 2>/dev/null) || stage_agent_pairs=""

    _stage_agent_pairs_to_json "$stage_agent_pairs"
}

# Build a map of pipeline stage name -> Jenkins agent name from console output.
# Usage: _build_stage_agent_map "$console_output" [job-name] [build-number]
# Returns: JSON object like {"Build":"agent6 guthrie","Unit Tests A":"agent7"}
# Notes:
# - When job/build are supplied and the console contains a parallel block, the
#   annotated HTML console is consulted first: plain consoleText interleaves
#   parallel "Running on" lines nondeterministically, so any text-order
#   heuristic can map agents to the wrong branch.
# - Otherwise associates each "Running on" line with the most recent unmatched
#   stage block (reliable while stages run serially).
# - Normalizes "Branch: <name>" stage labels to "<name>" for wfapi compatibility.
_build_stage_agent_map() {
    local console_output="${1:-}"
    local job_name="${2:-}"
    local build_number="${3:-}"
    if [[ -z "$console_output" ]]; then
        echo "{}"
        return 0
    fi

    if [[ -n "$job_name" && -n "$build_number" ]] && \
        _console_has_parallel_block "$console_output"; then
        local html_map
        html_map=$(_build_stage_agent_map_from_html "$job_name" "$build_number") || html_map="{}"
        if [[ -n "$html_map" && "$html_map" != "{}" ]]; then
            echo "$html_map"
            return 0
        fi
    fi

    local stage_agent_pairs
    stage_agent_pairs=$(printf "%s\n" "$console_output" | \
        sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' | \
        awk '
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }

            {
                if ($0 ~ /^\[Pipeline\] \{ \(.+\)$/) {
                    stage_name = $0
                    sub(/^\[Pipeline\] \{ \(/, "", stage_name)
                    sub(/\)$/, "", stage_name)
                    sub(/^Branch:[[:space:]]+/, "", stage_name)
                    pending[++pending_count] = stage_name
                    next
                }

                if ($0 ~ /Running on[[:space:]]+.+[[:space:]]+in[[:space:]]+\//) {
                    agent_name = $0
                    sub(/^.*Running on[[:space:]]+/, "", agent_name)
                    sub(/[[:space:]]+in[[:space:]]+\/.*$/, "", agent_name)
                    agent_name = trim(agent_name)
                    for (i = pending_count; i >= 1; i--) {
                        if (pending[i] != "") {
                            if (!(pending[i] in stage_agent_map)) {
                                stage_agent_map[pending[i]] = agent_name
                            }
                            pending[i] = ""
                            break
                        }
                    }
                }
            }

            END {
                for (stage_name in stage_agent_map) {
                    printf "%s\t%s\n", stage_name, stage_agent_map[stage_name]
                }
            }
        ')

    _stage_agent_pairs_to_json "$stage_agent_pairs"
}

# Map parent stages to their downstream builds
# Usage: _map_stages_to_downstream "$console_output" "$stages_json"
# Returns: JSON object mapping stage names to {job, build} pairs
# Example: {"Build Handle": {"job": "downstream-job", "build": 42}}
_map_stages_to_downstream() {
    local console_output="$1"
    local stages_json="$2"

    # Perf: pull every stage name out of stages_json in one jq pass; the loop
    # body only forks jq when a downstream is actually matched (rare — ~N_ds
    # forks total, where N_ds is the number of component builds).
    local -a _map_stage_names=()
    local _map_name
    while IFS= read -r _map_name; do
        [[ -z "$_map_name" ]] && continue
        _map_stage_names+=("$_map_name")
    done < <(echo "$stages_json" | jq -r '.[]?.name // empty' 2>/dev/null)

    local stage_count=${#_map_stage_names[@]}
    # Accumulate matches into parallel arrays; emit one jq fork at the end.
    local -a _map_out_stages=() _map_out_jobs=() _map_out_builds=()
    # Track downstream keys already claimed by a positive-score match.
    local -a _map_claimed_keys=()

    local i=0
    while [[ $i -lt $stage_count ]]; do
        local stage_name="${_map_stage_names[$i]}"

        # Extract this stage's console logs
        local stage_logs
        stage_logs=$(extract_stage_logs "$console_output" "$stage_name")

        if [[ -n "$stage_logs" ]]; then
            # Check for downstream builds in this stage's logs
            local downstream
            downstream=$(detect_all_downstream_builds "$stage_logs")

            if [[ -n "$downstream" ]]; then
                # Select best downstream match for this stage
                local ds_job ds_build
                local selected_downstream
                selected_downstream=$(_select_downstream_build_for_stage "$stage_name" "$downstream" "$stage_logs")
                ds_job=$(echo "$selected_downstream" | awk '{print $1}')
                ds_build=$(echo "$selected_downstream" | awk '{print $2}')

                if [[ -n "$ds_job" && -n "$ds_build" ]]; then
                    local downstream_key selected_score already_claimed_by_positive
                    downstream_key="${ds_job}#${ds_build}"
                    selected_score=$(_downstream_stage_job_match_score "$stage_name" "$ds_job")

                    already_claimed_by_positive="false"
                    if [[ ${#_map_claimed_keys[@]} -gt 0 ]]; then
                        local _ck
                        for _ck in "${_map_claimed_keys[@]}"; do
                            if [[ "$_ck" == "$downstream_key" ]]; then
                                already_claimed_by_positive="true"
                                break
                            fi
                        done
                    fi

                    if [[ "$selected_score" -le 0 && "$already_claimed_by_positive" == "true" ]]; then
                        i=$((i + 1))
                        continue
                    fi

                    _map_out_stages+=("$stage_name")
                    _map_out_jobs+=("$ds_job")
                    _map_out_builds+=("$ds_build")
                    if [[ "$selected_score" -gt 0 ]]; then
                        _map_claimed_keys+=("$downstream_key")
                    fi
                fi
            fi
        fi

        i=$((i + 1))
    done

    local match_count=${#_map_out_stages[@]}
    if [[ $match_count -eq 0 ]]; then
        echo "{}"
        return 0
    fi

    # Build the result map in a single jq call.
    local tsv_input="" j=0
    while [[ $j -lt $match_count ]]; do
        tsv_input+="${_map_out_stages[$j]}"$'\x1f'"${_map_out_jobs[$j]}"$'\x1f'"${_map_out_builds[$j]}"$'\n'
        j=$((j + 1))
    done
    printf '%s' "$tsv_input" | jq -Rsc '
        [ split("\n")
          | map(select(length > 0))
          | map(split("\u001f"))
          | .[]
          | {(.[0]): {job: .[1], build: (.[2] | tonumber)}}
        ] | add // {}
    '
}

_detect_branch_substages_from_blue_ocean() {
    local stages_json="$1"
    local blue_nodes_json="$2"
    local wrapper_stage="$3"
    local branches_json="$4"

    if [[ -z "$blue_nodes_json" || "$blue_nodes_json" == "[]" ]]; then
        echo "{}"
        return 0
    fi

    jq -cn \
        --arg wrapper "$wrapper_stage" \
        --argjson stages "$stages_json" \
        --argjson nodes "$blue_nodes_json" \
        --argjson branches "$branches_json" '
        def find_by_id($id): ($nodes[] | select(.id == $id));
        def nearest_parallel($node_id):
            if ($node_id == null or $node_id == "") then
                null
            else
                (find_by_id($node_id)?) as $node
                | if $node == null then
                    null
                  elif $node.type == "PARALLEL" then
                    $node
                  else
                    nearest_parallel($node.firstParent)
                  end
            end;

        ($stages | map(select(.name == $wrapper)) | first) as $wrapper_entry
        | if ($wrapper_entry | type) == "null" or (($wrapper_entry.id // "") == "") then
            {}
          else
            ($nodes | map(select(.type == "PARALLEL" and .firstParent == ($wrapper_entry.id | tostring))) | map({(.id): .name}) | add // {}) as $branch_by_id
            | reduce $branches[] as $branch (
                ($branches | map({(.): []}) | add // {});
                .[$branch] = (
                    $stages
                    | map(select((.id // "") != "" and .name != $wrapper and .name != $branch))
                    | map(
                        . as $stage
                        | (nearest_parallel(($stage.id | tostring))) as $parallel
                        | select($parallel != null and ($branch_by_id[$parallel.id] // "") == $branch)
                        | $stage
                    )
                    | sort_by(.startTimeMillis, .name)
                    | map(.name)
                )
            )
          end
        '
}

_extract_agent_before_console_marker() {
    local console_output="$1"
    local marker="$2"

    if [[ -z "$console_output" || -z "$marker" ]]; then
        return 0
    fi

    printf "%s\n" "$console_output" | awk -v marker="$marker" '
        /Running on[[:space:]]+.+[[:space:]]+in[[:space:]]+\// {
            agent = $0
            sub(/^.*Running on[[:space:]]+/, "", agent)
            sub(/[[:space:]]+in[[:space:]]+\/.*$/, "", agent)
            last_agent = agent
        }

        index($0, marker) {
            if (last_agent != "") {
                print last_agent
            }
            exit
        }
    ' || true
}

_detect_parallel_branch_agent_from_blue_ocean() {
    local job_name="$1"
    local build_number="$2"
    local branch_node_id="$3"
    local console_output="$4"
    local pipeline_scope_agent="$5"

    if [[ -z "$branch_node_id" ]]; then
        echo "$pipeline_scope_agent"
        return 0
    fi

    local steps_json
    steps_json=$(get_blue_ocean_node_steps "$job_name" "$build_number" "$branch_node_id" 2>/dev/null) || steps_json="[]"
    if [[ -z "$steps_json" || "$steps_json" == "[]" ]]; then
        echo "$pipeline_scope_agent"
        return 0
    fi

    local has_branch_local_setup
    has_branch_local_setup=$(echo "$steps_json" | jq -r 'map(select(.displayName == "Check out from version control")) | length > 0')
    if [[ "$has_branch_local_setup" != "true" ]]; then
        echo "$pipeline_scope_agent"
        return 0
    fi

    local marker agent
    marker=$(echo "$steps_json" | jq -r 'map(select(.displayDescription != "")) | .[0].displayDescription // empty')
    agent=$(_extract_agent_before_console_marker "$console_output" "$marker")
    if [[ -n "$agent" ]]; then
        echo "$agent"
    else
        echo "$pipeline_scope_agent"
    fi
}

# Get nested stages for a build, recursively expanding downstream builds
# Usage: _get_nested_stages "job-name" "build-number" [prefix] [nesting_depth] [parent_stage] [parallel_path]
# Returns: JSON array of stage objects with nested stage metadata
_get_nested_stages() {
    local job_name="$1"
    local build_number="$2"
    local prefix="${3:-}"
    local nesting_depth="${4:-0}"
    local parent_stage_name="${5:-}"
    local inherited_parallel_path="${6:-}"
    local parallel_max="${BUILDGIT_PARALLEL_MAX:-8}"
    if ! [[ "$parallel_max" =~ ^[1-9][0-9]*$ ]]; then
        parallel_max=8
    fi

    local pfetch_dir
    pfetch_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildgit-pfetch.XXXXXX")

    get_all_stages "$job_name" "$build_number" > "${pfetch_dir}/stages" 2>/dev/null 3>&- &
    local p1=$!
    get_console_output_cached "$job_name" "$build_number" > "${pfetch_dir}/console" 2>/dev/null 3>&- &
    local p2=$!
    get_blue_ocean_nodes "$job_name" "$build_number" > "${pfetch_dir}/blue" 2>/dev/null 3>&- &
    local p3=$!

    wait "$p1" "$p2" "$p3" 2>/dev/null || true

    local stages_json
    stages_json=$(cat "${pfetch_dir}/stages" 2>/dev/null)
    local console_output
    console_output=$(cat "${pfetch_dir}/console" 2>/dev/null)
    local blue_nodes_json
    blue_nodes_json=$(cat "${pfetch_dir}/blue" 2>/dev/null)
    rm -rf "$pfetch_dir"

    [[ -z "$stages_json" || "$stages_json" == "null" ]] && stages_json="[]"
    [[ -z "$blue_nodes_json" || "$blue_nodes_json" == "null" ]] && blue_nodes_json="[]"
    if [[ -z "$stages_json" || "$stages_json" == "[]" ]]; then
        echo "[]"
        return 0
    fi

    local stage_agent_map="{}"
    local pipeline_scope_agent=""
    local stage_agent_map_is_html="false"
    local html_map_attempted="false"
    if [[ -n "$console_output" ]]; then
        if _console_has_parallel_block "$console_output"; then
            local html_stage_agent_map
            html_stage_agent_map=$(_build_stage_agent_map_from_html "$job_name" "$build_number") || html_stage_agent_map="{}"
            html_map_attempted="true"
            if [[ -n "$html_stage_agent_map" && "$html_stage_agent_map" != "{}" ]]; then
                stage_agent_map="$html_stage_agent_map"
                stage_agent_map_is_html="true"
            fi
        fi
        if [[ "$stage_agent_map_is_html" != "true" ]]; then
            stage_agent_map=$(_build_stage_agent_map "$console_output")
        fi
        pipeline_scope_agent=$(_extract_pre_stage_agent_from_console "$console_output")
        if [[ "$stage_agent_map_is_html" != "true" && "$html_map_attempted" != "true" && -z "$pipeline_scope_agent" ]]; then
            # Serial pipeline with `agent none` + a stage-scoped agent: nested
            # stages{} under the agent-owning stage have no "Running on" lines
            # and no pipeline-scope fallback, so the plain-text map leaves them
            # agent-less. The annotated HTML console's enclosure chains can
            # attribute them to the nearest enclosing node allocation.
            local has_agentless_stage
            has_agentless_stage=$(echo "$stages_json" | jq -r --argjson map "$stage_agent_map" \
                '[.[]? | .name // empty | select(. != "") | select(($map[.] // "") == "")] | length > 0' 2>/dev/null) || has_agentless_stage="false"
            if [[ "$has_agentless_stage" == "true" ]]; then
                local html_fill_map
                html_fill_map=$(_build_stage_agent_map_from_html "$job_name" "$build_number") || html_fill_map="{}"
                if [[ -n "$html_fill_map" && "$html_fill_map" != "{}" ]]; then
                    stage_agent_map=$(jq -cn --argjson text "$stage_agent_map" --argjson html "$html_fill_map" '$text + $html' 2>/dev/null) || stage_agent_map="$html_fill_map"
                fi
            fi
        fi
    fi

    local parallel_info="{}"
    local _branch_to_wrapper="{}"
    local _branch_to_path="{}"
    local _branch_to_local_substages="{}"
    local _substage_to_branch="{}"
    local _branch_to_blue_node_id="{}"
    local _wrapper_last_branch_index="{}"
    local _branch_aggregate_duration="{}"
    if [[ -n "$console_output" ]]; then
        # Perf: pre-extract stage names once, and collect per-wrapper branch/
        # substage data into bash parallel arrays. A single jq pass at the end
        # builds all six maps in one shot, replacing O(wrappers × branches × 7)
        # jq forks in the legacy per-branch loop.
        local -a _ns_names=()
        local _ns_n
        while IFS= read -r _ns_n; do
            [[ -z "$_ns_n" ]] && continue
            _ns_names+=("$_ns_n")
        done < <(echo "$stages_json" | jq -r '.[]?.name // empty' 2>/dev/null)

        local stage_count_for_parallel=${#_ns_names[@]}
        local _pw_fsep=$'\x1f'  # Unit Separator — between fields within a record
        local _pw_rsep=$'\x1e'  # Record Separator — between records
        local _pw_input=""
        local pi=0
        while [[ $pi -lt $stage_count_for_parallel ]]; do
            local pi_stage_name="${_ns_names[$pi]}"
            local branches
            branches=$(_detect_parallel_branches "$console_output" "$pi_stage_name")
            if [[ -n "$branches" && "$branches" != "[]" ]]; then
                local branch_substages
                branch_substages=$(_detect_branch_substages "$console_output" "$pi_stage_name")
                if [[ "$blue_nodes_json" != "[]" ]]; then
                    local blue_branch_substages
                    blue_branch_substages=$(_detect_branch_substages_from_blue_ocean "$stages_json" "$blue_nodes_json" "$pi_stage_name" "$branches")
                    if [[ -n "$blue_branch_substages" && "$blue_branch_substages" != "{}" ]]; then
                        branch_substages="$blue_branch_substages"
                    fi
                fi
                [[ -z "$branch_substages" ]] && branch_substages="{}"
                # Append (wrapper, branches_json, substages_json) separated by
                # \x1f within a record and \x1e between records — both are
                # non-whitespace control chars that can't appear in valid JSON
                # content, so they won't collide with the embedded JSON values.
                _pw_input+="${pi_stage_name}${_pw_fsep}${branches}${_pw_fsep}${branch_substages}${_pw_rsep}"
            fi
            pi=$((pi + 1))
        done

        if [[ -n "$_pw_input" ]]; then
            local _parallel_maps
            _parallel_maps=$(printf '%s' "$_pw_input" | jq -Rsc \
                --arg fsep "$_pw_fsep" \
                --arg rsep "$_pw_rsep" \
                --arg prefix "$inherited_parallel_path" \
                --argjson stages "$stages_json" \
                --argjson blue "$blue_nodes_json" '
                ($stages | to_entries | map({(.value.name): .key}) | add // {}) as $name_to_idx
                | ($stages | map({(.name): (.id // "")}) | add // {}) as $name_to_id
                | ($blue // []) as $blue_nodes
                | [ split($rsep) | .[] | select(length > 0) | split($fsep)
                    | { wrapper: .[0],
                        branches: (.[1] | fromjson),
                        substages: (.[2] | fromjson) } ]
                  as $items
                | reduce $items[] as $it (
                    { parallel_info: {},
                      branch_to_wrapper: {},
                      branch_to_path: {},
                      branch_to_local_substages: {},
                      substage_to_branch: {},
                      branch_to_blue_node_id: {},
                      wrapper_last_branch_index: {} };
                    . as $acc
                    | $it.wrapper as $w
                    | ($it.branches // []) as $brs
                    | ($it.substages // {}) as $subs
                    | ($name_to_id[$w] // "") as $wrapper_id
                    | $acc
                    | .parallel_info = (.parallel_info + { ($w): { branches: $brs } })
                    | reduce ($brs | to_entries[]) as $be (
                        .;
                        $be.value as $bname
                        | ($be.key + 1) as $branch_index
                        | (if $prefix == "" then ($branch_index | tostring)
                           else ($prefix + "." + ($branch_index | tostring)) end) as $bpath
                        | ($subs[$bname] // []) as $bsubs
                        | .branch_to_wrapper = (.branch_to_wrapper + { ($bname): $w })
                        | .branch_to_path = (.branch_to_path + { ($bname): $bpath })
                        | .branch_to_local_substages = (.branch_to_local_substages + { ($bname): $bsubs })
                        | reduce $bsubs[] as $ss (
                            .;
                            .substage_to_branch = (.substage_to_branch + { ($ss): $bname })
                          )
                        | (if $wrapper_id != "" then
                             ([ $blue_nodes[]
                                | select(.type == "PARALLEL"
                                         and .firstParent == ($wrapper_id | tostring)
                                         and .name == $bname) ][0].id // "")
                           else "" end) as $bnode_id
                        | (if $bnode_id != ""
                           then .branch_to_blue_node_id = (.branch_to_blue_node_id + { ($bname): $bnode_id })
                           else . end)
                      )
                    | ([ $brs[] | ($name_to_idx[.] // -1) | select(. >= 0) ] | max // -1) as $max_idx
                    | (if $max_idx >= 0
                       then .wrapper_last_branch_index = (.wrapper_last_branch_index + { ($w): $max_idx })
                       else . end)
                )
            ')
            parallel_info=$(echo "$_parallel_maps" | jq -c '.parallel_info')
            _branch_to_wrapper=$(echo "$_parallel_maps" | jq -c '.branch_to_wrapper')
            _branch_to_path=$(echo "$_parallel_maps" | jq -c '.branch_to_path')
            _branch_to_local_substages=$(echo "$_parallel_maps" | jq -c '.branch_to_local_substages')
            _substage_to_branch=$(echo "$_parallel_maps" | jq -c '.substage_to_branch')
            _branch_to_blue_node_id=$(echo "$_parallel_maps" | jq -c '.branch_to_blue_node_id')
            _wrapper_last_branch_index=$(echo "$_parallel_maps" | jq -c '.wrapper_last_branch_index')
        fi
    fi

    local branch_name
    while IFS= read -r branch_name; do
        [[ -z "$branch_name" ]] && continue
        local branch_duration aggregate_duration
        branch_duration=$(echo "$stages_json" | jq -r --arg n "$branch_name" '[.[] | select(.name == $n)][0].durationMillis // 0')
        aggregate_duration="$branch_duration"
        if ! [[ "$aggregate_duration" =~ ^[0-9]+$ ]]; then
            aggregate_duration=0
        fi

        local branch_local_substages
        branch_local_substages=$(echo "$_branch_to_local_substages" | jq -r --arg b "$branch_name" '.[$b] // [] | .[]')
        local substage_name
        while IFS= read -r substage_name; do
            [[ -z "$substage_name" ]] && continue
            local substage_duration
            substage_duration=$(echo "$stages_json" | jq -r --arg n "$substage_name" '[.[] | select(.name == $n)][0].durationMillis // 0')
            if [[ "$substage_duration" =~ ^[0-9]+$ ]]; then
                aggregate_duration=$((aggregate_duration + substage_duration))
            fi
        done <<< "$branch_local_substages"

        _branch_aggregate_duration=$(echo "$_branch_aggregate_duration" | jq \
            --arg b "$branch_name" \
            --argjson d "$aggregate_duration" \
            '. + {($b): $d}')
    done <<< "$(echo "$_branch_to_wrapper" | jq -r 'keys[]?')"

    local stage_downstream_map="{}"
    if [[ -n "$console_output" ]]; then
        local filtered_stages_json
        if [[ "$parallel_info" != "{}" ]]; then
            filtered_stages_json=$(echo "$stages_json" | jq --argjson pi "$parallel_info" \
                '[.[] | select(.name as $n | $pi | has($n) | not)]')
        else
            filtered_stages_json="$stages_json"
        fi
        stage_downstream_map=$(_map_stages_to_downstream "$console_output" "$filtered_stages_json")
    fi

    local stage_count
    stage_count=$(echo "$stages_json" | jq 'length')

    # Perf: pre-extract per-stage fields in a single jq pass so the collect and
    # main loops can index bash arrays instead of forking jq per stage per loop.
    local -a _gs_names=() _gs_status=() _gs_duration=()
    local _gs_n _gs_s _gs_d
    while IFS=$'\t' read -r _gs_n _gs_s _gs_d; do
        _gs_names+=("$_gs_n")
        _gs_status+=("$_gs_s")
        _gs_duration+=("$_gs_d")
    done < <(echo "$stages_json" | jq -r '.[]? | [.name, .status, (.durationMillis|tostring)] | @tsv' 2>/dev/null)

    local -a recursive_job_names
    local -a recursive_build_numbers
    local -a recursive_prefixes
    local -a recursive_parent_names
    local -a recursive_parallel_paths
    local -a recursive_output_files
    local recursive_task_count=0

    if [[ "$stage_downstream_map" != "{}" ]]; then
        local collect_i=0
        while [[ $collect_i -lt $stage_count ]]; do
            local collect_stage_name
            collect_stage_name="${_gs_names[$collect_i]}"

            local collect_local_parent_branch
            collect_local_parent_branch=$(echo "$_substage_to_branch" | jq -r --arg s "$collect_stage_name" '.[$s] // empty')
            if [[ -n "$collect_local_parent_branch" && "$collect_local_parent_branch" != "null" ]]; then
                collect_i=$((collect_i + 1))
                continue
            fi

            local collect_parallel_branch=""
            local collect_stage_parallel_path="$inherited_parallel_path"
            local collect_bw_check
            collect_bw_check=$(echo "$_branch_to_wrapper" | jq -r --arg b "$collect_stage_name" '.[$b] // empty')
            if [[ -n "$collect_bw_check" && "$collect_bw_check" != "null" ]]; then
                collect_parallel_branch="$collect_stage_name"
                collect_stage_parallel_path=$(echo "$_branch_to_path" | jq -r --arg b "$collect_stage_name" '.[$b] // empty')
            fi

            local collect_display_name
            if [[ -n "$prefix" ]]; then
                collect_display_name="${prefix}->${collect_stage_name}"
            else
                collect_display_name="${collect_stage_name}"
            fi

            local collect_branch_local_substages_json="[]"
            if [[ -n "$collect_parallel_branch" ]]; then
                collect_branch_local_substages_json=$(echo "$_branch_to_local_substages" | jq --arg b "$collect_stage_name" '.[$b] // []')
            fi

            if [[ "$collect_branch_local_substages_json" != "[]" ]]; then
                local collect_local_substage_name
                while IFS= read -r collect_local_substage_name; do
                    [[ -z "$collect_local_substage_name" ]] && continue
                    local collect_local_substage_display_name collect_local_substage_ds_info
                    collect_local_substage_display_name="${collect_display_name}->${collect_local_substage_name}"
                    collect_local_substage_ds_info=$(echo "$stage_downstream_map" | jq -r --arg s "$collect_local_substage_name" '.[$s] // empty')
                    if [[ -n "$collect_local_substage_ds_info" && "$collect_local_substage_ds_info" != "null" ]]; then
                        recursive_job_names[$recursive_task_count]=$(echo "$collect_local_substage_ds_info" | jq -r '.job')
                        recursive_build_numbers[$recursive_task_count]=$(echo "$collect_local_substage_ds_info" | jq -r '.build')
                        recursive_prefixes[$recursive_task_count]="$collect_local_substage_display_name"
                        recursive_parent_names[$recursive_task_count]="$collect_local_substage_name"
                        recursive_parallel_paths[$recursive_task_count]="$collect_stage_parallel_path"
                        recursive_task_count=$((recursive_task_count + 1))
                    fi
                done <<< "$(echo "$collect_branch_local_substages_json" | jq -r '.[]')"
            fi

            local collect_ds_info
            collect_ds_info=$(echo "$stage_downstream_map" | jq -r --arg s "$collect_stage_name" '.[$s] // empty')
            if [[ -n "$collect_ds_info" && "$collect_ds_info" != "null" ]]; then
                recursive_job_names[$recursive_task_count]=$(echo "$collect_ds_info" | jq -r '.job')
                recursive_build_numbers[$recursive_task_count]=$(echo "$collect_ds_info" | jq -r '.build')
                recursive_prefixes[$recursive_task_count]="$collect_display_name"
                recursive_parent_names[$recursive_task_count]="$collect_stage_name"
                recursive_parallel_paths[$recursive_task_count]="$collect_stage_parallel_path"
                recursive_task_count=$((recursive_task_count + 1))
            fi

            collect_i=$((collect_i + 1))
        done
    fi

    local recursive_dir=""
    if [[ $recursive_task_count -gt 0 ]]; then
        recursive_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildgit-nested.XXXXXX")
        local batch_start=0
        while [[ $batch_start -lt $recursive_task_count ]]; do
            local batch_end=$((batch_start + parallel_max))
            if [[ $batch_end -gt $recursive_task_count ]]; then
                batch_end=$recursive_task_count
            fi

            local -a batch_pids
            local batch_pid_count=0
            local task_idx=$batch_start
            while [[ $task_idx -lt $batch_end ]]; do
                recursive_output_files[$task_idx]="${recursive_dir}/${task_idx}.json"
                (
                    _get_nested_stages \
                        "${recursive_job_names[$task_idx]}" \
                        "${recursive_build_numbers[$task_idx]}" \
                        "${recursive_prefixes[$task_idx]}" \
                        "$((nesting_depth + 1))" \
                        "${recursive_parent_names[$task_idx]}" \
                        "${recursive_parallel_paths[$task_idx]}" \
                        > "${recursive_output_files[$task_idx]}" 2>/dev/null 3>&-
                ) &
                batch_pids[$batch_pid_count]=$!
                batch_pid_count=$((batch_pid_count + 1))
                task_idx=$((task_idx + 1))
            done

            local pid_idx=0
            while [[ $pid_idx -lt $batch_pid_count ]]; do
                wait "${batch_pids[$pid_idx]}" 2>/dev/null || true
                pid_idx=$((pid_idx + 1))
            done

            batch_start=$batch_end
        done
    fi

    local result="[]"
    local deferred_wrappers="{}"
    local recursive_result_idx=0

    local i=0
    while [[ $i -lt $stage_count ]]; do
        local stage_name status duration_ms
        stage_name="${_gs_names[$i]}"
        status="${_gs_status[$i]}"
        duration_ms="${_gs_duration[$i]}"

        local local_parent_branch
        local_parent_branch=$(echo "$_substage_to_branch" | jq -r --arg s "$stage_name" '.[$s] // empty')
        if [[ -n "$local_parent_branch" && "$local_parent_branch" != "null" ]]; then
            i=$((i + 1))
            continue
        fi

        local stage_agent=""
        local stage_agent_from_map=""
        if [[ "$stage_agent_map" != "{}" ]]; then
            stage_agent_from_map=$(echo "$stage_agent_map" | jq -r --arg s "$stage_name" '.[$s] // empty')
            stage_agent="$stage_agent_from_map"
        fi
        if [[ -z "$stage_agent" && -n "$pipeline_scope_agent" ]]; then
            stage_agent="$pipeline_scope_agent"
        fi

        local is_parallel_wrapper="false"
        local parallel_branches_json="null"
        local parallel_branch=""
        local parallel_wrapper=""
        local stage_parallel_path="$inherited_parallel_path"

        local wrapper_check
        wrapper_check=$(echo "$parallel_info" | jq -r --arg s "$stage_name" 'has($s)') || wrapper_check="false"
        if [[ "$wrapper_check" == "true" ]]; then
            is_parallel_wrapper="true"
            stage_parallel_path=""
            parallel_branches_json=$(echo "$parallel_info" | jq --arg s "$stage_name" '.[$s].branches')
            local max_branch_dur=0
            local branch_name
            while IFS= read -r branch_name; do
                [[ -z "$branch_name" ]] && continue
                local bd
                bd=$(echo "$_branch_aggregate_duration" | jq -r --arg n "$branch_name" '.[$n] // 0')
                if [[ "$bd" =~ ^[0-9]+$ && "$bd" -gt "$max_branch_dur" ]]; then
                    max_branch_dur="$bd"
                fi
            done <<< "$(echo "$parallel_branches_json" | jq -r '.[]')"
            if [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
                duration_ms=$((duration_ms + max_branch_dur))
            fi
        fi

        local bw_check
        bw_check=$(echo "$_branch_to_wrapper" | jq -r --arg b "$stage_name" '.[$b] // empty')
        if [[ -n "$bw_check" && "$bw_check" != "null" ]]; then
            parallel_branch="$stage_name"
            parallel_wrapper="$bw_check"
            stage_parallel_path=$(echo "$_branch_to_path" | jq -r --arg b "$stage_name" '.[$b] // empty')
            duration_ms=$(echo "$_branch_aggregate_duration" | jq -r --arg b "$stage_name" '.[$b] // empty')
            # The HTML-annotated map ties each "Running on" line to its exact
            # stage; the Blue Ocean console-marker heuristic below can misfire
            # on interleaved parallel output, so only use it as a fallback.
            if [[ "$stage_agent_map_is_html" == "true" && -n "$stage_agent_from_map" ]]; then
                :
            elif [[ -n "$blue_nodes_json" && "$blue_nodes_json" != "[]" ]]; then
                local branch_blue_node_id branch_agent_from_blue
                branch_blue_node_id=$(echo "$_branch_to_blue_node_id" | jq -r --arg b "$stage_name" '.[$b] // empty')
                branch_agent_from_blue=$(_detect_parallel_branch_agent_from_blue_ocean "$job_name" "$build_number" "$branch_blue_node_id" "$console_output" "$pipeline_scope_agent")
                if [[ -n "$branch_agent_from_blue" ]]; then
                    stage_agent="$branch_agent_from_blue"
                fi
            fi
        fi

        local ds_info
        ds_info=$(echo "$stage_downstream_map" | jq -r --arg s "$stage_name" '.[$s] // empty')

        local display_name
        if [[ -n "$prefix" ]]; then
            display_name="${prefix}->${stage_name}"
        else
            display_name="${stage_name}"
        fi

        local branch_local_substages_json="[]"
        if [[ -n "$parallel_branch" ]]; then
            branch_local_substages_json=$(echo "$_branch_to_local_substages" | jq --arg b "$stage_name" '.[$b] // []')
        fi

        if [[ "$branch_local_substages_json" != "[]" ]]; then
            local local_substage_name
            while IFS= read -r local_substage_name; do
                [[ -z "$local_substage_name" ]] && continue

                local local_substage_json local_substage_status local_substage_duration
                local_substage_json=$(echo "$stages_json" | jq -c --arg n "$local_substage_name" '[.[] | select(.name == $n)][0]')
                [[ -z "$local_substage_json" || "$local_substage_json" == "null" ]] && continue
                local_substage_status=$(echo "$local_substage_json" | jq -r '.status')
                local_substage_duration=$(echo "$local_substage_json" | jq -r '.durationMillis')

                local local_substage_agent=""
                if [[ "$stage_agent_map" != "{}" ]]; then
                    local_substage_agent=$(echo "$stage_agent_map" | jq -r --arg s "$local_substage_name" '.[$s] // empty')
                fi
                if [[ -z "$local_substage_agent" ]]; then
                    local_substage_agent="$stage_agent"
                fi
                if [[ -z "$local_substage_agent" && -n "$pipeline_scope_agent" ]]; then
                    local_substage_agent="$pipeline_scope_agent"
                fi

                local local_substage_display_name="${display_name}->${local_substage_name}"
                local local_substage_ds_info
                local_substage_ds_info=$(echo "$stage_downstream_map" | jq -r --arg s "$local_substage_name" '.[$s] // empty')
                if [[ -n "$local_substage_ds_info" && "$local_substage_ds_info" != "null" ]]; then
                    local nested_stages
                    nested_stages="[]"
                    if [[ -n "$recursive_dir" && -f "${recursive_output_files[$recursive_result_idx]}" ]]; then
                        nested_stages=$(cat "${recursive_output_files[$recursive_result_idx]}" 2>/dev/null)
                    fi
                    [[ -z "$nested_stages" ]] && nested_stages="[]"
                    recursive_result_idx=$((recursive_result_idx + 1))

                    nested_stages=$(echo "$nested_stages" | jq \
                        --arg pb "$parallel_branch" \
                        --arg pw "$parallel_wrapper" \
                        --arg pp "$stage_parallel_path" \
                        '[.[] |
                            . + (if $pb != "" and ((.parallel_branch // "") == "") then {parallel_branch: $pb} else {} end)
                              + (if $pw != "" and ((.parallel_wrapper // "") == "") then {parallel_wrapper: $pw} else {} end)
                              + (if $pp != "" and ((.parallel_path // "") == "") then {parallel_path: $pp} else {} end)
                        ]')

                    if [[ "$nested_stages" != "[]" ]]; then
                        result=$(echo "$result" "$nested_stages" | jq -s '.[0] + .[1]')
                    fi
                fi

                local local_substage_entry
                local_substage_entry=$(jq -n \
                    --arg name "$local_substage_display_name" \
                    --arg status "$local_substage_status" \
                    --argjson duration_ms "$local_substage_duration" \
                    --arg agent "$local_substage_agent" \
                    --argjson nesting_depth "$nesting_depth" \
                    --arg parallel_branch "$parallel_branch" \
                    --arg parallel_wrapper "$parallel_wrapper" \
                    --arg parallel_path "${stage_parallel_path:-}" \
                    --arg parent_branch_stage "$stage_name" \
                    --argjson has_downstream "$(if [[ "$local_substage_ds_info" != "" && "$local_substage_ds_info" != "null" ]]; then echo true; else echo false; fi)" \
                    '{
                        name: $name,
                        status: $status,
                        durationMillis: $duration_ms,
                        agent: $agent,
                        nesting_depth: $nesting_depth,
                        has_downstream: $has_downstream,
                        parent_branch_stage: $parent_branch_stage
                    }
                    + (if $parallel_branch != "" then {parallel_branch: $parallel_branch, parallel_wrapper: $parallel_wrapper} else {} end)
                    + (if $parallel_path != "" then {parallel_path: $parallel_path} else {} end)')
                result=$(echo "$result" | jq --argjson entry "$local_substage_entry" '. + [$entry]')
            done <<< "$(echo "$branch_local_substages_json" | jq -r '.[]')"
        fi

        local nested_stages="[]"
        if [[ -n "$ds_info" && "$ds_info" != "null" ]]; then
            if [[ -n "$recursive_dir" && -f "${recursive_output_files[$recursive_result_idx]}" ]]; then
                nested_stages=$(cat "${recursive_output_files[$recursive_result_idx]}" 2>/dev/null)
            fi
            [[ -z "$nested_stages" ]] && nested_stages="[]"
            recursive_result_idx=$((recursive_result_idx + 1))

            if [[ -n "$parallel_branch" ]]; then
                nested_stages=$(echo "$nested_stages" | jq \
                    --arg pb "$parallel_branch" \
                    --arg pw "$parallel_wrapper" \
                    --arg pp "$stage_parallel_path" \
                    '[.[] |
                        . + (if ((.parallel_branch // "") == "") then {parallel_branch: $pb} else {} end)
                          + (if $pw != "" and ((.parallel_wrapper // "") == "") then {parallel_wrapper: $pw} else {} end)
                          + (if $pp != "" and ((.parallel_path // "") == "") then {parallel_path: $pp} else {} end)
                    ]')
            fi

            if [[ "$nested_stages" != "[]" ]]; then
                result=$(echo "$result" "$nested_stages" | jq -s '.[0] + .[1]')
            fi
        fi

        local stage_entry
        if [[ $nesting_depth -gt 0 ]]; then
            stage_entry=$(jq -n \
                --arg name "$display_name" \
                --arg status "$status" \
                --argjson duration_ms "$duration_ms" \
                --arg agent "$stage_agent" \
                --argjson nesting_depth "$nesting_depth" \
                --arg downstream_job "$job_name" \
                --argjson downstream_build "$build_number" \
                --arg parent_stage "$parent_stage_name" \
                --arg parallel_branch "${parallel_branch:-}" \
                --arg parallel_wrapper "${parallel_wrapper:-}" \
                --arg parallel_path "${stage_parallel_path:-}" \
                --argjson has_downstream "$(if [[ "$ds_info" != "" && "$ds_info" != "null" ]]; then echo true; else echo false; fi)" \
                '{
                    name: $name,
                    status: $status,
                    durationMillis: $duration_ms,
                    agent: $agent,
                    nesting_depth: $nesting_depth,
                    downstream_job: $downstream_job,
                    downstream_build: $downstream_build,
                    parent_stage: $parent_stage,
                    has_downstream: $has_downstream
                }
                + (if $parallel_branch != "" then {parallel_branch: $parallel_branch} else {} end)
                + (if $parallel_wrapper != "" then {parallel_wrapper: $parallel_wrapper} else {} end)
                + (if $parallel_path != "" then {parallel_path: $parallel_path} else {} end)')
        else
            stage_entry=$(jq -n \
                --arg name "$display_name" \
                --arg status "$status" \
                --argjson duration_ms "$duration_ms" \
                --arg agent "$stage_agent" \
                --argjson nesting_depth "$nesting_depth" \
                --argjson is_parallel_wrapper "$is_parallel_wrapper" \
                --argjson parallel_branches "${parallel_branches_json:-null}" \
                --arg parallel_branch "$parallel_branch" \
                --arg parallel_wrapper "$parallel_wrapper" \
                --arg parallel_path "${stage_parallel_path:-}" \
                --argjson has_downstream "$(if [[ "$ds_info" != "" && "$ds_info" != "null" ]]; then echo true; else echo false; fi)" \
                '{
                    name: $name,
                    status: $status,
                    durationMillis: $duration_ms,
                    agent: $agent,
                    nesting_depth: $nesting_depth,
                    has_downstream: $has_downstream
                }
                + (if $is_parallel_wrapper == true then {is_parallel_wrapper: true, parallel_branches: $parallel_branches} else {} end)
                + (if $parallel_branch != "" then {parallel_branch: $parallel_branch, parallel_wrapper: $parallel_wrapper} else {} end)
                + (if $parallel_path != "" then {parallel_path: $parallel_path} else {} end)')
        fi

        if [[ "$is_parallel_wrapper" == "true" ]]; then
            local wrapper_emit_after_idx
            wrapper_emit_after_idx=$(echo "$_wrapper_last_branch_index" | jq -r --arg w "$stage_name" '.[$w] // empty' 2>/dev/null)
            if [[ "$wrapper_emit_after_idx" =~ ^[0-9]+$ && "$i" -ge "$wrapper_emit_after_idx" ]]; then
                result=$(echo "$result" | jq --argjson entry "$stage_entry" '. + [$entry]')
            else
                deferred_wrappers=$(echo "$deferred_wrappers" | jq --arg w "$stage_name" --argjson e "$stage_entry" '. + {($w): $e}')
            fi
        else
            result=$(echo "$result" | jq --argjson entry "$stage_entry" '. + [$entry]')
        fi

        local wrappers_to_emit
        wrappers_to_emit=$(echo "$_wrapper_last_branch_index" | jq -r --argjson idx "$i" \
            'to_entries[] | select(.value == $idx) | .key' 2>/dev/null) || true
        while IFS= read -r emit_wrapper; do
            [[ -z "$emit_wrapper" ]] && continue
            local wrapper_entry
            wrapper_entry=$(echo "$deferred_wrappers" | jq -c --arg w "$emit_wrapper" '.[$w] // empty')
            if [[ -n "$wrapper_entry" && "$wrapper_entry" != "null" ]]; then
                result=$(echo "$result" | jq --argjson entry "$wrapper_entry" '. + [$entry]')
                deferred_wrappers=$(echo "$deferred_wrappers" | jq --arg w "$emit_wrapper" 'del(.[$w])')
            fi
        done <<< "$wrappers_to_emit"

        i=$((i + 1))
    done

    local remaining_wrappers
    remaining_wrappers=$(echo "$deferred_wrappers" | jq -r 'keys[]?' 2>/dev/null) || true
    while IFS= read -r rw; do
        [[ -z "$rw" ]] && continue
        local rw_entry
        rw_entry=$(echo "$deferred_wrappers" | jq -c --arg w "$rw" '.[$w] // empty')
        if [[ -n "$rw_entry" && "$rw_entry" != "null" ]]; then
            result=$(echo "$result" | jq --argjson entry "$rw_entry" '. + [$entry]')
        fi
    done <<< "$remaining_wrappers"

    if [[ -n "$recursive_dir" && -d "$recursive_dir" ]]; then
        rm -rf "$recursive_dir"
    fi

    echo "$result"
}
