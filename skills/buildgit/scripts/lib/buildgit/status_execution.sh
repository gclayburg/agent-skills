# Fast one-line status output for snapshot mode.
# Arguments: job_name [start_build_number] [line_count] [no_tests] [prior_jobs_count] [reverse_mode]
# Returns: exit code always reflects the newest build (regardless of display order).
_status_line_check() {
    local job_name="$1"
    local start_build_number="${2:-}"
    local line_count="${3:-1}"
    local no_tests="${4:-false}"
    local prior_jobs_count="${5:-0}"
    local reverse_mode="${6:-false}"
    local first_build_number="$start_build_number"

    if [[ -z "$first_build_number" ]]; then
        first_build_number=$(get_last_build_number "$job_name")
        if [[ "$first_build_number" == "0" || -z "$first_build_number" ]]; then
            echo "Error: No builds found for job '${job_name}'" >&2
            return 1
        fi
    fi

    # Collect build numbers to print (newest to oldest), capping at available builds.
    # build_numbers[0] = newest, build_numbers[N-1] = oldest.
    local build_numbers=()
    local i=0
    while [[ "$i" -lt "$line_count" ]]; do
        local current_build_number=$((first_build_number - i))
        if [[ "$current_build_number" -lt 1 ]]; then
            break
        fi
        build_numbers+=("$current_build_number")
        i=$((i + 1))
    done

    # Validate that at least the newest build can be fetched.
    if [[ "${#build_numbers[@]}" -eq 0 ]]; then
        echo "Error: No builds found for job '${job_name}'" >&2
        return 1
    fi

    local newest_exit_code=1
    local total="${#build_numbers[@]}"
    local newest_bn="${build_numbers[0]}"

    if [[ "$reverse_mode" == "true" ]]; then
        # Oldest-first display: iterate j from N-1 down to 0.
        # Prior jobs block emitted right before the newest build (legacy layout).
        local j="$total"
        while [[ "$j" -gt 0 ]]; do
            j=$((j - 1))
            local bn="${build_numbers[$j]}"

            if [[ "$j" -eq 0 && "$prior_jobs_count" -gt 0 ]]; then
                local max_prior_build=$((bn - 1))
                _display_prior_jobs_block "$job_name" "$prior_jobs_count" "$no_tests" "$max_prior_build"
            fi

            local build_json
            build_json=$(get_build_info "$job_name" "$bn")
            if [[ -z "$build_json" ]]; then
                if [[ "$j" -eq 0 ]]; then
                    echo "Error: Failed to fetch build information" >&2
                    return 1
                fi
                continue
            fi

            local line_exit=1
            if _status_line_for_build_json "$job_name" "$bn" "$build_json" "$no_tests"; then
                line_exit=0
            fi
            if [[ "$j" -eq 0 ]]; then
                newest_exit_code="$line_exit"
            fi
        done
    else
        # Newest-first display (default): iterate j from 0 to N-1.
        # Prior jobs block emitted at the end (below the oldest -n row).
        local j=0
        while [[ "$j" -lt "$total" ]]; do
            local bn="${build_numbers[$j]}"

            local build_json
            build_json=$(get_build_info "$job_name" "$bn")
            if [[ -z "$build_json" ]]; then
                if [[ "$j" -eq 0 ]]; then
                    echo "Error: Failed to fetch build information" >&2
                    return 1
                fi
                j=$((j + 1))
                continue
            fi

            local line_exit=1
            if _status_line_for_build_json "$job_name" "$bn" "$build_json" "$no_tests"; then
                line_exit=0
            fi
            if [[ "$j" -eq 0 ]]; then
                newest_exit_code="$line_exit"
            fi
            j=$((j + 1))
        done

        if [[ "$prior_jobs_count" -gt 0 ]]; then
            local max_prior_build=$((newest_bn - 1))
            _display_prior_jobs_block "$job_name" "$prior_jobs_count" "$no_tests" "$max_prior_build"
        fi
    fi

    return "$newest_exit_code"
}

