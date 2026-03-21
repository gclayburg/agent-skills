#!/usr/bin/env bash

# Correlate JUnit suites to their parent wfapi stages.

fetch_stage_test_suites() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo "{}"
        return 0
    fi

    local response http_code body
    response=$(jenkins_api_with_status "${job_path}/${build_number}/testReport/api/json?tree=suites[name,duration,enclosingBlockNames,cases[status]]" || true)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
        echo "{}"
        return 0
    fi

    case "$http_code" in
        200)
            ;;
        404)
            echo "{}"
            return 0
            ;;
        *)
            echo "{}"
            return 0
            ;;
    esac

    local result_json
    result_json=$(printf '%s\n' "$body" | jq -c '
        [.suites[]? | {
            name: (.name // ""),
            durationMs: (((.duration // 0) * 1000) | floor),
            tests: ((.cases // []) | length),
            failures: ((.cases // []) | map(select(.status == "FAILED" or .status == "REGRESSION")) | length),
            stage: ((.enclosingBlockNames // []) | first // "")
        }]
        | map(select(.stage != "" and .tests > 0))
        | group_by(.stage)
        | map({
            (.[0].stage): (map({name, durationMs, tests, failures}) | sort_by(.durationMs) | reverse)
        })
        | add // {}
    ' 2>/dev/null) || result_json="{}"

    if [[ -z "$result_json" || "$result_json" == "null" ]]; then
        echo "{}"
        return 0
    fi

    echo "$result_json"
}
