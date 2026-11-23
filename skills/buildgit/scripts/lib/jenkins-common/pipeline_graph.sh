# Adapt Pipeline Graph View to the stage tracker and the TTY renderer.
_get_live_pipeline_snapshot() {
    local job_name="$1" build_number="$2" ancestors="${3:-}"
    local job_key="${job_name//%/%25}"
    job_key="${job_key//\//%2F}"
    local finished="${BUILDGIT_CONSOLE_CACHE_DIR:+${BUILDGIT_CONSOLE_CACHE_DIR}/graph-${job_key}-${build_number}.done}"
    if [[ -n "$finished" && -f "$finished" ]]; then
        cat "$finished"
        return
    fi

    local BUILDGIT_HTTP_DEADLINE="${BUILDGIT_HTTP_DEADLINE:-$((EPOCHSECONDS + 8))}"
    local snapshot
    snapshot=$(_fetch_live_pipeline_snapshot "$job_name" "$build_number" "$ancestors" "$job_key" 2>/dev/null) || return 1
    if [[ -n "$finished" ]] && jq -e '.complete' <<< "$snapshot" >/dev/null; then
        printf '%s\n' "$snapshot" > "$finished"
    fi
    printf '%s\n' "$snapshot"
}

_fetch_live_pipeline_snapshot() {
    local job_name="$1" build_number="$2" ancestors="$3" job_key="$4"
    local legacy_marker="${BUILDGIT_CONSOLE_CACHE_DIR:+${BUILDGIT_CONSOLE_CACHE_DIR}/legacy-pipeline-${job_key}}"
    [[ -z "$legacy_marker" || ! -f "$legacy_marker" ]] || return 1

    local identity="$job_name #$build_number"
    [[ $'\n'"$ancestors"$'\n' != *$'\n'"$identity"$'\n'* ]] || return 1
    local job_path response http_code snapshot steps
    job_path=$(jenkins_job_path "$job_name")
    [[ -n "$job_path" ]] || return 1
    local BUILDGIT_HTTP_TIMEOUT=5
    response=$(jenkins_api_with_status "${job_path}/${build_number}/stages/tree" 2>/dev/null) || return 1
    http_code="${response##*$'\n'}"
    if [[ "$http_code" != 200 ]]; then
        if [[ "$http_code" == 404 && -n "$legacy_marker" ]]; then
            : > "$legacy_marker"
        fi
        return 1
    fi
    snapshot=$(_normalize_pipeline_graph <<< "${response%$'\n'*}") || return 1
    steps=$(jenkins_api "${job_path}/${build_number}/stages/allSteps" 2>/dev/null) || return 1
    if ! jq -e '.data.runIsComplete' <<< "$steps" >/dev/null; then
        snapshot=$(jq -c '.complete = false' <<< "$snapshot")
    fi
    local triggers
    triggers=$(jq -er '
        .data.steps | select(type == "array")
        | map(select((.name // "") | test("^Starting building:|build #[0-9]+ completed"; "i")))
        | group_by(.stageId)
        | map([(first.stageId // ""), (map(.id) | join("-"))] | join("\u001f")) | join("\n")
    ' <<< "$steps") || return 1
    if [[ -z "$triggers" ]]; then
        printf '%s\n' "$snapshot"
        return 0
    fi

    # The step metadata identifies the enclosing stage but does not expose a
    # usable downstream job URL. Resolve it from that stage's raw log only
    # when its set of build announcements changes.
    local stage_id step_ids stage_name log links link cache_file child_job child_build child_snapshot
    local children=""
    while IFS=$'\x1f' read -r stage_id step_ids; do
        [[ "$stage_id" =~ ^[0-9]+$ && "$step_ids" =~ ^[0-9]+(-[0-9]+)*$ ]] || return 1
        cache_file="${BUILDGIT_CONSOLE_CACHE_DIR:+${BUILDGIT_CONSOLE_CACHE_DIR}/graph-link-${job_key}-${build_number}-${stage_id}}"
        link=""
        if [[ -n "$cache_file" && -f "$cache_file" ]]; then
            local cached_steps cached_link
            IFS=$'\x1f' read -r cached_steps cached_link < "$cache_file"
            [[ "$cached_steps" != "$step_ids" ]] || link="$cached_link"
        fi
        if [[ -z "$link" ]]; then
            stage_name=$(jq -er --arg id "$stage_id" 'first(.nested[] | select(.id == $id) | .name)' <<< "$snapshot") || return 1
            log=$(_get_graph_stage_console_log "$job_path" "$build_number" "$stage_id") || return 1
            links=$(detect_all_downstream_builds "$log")
            link=$(_select_downstream_build_for_stage "${stage_name##*->}" "$links")
            [[ -n "$link" ]] || return 1
            if [[ -n "$cache_file" ]]; then
                printf '%s\x1f%s\n' "$step_ids" "$link" > "$cache_file"
            fi
        fi
        read -r child_job child_build <<< "$link"
        [[ -n "$child_job" && "$child_build" =~ ^[1-9][0-9]*$ ]] || return 1
        child_snapshot=$(_get_live_pipeline_snapshot "$child_job" "$child_build" "$ancestors"$'\n'"$identity") || return 1
        children+=$(jq -c --arg id "$stage_id" --arg job "$child_job" --argjson build "$child_build" \
            '{id: $id, job: $job, build: $build, nested, active, complete}' <<< "$child_snapshot")$'\n'
    done <<< "$triggers"

    {
        printf '%s\n' "$snapshot"
        printf '%s' "$children"
    } | jq -cs '
        def attach($parent; $link):
            .name = ($parent.name + "->" + .name)
            | .nesting_depth += 1
            | (.downstream_job //= $link.job) | (.downstream_build //= $link.build)
            | (.parent_stage //= $parent.name)
            | (.parallel_branch //= $parent.parallel_branch) | (.parallel_wrapper //= $parent.parallel_wrapper)
            | (.parallel_path //= $parent.parallel_path);
        .[0] as $root | (.[1:] | INDEX(.id)) as $links
        | $root
        | .complete = (.complete and all($links[]; .complete))
        | .nested |= [ .[] | . as $stage | ($links[$stage.id] // null) as $link
            | if $link == null then .
              else ($link.nested[] | attach($stage; $link)), (.has_downstream = true) end ]
        | .active = [ $root.nested[] | . as $stage | ($links[$stage.id] // null) as $link
            | ($link.active[]? | attach($stage; $link)),
              ($stage | select(.status == "IN_PROGRESS" and .graph_container == false)) ]
    '
}

_normalize_pipeline_graph() {
    jq -ce '
        def status:
            {running:"IN_PROGRESS", queued:"IN_PROGRESS", paused:"IN_PROGRESS",
             success:"SUCCESS", failure:"FAILED", unstable:"UNSTABLE", aborted:"ABORTED",
             skipped:"NOT_EXECUTED", not_built:"NOT_EXECUTED", unknown:"NOT_EXECUTED"}[.state];
        def children: (.children // []) | map(select(.placeholder != true));
        def visit($branch; $wrapper; $path; $agent):
            . as $node | children as $children
            | (if .synthetic and (.name | startswith("Declarative: ") | not) then "Declarative: " + .name
               else .name | sub("^Branch: "; "") end) as $name
            | (if $branch == "" or $branch == $name then $name else $branch + "->" + $name end) as $display
            | (.agent // $agent) as $nodeAgent
            | ([$children[] | select(.type == "PARALLEL")] | length > 0) as $wrapsParallel
            | if $wrapsParallel then
                  ($children | to_entries[]
                  | .key as $index | .value
                  | visit((.name | sub("^Branch: "; "")); $display; ($path + [($index + 1)]); $nodeAgent))
              else ($children[] | visit($branch; $wrapper; $path; $nodeAgent)) end,
              {id: ($node.id | tostring), name: $display, status: ($node | status),
               startTimeMillis: ($node.startTimeMillis // 0),
               durationMillis: (if ($node | status) == "IN_PROGRESS" then 0 else ($node.totalDurationMillis // 0) end),
               agent: $nodeAgent, nesting_depth: 0, has_downstream: false,
               graph_container: ($children | length > 0),
               graph_failed_child: any($children[]; .state == "failure")}
              + (if $wrapsParallel then {is_parallel_wrapper: true, parallel_branches: ($children | map(.name | sub("^Branch: "; "")))} else {} end)
              + (if $branch != "" then {parallel_branch: $branch, parallel_wrapper: $wrapper,
                  parallel_path: ($path | join("."))}
                    + (if $branch != $name then {parent_branch_stage: $branch} else {} end)
                 else {} end);
        (.data.complete == true) as $complete
        | .data.stages | select(type == "array")
        | [ .[] | select(.placeholder != true) | visit(""; ""; []; "") ] as $stages
        | select(all($stages[]; .status != null and .id != "null"))
        | {parent: $stages, nested: $stages, complete: $complete,
           active: [$stages[] | select(.status == "IN_PROGRESS" and .graph_container == false)]}
    '
}