# Resolve status build reference to an absolute build number.
# Arguments: job_name, raw_build_ref
# Outputs: resolved absolute build number, or empty string for "latest"
# Returns: 0 on success, 1 on invalid/out-of-range reference
_resolve_status_build_number() {
    local job_name="$1"
    local raw_build_ref="${2:-}"

    if [[ -z "$raw_build_ref" ]]; then
        echo ""
        return 0
    fi

    # 0 and -0 mean "latest/current build"
    if [[ "$raw_build_ref" == "0" || "$raw_build_ref" == "-0" ]]; then
        echo ""
        return 0
    fi

    # Positive values are absolute build numbers
    if [[ "$raw_build_ref" =~ ^[1-9][0-9]*$ ]]; then
        echo "$raw_build_ref"
        return 0
    fi

    # Negative values are relative offsets from latest build number
    if [[ "$raw_build_ref" =~ ^-[0-9]+$ ]]; then
        local relative_offset="${raw_build_ref#-}"
        local latest_build_number
        latest_build_number=$(get_last_build_number "$job_name")
        if [[ "$latest_build_number" == "0" || -z "$latest_build_number" ]]; then
            echo "Error: No builds found for job '${job_name}'" >&2
            return 1
        fi

        local resolved_build_number=$((latest_build_number - relative_offset))
        if [[ "$resolved_build_number" -lt 1 ]]; then
            echo "Error: Relative build reference ${raw_build_ref} resolved to #${resolved_build_number} (must be >= 1)" >&2
            return 1
        fi

        echo "$resolved_build_number"
        return 0
    fi

    echo "Error: Invalid build number: ${raw_build_ref}" >&2
    return 1
}

# Snapshot status output for multiple builds.
# Default ordering: newest-first. Pass reverse_mode=true for oldest-first.
# Arguments: job_name, [start_build_number], [line_count], [json_mode], [prior_jobs_count], [no_tests], [reverse_mode]
# Returns: exit code always reflects the newest build (regardless of display order).
_status_multi_build_check() {
    local job_name="$1"
    local start_build_number="${2:-}"
    local line_count="${3:-1}"
    local json_mode="${4:-false}"
    local prior_jobs_count="${5:-0}"
    local no_tests="${6:-false}"
    local reverse_mode="${7:-false}"
    local first_build_number="$start_build_number"

    if [[ -z "$first_build_number" ]]; then
        first_build_number=$(get_last_build_number "$job_name")
        if [[ "$first_build_number" == "0" || -z "$first_build_number" ]]; then
            echo "Error: No builds found for job '${job_name}'" >&2
            return 1
        fi
    fi

    # build_numbers[0] = newest, build_numbers[N-1] = oldest.
    local build_numbers=()
    local i=0
    while [[ "$i" -lt "$line_count" ]]; do
        local current_build_number=$((first_build_number - i))
        if [[ "$current_build_number" -lt 1 ]]; then
            break
        fi
        build_numbers+=("$current_build_number")
        i=$((i + 1))
    done

    if [[ "${#build_numbers[@]}" -eq 0 ]]; then
        echo "Error: No builds found for job '${job_name}'" >&2
        return 1
    fi

    local newest_exit_code=1
    local total="${#build_numbers[@]}"
    local newest_bn="${build_numbers[0]}"
    local printed_any=false

    local start_idx end_idx step
    if [[ "$reverse_mode" == "true" ]]; then
        start_idx=$((total - 1))
        end_idx=-1
        step=-1
    else
        start_idx=0
        end_idx="$total"
        step=1
    fi

    local idx="$start_idx"
    while [[ "$idx" -ne "$end_idx" ]]; do
        # Emit prior jobs block right before newest in reverse mode
        if [[ "$reverse_mode" == "true" && "$idx" -eq 0 && "$json_mode" != "true" && "$prior_jobs_count" -gt 0 ]]; then
            local max_prior_build=$((newest_bn - 1))
            _display_prior_jobs_block "$job_name" "$prior_jobs_count" "$no_tests" "$max_prior_build"
            printed_any=true
        fi

        local bn="${build_numbers[$idx]}"
        local build_exit=1
        if [[ "$json_mode" == "true" ]]; then
            local json_object
            if json_object=$(_jenkins_status_check "$job_name" "true" "$bn"); then
                build_exit=0
            else
                build_exit=$?
            fi
            if [[ -n "$json_object" ]]; then
                local compact_json
                compact_json=$(printf "%s\n" "$json_object" | jq -c . 2>/dev/null || printf "%s\n" "$json_object")
                printf "%s\n" "$compact_json"
                printed_any=true
            fi
        else
            if [[ "$printed_any" == "true" ]]; then
                echo ""
            fi
            if _jenkins_status_check "$job_name" "false" "$bn"; then
                build_exit=0
            else
                build_exit=$?
            fi
            printed_any=true
        fi
        if [[ "$idx" -eq 0 ]]; then
            newest_exit_code="$build_exit"
        fi

        idx=$((idx + step))
    done

    # In default (newest-first) mode, emit prior jobs block AFTER the loop
    if [[ "$reverse_mode" != "true" && "$json_mode" != "true" && "$prior_jobs_count" -gt 0 ]]; then
        local max_prior_build=$((newest_bn - 1))
        _display_prior_jobs_block "$job_name" "$prior_jobs_count" "$no_tests" "$max_prior_build"
    fi

    return "$newest_exit_code"
}

