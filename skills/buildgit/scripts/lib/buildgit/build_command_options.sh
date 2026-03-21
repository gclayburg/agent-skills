_parse_build_options() {
    BUILD_NO_FOLLOW=false
    BUILD_LINE_MODE=false
    BUILD_PRIOR_JOBS=3
    _LINE_FORMAT_STRING="$_DEFAULT_LINE_FORMAT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            --no-follow)
                BUILD_NO_FOLLOW=true
                shift
                ;;
            --line)
                BUILD_LINE_MODE=true
                shift
                ;;
            --format)
                shift
                if [[ -z "${1:-}" ]]; then
                    _usage_error "--format requires a format string argument"
                fi
                _LINE_FORMAT_STRING="$1"
                BUILD_LINE_MODE=true
                shift
                ;;
            --format=*)
                _LINE_FORMAT_STRING="${1#--format=}"
                BUILD_LINE_MODE=true
                shift
                ;;
            --prior-jobs)
                shift
                BUILD_PRIOR_JOBS=$(_parse_prior_jobs_value "${1:-}" "--prior-jobs")
                shift
                ;;
            --prior-jobs=*)
                BUILD_PRIOR_JOBS=$(_parse_prior_jobs_value "${1#--prior-jobs=}" "--prior-jobs")
                shift
                ;;
            *)
                # Unknown option for build command
                _usage_error "Unknown option for build command: $1"
                ;;
        esac
    done
}

# Monitor triggered build until completion
# Arguments: job_name, build_number
# Returns: 0 on completion, 1 on error
# _build_monitor removed - consolidated into _monitor_build()
# Spec: unify-follow-log-spec.md, Implementation Requirements

# Build command handler
# Triggers a Jenkins build and monitors it until completion
# Spec reference: buildgit-spec.md, buildgit build
# Error handling: buildgit-spec.md, Error Handling section
