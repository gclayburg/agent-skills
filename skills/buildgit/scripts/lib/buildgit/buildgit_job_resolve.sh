_get_current_git_branch() {
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
    if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
        return 1
    fi
    echo "$current_branch"
}

_normalize_branch_ref() {
    local ref="$1"
    ref="${ref#+}"

    # For refspecs, prefer destination branch when present.
    if [[ "$ref" == *:* ]]; then
        local src_ref dst_ref
        src_ref="${ref%%:*}"
        dst_ref="${ref#*:}"
        if [[ -n "$dst_ref" ]]; then
            ref="$dst_ref"
        elif [[ -n "$src_ref" ]]; then
            ref="$src_ref"
        fi
    fi

    ref="${ref#refs/heads/}"
    if [[ "$ref" == "HEAD" || -z "$ref" ]]; then
        _get_current_git_branch || return 1
    else
        echo "$ref"
    fi
}

_infer_push_branch_from_args() {
    local args=("${PUSH_GIT_ARGS[@]+"${PUSH_GIT_ARGS[@]}"}")
    local positionals=()
    local parse_positionals=false
    local arg

    # Bash 3.2 + set -u throws on iterating an empty array with "${arr[@]}".
    # No push args means no explicit refspec, so use current git branch.
    if [[ "${#args[@]}" -eq 0 ]]; then
        _get_current_git_branch || return 1
        return 0
    fi

    # Support common push syntax: git push [options] [remote] [refspec]
    for arg in "${args[@]}"; do
        if [[ "$arg" == "--" ]]; then
            parse_positionals=true
            continue
        fi
        if [[ "$parse_positionals" == "false" && "$arg" == -* ]]; then
            continue
        fi
        positionals+=("$arg")
    done

    # Branch/refspec is positional #2 when present.
    if [[ "${#positionals[@]}" -ge 2 ]]; then
        _normalize_branch_ref "${positionals[1]}" || return 1
        return 0
    fi

    _get_current_git_branch || return 1
}

_resolve_effective_job_name() {
    local requested_job_name="$1"
    local command_mode="${2:-status}"

    local top_job_name="$requested_job_name"
    local explicit_branch_name=""
    if [[ "$requested_job_name" == */* ]]; then
        top_job_name="${requested_job_name%%/*}"
        explicit_branch_name="${requested_job_name#*/}"
    fi

    if [[ -z "$top_job_name" ]]; then
        bg_log_error "Invalid Jenkins job name: '${requested_job_name}'"
        return 1
    fi

    local job_type
    job_type=$(get_jenkins_job_type "$top_job_name")
    if [[ "$job_type" == "unknown" || -z "$job_type" ]]; then
        # Backward-compatible fallback for Jenkins instances where _class
        # cannot be resolved from the API response.
        if [[ -n "$explicit_branch_name" ]]; then
            bg_log_error "Jenkins job '${requested_job_name}' not found"
            return 1
        fi
        echo "$top_job_name"
        return 0
    fi

    if [[ -n "$explicit_branch_name" ]]; then
        if [[ "$job_type" != "multibranch" ]]; then
            bg_log_error "Jenkins job '${requested_job_name}' not found"
            return 1
        fi
        if ! multibranch_branch_exists "$top_job_name" "$explicit_branch_name"; then
            bg_log_error "Branch '${explicit_branch_name}' not found in multibranch job '${top_job_name}'. Push the branch and wait for Jenkins to scan."
            return 1
        fi
        echo "${top_job_name}/${explicit_branch_name}"
        return 0
    fi

    if [[ "$job_type" == "multibranch" ]]; then
        if [[ "${STATUS_PROBE_ALL:-false}" == "true" && "$command_mode" == "status" ]]; then
            echo "$top_job_name"
            return 0
        fi

        local inferred_branch=""
        case "$command_mode" in
            push)
                inferred_branch=$(_infer_push_branch_from_args) || true
                ;;
            status|build)
                inferred_branch=$(_get_current_git_branch) || true
                ;;
            *)
                inferred_branch=$(_get_current_git_branch) || true
                ;;
        esac

        if [[ -z "$inferred_branch" ]]; then
            bg_log_error "Could not determine git branch for multibranch job '${top_job_name}'"
            return 1
        fi
        if ! multibranch_branch_exists "$top_job_name" "$inferred_branch"; then
            bg_log_error "Branch '${inferred_branch}' not found in multibranch job '${top_job_name}'. Push the branch and wait for Jenkins to scan."
            return 1
        fi
        echo "${top_job_name}/${inferred_branch}"
        return 0
    fi

    echo "$top_job_name"
}

_validate_jenkins_setup() {
    local context="$1"  # e.g., "monitor Jenkins builds", "trigger Jenkins build"
    local command_mode="${2:-status}"

    if ! validate_dependencies; then
        bg_log_error "Cannot ${context} - missing dependencies (jq, curl)"
        bg_log_essential "Suggestion: Install jq and curl, then retry"
        return 1
    fi

    if ! validate_environment; then
        bg_log_error "Cannot ${context} - environment not configured"
        bg_log_essential "Suggestion: Set JENKINS_URL, JENKINS_USER_ID, and JENKINS_API_TOKEN"
        return 1
    fi

    if [[ -n "$JOB_NAME" ]]; then
        _VALIDATED_JOB_NAME="$JOB_NAME"
        bg_log_info "Using specified job: $_VALIDATED_JOB_NAME"
    else
        bg_log_info "Discovering Jenkins job name..."
        if ! _VALIDATED_JOB_NAME=$(discover_job_name); then
            bg_log_error "Cannot ${context} - could not determine job name"
            bg_log_essential "Suggestion: Use -j/--job to specify job name"
            return 1
        fi
        bg_log_success "Job name: $_VALIDATED_JOB_NAME"
    fi

    bg_log_info "Verifying Jenkins connectivity..."
    if ! verify_jenkins_connection; then
        bg_log_error "Cannot ${context} - cannot connect to Jenkins"
        bg_log_essential "Suggestion: Check JENKINS_URL and credentials"
        return 1
    fi

    if ! _VALIDATED_JOB_NAME=$(_resolve_effective_job_name "$_VALIDATED_JOB_NAME" "$command_mode"); then
        bg_log_error "Cannot ${context} - could not resolve Jenkins job"
        bg_log_essential "Suggestion: Verify --job value and git branch"
        return 1
    fi

    if ! verify_job_exists "$_VALIDATED_JOB_NAME"; then
        bg_log_error "Cannot ${context} - job not found: $_VALIDATED_JOB_NAME"
        bg_log_essential "Suggestion: Verify job name with -j/--job option"
        return 1
    fi

    return 0
}
