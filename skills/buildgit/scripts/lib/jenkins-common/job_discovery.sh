# =============================================================================
# Job Name Discovery Functions
# =============================================================================

# Build a Jenkins API path segment from a buildgit job name.
# Supported inputs:
#   pipeline:     myjob              -> /job/myjob
#   multibranch:  myjob/feature/x    -> /job/myjob/job/feature%2Fx
# Branch parsing uses the first slash as the separator: <job>/<branch>.
jenkins_job_path() {
    local job_name="$1"
    if [[ -z "$job_name" ]]; then
        echo ""
        return 1
    fi

    local top_job="$job_name"
    local branch_name=""
    if [[ "$job_name" == */* ]]; then
        top_job="${job_name%%/*}"
        branch_name="${job_name#*/}"
    fi

    if [[ -z "$top_job" ]]; then
        echo ""
        return 1
    fi

    local top_job_enc
    top_job_enc=$(printf '%s' "$top_job" | jq -sRr @uri 2>/dev/null)
    if [[ -z "$top_job_enc" || "$top_job_enc" == "null" ]]; then
        echo ""
        return 1
    fi

    if [[ -n "$branch_name" ]]; then
        local branch_name_enc
        branch_name_enc=$(printf '%s' "$branch_name" | jq -sRr @uri 2>/dev/null)
        if [[ -z "$branch_name_enc" || "$branch_name_enc" == "null" ]]; then
            echo ""
            return 1
        fi
        echo "/job/${top_job_enc}/job/${branch_name_enc}"
    else
        echo "/job/${top_job_enc}"
    fi
}

# Build Jenkins console URL for a job/build pair.
jenkins_console_url() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo ""
        return 1
    fi
    echo "${JENKINS_URL}${job_path}/${build_number}/console"
}

# Build Jenkins build URL for a job/build pair.
jenkins_build_url() {
    local job_name="$1"
    local build_number="$2"
    local job_path
    job_path=$(jenkins_job_path "$job_name")
    if [[ -z "$job_path" ]]; then
        echo ""
        return 1
    fi
    echo "${JENKINS_URL}${job_path}/${build_number}/"
}

# Cache for get_jenkins_job_type.
_JENKINS_JOB_TYPE_CACHE_JOB=""
_JENKINS_JOB_TYPE_CACHE_VALUE=""

# Detect top-level Jenkins job type.
# Returns one of: pipeline, multibranch, unknown
get_jenkins_job_type() {
    local top_job_name="$1"
    if [[ -z "$top_job_name" ]]; then
        echo "unknown"
        return 1
    fi

    if [[ "$_JENKINS_JOB_TYPE_CACHE_JOB" == "$top_job_name" && -n "$_JENKINS_JOB_TYPE_CACHE_VALUE" ]]; then
        echo "$_JENKINS_JOB_TYPE_CACHE_VALUE"
        return 0
    fi

    local top_job_path response class_name job_type
    top_job_path=$(jenkins_job_path "$top_job_name")
    if [[ -z "$top_job_path" ]]; then
        echo "unknown"
        return 1
    fi

    response=$(jenkins_api "${top_job_path}/api/json" 2>/dev/null) || true
    class_name=$(echo "$response" | jq -r '._class // empty' 2>/dev/null) || class_name=""

    job_type="unknown"
    case "$class_name" in
        org.jenkinsci.plugins.workflow.job.WorkflowJob)
            job_type="pipeline"
            ;;
        org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject)
            job_type="multibranch"
            ;;
    esac

    _JENKINS_JOB_TYPE_CACHE_JOB="$top_job_name"
    _JENKINS_JOB_TYPE_CACHE_VALUE="$job_type"
    echo "$job_type"
}

# Verify branch sub-job exists under a multibranch job.
# Usage: multibranch_branch_exists "top-job" "feature/name"
multibranch_branch_exists() {
    local top_job_name="$1"
    local branch_name="$2"
    if [[ -z "$top_job_name" || -z "$branch_name" ]]; then
        return 1
    fi

    local branch_job="${top_job_name}/${branch_name}"
    local branch_path response http_code
    branch_path=$(jenkins_job_path "$branch_job")
    if [[ -z "$branch_path" ]]; then
        return 1
    fi

    response=$(jenkins_api_with_status "${branch_path}/api/json")
    http_code=$(echo "$response" | tail -1)
    [[ "$http_code" == "200" ]]
}

# Discover Jenkins job name from AGENTS.md or git origin
# Priority: 1) AGENTS.md JOB_NAME, 2) git origin fallback
# Usage: discover_job_name
# Returns: Job name on stdout, returns 0 on success, 1 on failure
discover_job_name() {
    local job_name=""

    # Try AGENTS.md first
    job_name=$(_discover_job_from_agents_md)
    if [[ -n "$job_name" ]]; then
        echo "$job_name"
        return 0
    fi

    # Fallback to git origin
    job_name=$(_discover_job_from_git_origin)
    if [[ -n "$job_name" ]]; then
        echo "$job_name"
        return 0
    fi

    log_error "Could not determine Jenkins job name"
    log_info "Either create AGENTS.md with JOB_NAME=<job-name> or configure git origin"
    return 1
}

# Parse AGENTS.md for JOB_NAME pattern
# Flexible matching:
#   - JOB_NAME=myjob
#   - JOB_NAME = myjob
#   - - JOB_NAME=myjob
#   - Embedded in text: the job is JOB_NAME=myjob
# Returns: Job name or empty string
_discover_job_from_agents_md() {
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || return

    local agents_file="${git_root}/AGENTS.md"
    if [[ ! -f "$agents_file" ]]; then
        return
    fi

    # Extract JOB_NAME value with flexible matching
    # Pattern: JOB_NAME followed by optional whitespace, =, optional whitespace, then the value
    local job_name
    job_name=$(grep -oE 'JOB_NAME[[:space:]]*=[[:space:]]*[^[:space:]]+' "$agents_file" 2>/dev/null | head -1 | \
        sed -E 's/JOB_NAME[[:space:]]*=[[:space:]]*//')

    if [[ -n "$job_name" ]]; then
        echo "$job_name"
    fi
}

# Extract job name from git origin URL
# Supported formats:
#   - git@github.com:org/my-project.git → my-project
#   - https://github.com/org/my-project.git → my-project
#   - ssh://git@server:2233/home/git/ralph1.git → ralph1
#   - git@server:path/to/repo.git → repo
# Returns: Repository name (job name) or empty string
_discover_job_from_git_origin() {
    local origin_url
    origin_url=$(git remote get-url origin 2>/dev/null) || return

    local repo_name=""

    # Handle different URL formats
    if [[ "$origin_url" =~ ^https?:// ]]; then
        # HTTPS URL: https://github.com/org/my-project.git
        repo_name=$(basename "$origin_url")
    elif [[ "$origin_url" =~ ^ssh:// ]]; then
        # SSH URL with explicit protocol: ssh://git@server:2233/home/git/ralph1.git
        repo_name=$(basename "$origin_url")
    elif [[ "$origin_url" =~ ^git@ ]]; then
        # Git SSH shorthand: git@github.com:org/my-project.git or git@server:path/to/repo.git
        # Extract everything after the last / or :
        repo_name=$(echo "$origin_url" | sed -E 's|.*[:/]([^/]+)$|\1|')
    else
        # Unknown format, try basename
        repo_name=$(basename "$origin_url")
    fi

    # Strip .git suffix if present
    repo_name="${repo_name%.git}"

    if [[ -n "$repo_name" ]]; then
        echo "$repo_name"
    fi
}

# =============================================================================