# Strip ANSI / terminal control sequences from stdin or argument so that
# string length matches visible terminal width (for column math).
# - CSI SGR and friends: ESC [ ... final byte
# - ISO-2022 from tput (e.g. sgr0 -> ESC ( B): zero-width on common terminals)
#
# Note: BSD sed treats "(" after "\x1b" as starting a BRE group, not a literal
# "(". Use hex \x28 / \x29 for literal "(" / ")" so ESC ( B is actually removed.
_strip_ansi_escapes() {
    printf '%s' "$1" | sed \
        -e $'s/\x1b\\[[0-9:;?]*[A-Za-z]//g' \
        -e $'s/\x1b\x28[0-9A-Za-z]//g' \
        -e $'s/\x1b\x29[0-9A-Za-z]//g'
}

# Resolve the default gitlog range when none is provided.
# Prints the resolved range to stdout.
# Emits a warning to stderr when falling back to HEAD~20..HEAD.
_gitlog_resolve_default_range() {
    local origin_head_sym default_branch

    origin_head_sym=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -n "$origin_head_sym" ]]; then
        if [[ "$origin_head_sym" == refs/remotes/origin/* ]]; then
            default_branch="${origin_head_sym#refs/remotes/origin/}"
        elif [[ "$origin_head_sym" == refs/heads/* ]]; then
            default_branch="${origin_head_sym#refs/heads/}"
        else
            default_branch="$origin_head_sym"
        fi
        # Reject stale origin/HEAD (symref present but target ref missing).
        if [[ -n "$default_branch" ]] && git rev-parse --verify --quiet "$default_branch" >/dev/null 2>&1; then
            echo "${default_branch}..HEAD"
            return 0
        fi
    fi

    if git rev-parse --verify --quiet main >/dev/null 2>&1; then
        echo "main..HEAD"
        return 0
    fi

    if git rev-parse --verify --quiet master >/dev/null 2>&1; then
        echo "master..HEAD"
        return 0
    fi

    if [[ "${_GITLOG_WARNED_NO_DEFAULT_BRANCH:-0}" != "1" ]]; then
        echo "Warning: could not determine default branch for repo; showing last 20 commits. Use --gitlog=<range> to override." >&2
        _GITLOG_WARNED_NO_DEFAULT_BRANCH=1
    fi
    echo "HEAD~20..HEAD"
}

# 0-based terminal column of the first %c character in a rendered status line (ANSI stripped).
# Arguments: rendered_line, format_string, commit_short_sha (7 chars or unknown)
_gitlog_commit_column_for_interleave() {
    local rendered="$1"
    local fmt="$2"
    local bsha="$3"
    local stripped col search head prefix needle pre

    stripped=$(_strip_ansi_escapes "$rendered")
    col="-1"

    if [[ "$fmt" != *"%c"* ]]; then
        echo "-1"
        return 0
    fi

    if [[ "$fmt" == "$_DEFAULT_LINE_FORMAT" ]]; then
        needle="id=unknown"
        if [[ -n "$bsha" && "$bsha" != "unknown" ]]; then
            needle="id=${bsha}"
        fi
        if [[ "$stripped" == *"$needle"* ]]; then
            pre="${stripped%%$needle*}"
            col=$((${#pre} + 3))
        fi
        echo "$col"
        return 0
    fi

    search="$bsha"
    if [[ -n "$search" && "$search" != "unknown" ]]; then
        head="${stripped#*$search}"
        if [[ "$head" != "$stripped" ]]; then
            prefix="${stripped%%$search*}"
            col="${#prefix}"
        fi
    fi
    echo "$col"
}

# Interleave git log --oneline rows with one-line build status rows.
# Arguments:
#   job_name
#   start_build_number      (optional; empty = latest)
#   line_count              (N when n_set=true, otherwise unused)
#   no_tests
#   n_set                   ("true" if user passed -n)
#   range                   (optional; empty = default <default-branch>..HEAD)
# Returns: exit code reflects the newest build.
_status_gitlog_interleave() {
    local job_name="$1"
    local start_build_number="${2:-}"
    local line_count="${3:-1}"
    local no_tests="${4:-false}"
    local n_set="${5:-false}"
    local range="${6:-}"

    local effective_range="$range"
    if [[ -z "$effective_range" ]]; then
        effective_range=$(_gitlog_resolve_default_range)
    fi

    local gitlog_raw
    if ! gitlog_raw=$(git log --oneline --decorate "$effective_range" 2>&1); then
        echo "Error: git log failed for range '${effective_range}': ${gitlog_raw}" >&2
        return 1
    fi

    # Parse commits into parallel arrays (newest-first, as git log emits).
    local commit_shas=()
    local commit_lines=()
    local commit_consumed=()
    local commit_line
    while IFS= read -r commit_line; do
        [[ -z "$commit_line" ]] && continue
        local sha="${commit_line%% *}"
        commit_shas+=("$sha")
        commit_lines+=("$commit_line")
        commit_consumed+=("0")
    done <<< "$gitlog_raw"
    local total_commits="${#commit_shas[@]}"

    # Resolve the number of builds to fetch.
    local max_builds
    local using_ceiling=false
    if [[ "$n_set" == "true" ]]; then
        max_builds="$line_count"
    else
        max_builds="${BUILDGIT_GITLOG_MAX_BUILDS:-50}"
        using_ceiling=true
    fi

    local first_build_number="$start_build_number"
    if [[ -z "$first_build_number" ]]; then
        first_build_number=$(get_last_build_number "$job_name")
        if [[ "$first_build_number" == "0" || -z "$first_build_number" ]]; then
            echo "Error: No builds found for job '${job_name}'" >&2
            return 1
        fi
    fi

    # Collect builds newest-first: build_bns[i], build_jsons[i], build_shas[i], build_lines[i].
    local build_bns=()
    local build_jsons=()
    local build_shas=()
    local build_lines=()
    local build_columns=()
    local i=0
    while [[ "$i" -lt "$max_builds" ]]; do
        local bn=$((first_build_number - i))
        if [[ "$bn" -lt 1 ]]; then
            break
        fi
        local build_json
        build_json=$(get_build_info "$job_name" "$bn")
        if [[ -z "$build_json" ]]; then
            break
        fi
        _extract_git_info_from_build "$build_json"
        local bsha="$_LINE_COMMIT_SHA"

        local rendered line_exit=1
        if rendered=$(_status_line_for_build_json "$job_name" "$bn" "$build_json" "$no_tests"); then
            line_exit=0
        fi

        build_bns+=("$bn")
        build_jsons+=("$line_exit")
        build_shas+=("$bsha")
        build_lines+=("$rendered")

        # Compute column for commit alignment (per build row; see gitlog-mod-spec).
        local fmt="${_LINE_FORMAT_STRING:-${_DEFAULT_LINE_FORMAT}}"
        local col
        col=$(_gitlog_commit_column_for_interleave "$rendered" "$fmt" "$bsha")
        build_columns+=("$col")

        i=$((i + 1))
    done

    if [[ "${#build_bns[@]}" -eq 0 ]]; then
        echo "Error: No builds found for job '${job_name}'" >&2
        return 1
    fi

    # Warn on ceiling reached (no -n, fetched >= ceiling and more builds exist)
    if [[ "$using_ceiling" == "true" && "${#build_bns[@]}" -ge "$max_builds" ]]; then
        local oldest_fetched="${build_bns[$((${#build_bns[@]} - 1))]}"
        if [[ "$oldest_fetched" -gt 1 ]]; then
            echo "Warning: --gitlog capped at ${max_builds} builds (BUILDGIT_GITLOG_MAX_BUILDS). Use -n <count> to adjust." >&2
        fi
    fi

    local num_builds="${#build_bns[@]}"

    # Compute each build's commit index in the commit list (-1 if unknown or not found).
    local build_commit_idx=()
    local b=0
    while [[ "$b" -lt "$num_builds" ]]; do
        local this_sha="${build_shas[$b]}"
        local found="-1"
        if [[ "$this_sha" != "unknown" && -n "$this_sha" ]]; then
            local k=0
            while [[ "$k" -lt "$total_commits" ]]; do
                local csha="${commit_shas[$k]}"
                # Prefix match: csha must start with this_sha or vice versa
                if [[ "$csha" == "$this_sha"* || "$this_sha" == "$csha"* ]]; then
                    found="$k"
                    break
                fi
                k=$((k + 1))
            done
        fi
        build_commit_idx+=("$found")
        b=$((b + 1))
    done

    # Emit "newer than any build" commits ABOVE the first build,
    # but only if the newest build has a known, matched commit.
    local cursor=0
    if [[ "$num_builds" -gt 0 ]]; then
        local first_idx="${build_commit_idx[0]}"
        if [[ "$first_idx" != "-1" && "$first_idx" -gt 0 ]]; then
            local k=0
            while [[ "$k" -lt "$first_idx" ]]; do
                _gitlog_emit_indent_row "${build_columns[0]}" "${commit_lines[$k]}"
                commit_consumed[$k]=1
                k=$((k + 1))
            done
            cursor="$first_idx"
        fi
    fi

    # Walk builds newest-to-oldest.
    b=0
    while [[ "$b" -lt "$num_builds" ]]; do
        local bline="${build_lines[$b]}"
        printf '%s\n' "$bline"

        local col="${build_columns[$b]}"
        local this_idx="${build_commit_idx[$b]}"

        if [[ "$this_idx" != "-1" ]]; then
            # Emit the matched commit row (unless already consumed).
            if [[ "${commit_consumed[$this_idx]}" == "0" ]]; then
                _gitlog_emit_indent_row "$col" "${commit_lines[$this_idx]}"
                commit_consumed[$this_idx]=1
            fi
            if [[ "$this_idx" -ge "$cursor" ]]; then
                cursor=$((this_idx + 1))
            fi

            # Only emit "owned" extra commits if the NEXT build is also known;
            # otherwise let the unknown build(s) consume via positional fallback.
            local next_b=$((b + 1))
            if [[ "$next_b" -lt "$num_builds" ]]; then
                local next_build_idx="${build_commit_idx[$next_b]}"
                if [[ "$next_build_idx" != "-1" ]]; then
                    local kk=$((this_idx + 1))
                    while [[ "$kk" -lt "$next_build_idx" ]]; do
                        if [[ "${commit_consumed[$kk]}" == "0" ]]; then
                            _gitlog_emit_indent_row "$col" "${commit_lines[$kk]}"
                            commit_consumed[$kk]=1
                        fi
                        kk=$((kk + 1))
                    done
                    if [[ "$next_build_idx" -gt "$cursor" ]]; then
                        cursor="$next_build_idx"
                    fi
                fi
            fi
        else
            # Unknown SHA: positional fallback — consume the next unconsumed commit.
            local kk="$cursor"
            while [[ "$kk" -lt "$total_commits" ]]; do
                if [[ "${commit_consumed[$kk]}" == "0" ]]; then
                    _gitlog_emit_indent_row "$col" "${commit_lines[$kk]}"
                    commit_consumed[$kk]=1
                    cursor=$((kk + 1))
                    break
                fi
                kk=$((kk + 1))
            done
        fi

        b=$((b + 1))
    done

    # Emit any remaining unconsumed commits beneath the final build row.
    local trailing_col="${build_columns[$((num_builds - 1))]}"
    local kk=0
    while [[ "$kk" -lt "$total_commits" ]]; do
        if [[ "${commit_consumed[$kk]}" == "0" ]]; then
            _gitlog_emit_indent_row "$trailing_col" "${commit_lines[$kk]}"
            commit_consumed[$kk]=1
        fi
        kk=$((kk + 1))
    done

    # Exit code reflects newest build (index 0).
    return "${build_jsons[0]}"
}

# Emit an indented git log row beneath a build row.
# Arguments: column (-1 for default 5-space indent), commit_line
_gitlog_emit_indent_row() {
    local col="$1"
    local line="$2"
    local indent=""
    local target_col="$col"
    if [[ "$target_col" == "-1" || -z "$target_col" ]]; then
        target_col=5
    fi
    if [[ "$target_col" -gt 0 ]]; then
        indent=$(printf '%*s' "$target_col" '')
    fi
    printf '%s%s\n' "$indent" "$line"
}

# Extract trigger, commit, and correlation info from a build
# Usage: _extract_build_context "job-name" "build-number" ["build_json"] ["console_output"]
# Sets globals: _BC_TRIGGER_TYPE, _BC_TRIGGER_USER,
#               _BC_COMMIT_SHA, _BC_COMMIT_MSG, _BC_CORRELATION_STATUS
_extract_build_context() {
    local job_name="$1"
    local build_number="$2"
    local build_json="${3:-}"
    local console_output="${4:-}"

    if [[ -n "$build_json" && "${build_json#\{}" == "$build_json" ]]; then
        console_output="$build_json"
        build_json=""
    fi

    _BC_TRIGGER_TYPE="unknown"
    _BC_TRIGGER_USER="unknown"
    if [[ -n "$build_json" ]]; then
        local trigger_info
        trigger_info=$(detect_trigger_type_from_build_json "$build_json")
        local IFS=$'\n'
        set -- $trigger_info
        _BC_TRIGGER_TYPE="${1:-unknown}"
        _BC_TRIGGER_USER="${2:-unknown}"
    fi

    if [[ "$_BC_TRIGGER_TYPE" == "unknown" && -n "$console_output" ]]; then
        local trigger_info
        trigger_info=$(detect_trigger_type "$console_output")
        local IFS=$'\n'
        set -- $trigger_info
        _BC_TRIGGER_TYPE="${1:-unknown}"
        _BC_TRIGGER_USER="${2:-unknown}"
    fi

    # Extract triggering commit
    local commit_info
    commit_info=$(extract_triggering_commit "$job_name" "$build_number" "$build_json" "$console_output")
    local IFS=$'\n'
    set -- $commit_info
    _BC_COMMIT_SHA="${1:-unknown}"
    _BC_COMMIT_MSG="${2:-unknown}"

    # Correlate commit with local history
    _BC_CORRELATION_STATUS=$(correlate_commit "$_BC_COMMIT_SHA")
}

# Perform Jenkins status check and display
# Reuses logic from checkbuild.sh
# Arguments: job_name, json_mode [, build_number]
# Returns: exit code (0=success, 1=failure, 2=building)
_jenkins_status_check() {
    local job_name="$1"
    local json_mode="$2"
    local build_number="${3:-}"

    if [[ -n "$build_number" ]]; then
        bg_log_info "Fetching build #${build_number} information..."
    else
        # Get last build number
        bg_log_info "Fetching last build information..."
        build_number=$(get_last_build_number "$job_name")

        if [[ "$build_number" == "0" || -z "$build_number" ]]; then
            bg_log_error "No builds found for job '$job_name'"
            return 1
        fi
    fi

    # Get build info
    local build_json
    build_json=$(get_build_info "$job_name" "$build_number")

    if [[ -z "$build_json" ]]; then
        if [[ -n "${3:-}" ]]; then
            bg_log_error "Build #${build_number} not found for job '$job_name'"
        else
            bg_log_error "Failed to fetch build information"
        fi
        return 1
    fi

    # Extract build status
    local result building
    result=$(echo "$build_json" | jq -r '.result // "null"')
    building=$(echo "$build_json" | jq -r '.building // false')

    bg_log_success "Build #$build_number found"

    # Get console output for trigger detection and commit extraction
    bg_log_info "Analyzing build details..."
    local console_output
    console_output=$(get_console_output "$job_name" "$build_number" 2>/dev/null) || true

    # Extract trigger, commit, and correlation context
    _extract_build_context "$job_name" "$build_number" "$build_json" "$console_output"

    # Determine output based on build status
    local exit_code

    if [[ "$building" == "true" ]]; then
        # Build is in progress
        local current_stage
        current_stage=$(get_current_stage "$job_name" "$build_number" 2>/dev/null) || true

        if [[ "$json_mode" == "true" ]]; then
            output_json "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        else
            display_building_output "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$current_stage" \
                "$console_output"
        fi
        exit_code=2

    elif [[ "$result" == "SUCCESS" ]]; then
        # Build succeeded
        if [[ "$json_mode" == "true" ]]; then
            output_json "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        else
            display_success_output "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        fi
        exit_code=0

    else
        # Build failed (FAILURE, UNSTABLE, ABORTED, or other)
        if [[ "$json_mode" == "true" ]]; then
            output_json "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        else
            display_failure_output "$job_name" "$build_number" "$build_json" \
                "$_BC_TRIGGER_TYPE" "$_BC_TRIGGER_USER" \
                "$_BC_COMMIT_SHA" "$_BC_COMMIT_MSG" \
                "$_BC_CORRELATION_STATUS" "$console_output"
        fi
        exit_code=1
    fi

    return "$exit_code"
}
