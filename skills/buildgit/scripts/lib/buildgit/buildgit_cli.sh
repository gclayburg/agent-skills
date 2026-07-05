show_usage() {
    cat <<EOF
Usage: buildgit [global-options] <command> [command-options] [arguments]

A unified interface for git operations with Jenkins CI/CD integration.

Global Options:
  -j, --job <name>               Specify Jenkins job name (or multibranch job/branch)
  -c, --console <mode>           Show console log output (auto or line count)
  --threads [<format>]           Show live active-stage progress during TTY monitoring
  -h, --help                     Show this help message
  -v, --verbose                  Enable verbose output for debugging
  --version                      Show version number and exit

Commands:
  status [build#] [-f|--follow] [--once[=N]] [--probe-all] [-n <count>] [-r|--reverse] [-g|--gitlog[=<range>]] [--json] [--line] [--all] [--no-tests] [--format <fmt>] [--prior-jobs <N>] [--console-text [stage]] [--list-stages]
                      Display Jenkins build status (latest or specific build)
                      build# can be absolute (31) or relative (0=latest, -1=previous, -2=two ago)
                      Default: one-line output (TTY adds color), newest build first
  agents [--json] [--label <name>] [--nodes]
                      Show Jenkins executor capacity by label
  timing [build#] [--json] [--tests] [--by-stage] [--compare <a> <b>] [-n <count>]
                      Show per-stage and per-test-suite timing
  pipeline [build#] [--json]
                      Show pipeline structure (stages, parallelism, labels)
  queue [--json]
                      Show Jenkins build queue with wait reasons
  push [--no-follow] [--line] [--format <fmt>] [--prior-jobs <N>] [git-push-options] [remote] [branch]
                      Push commits and monitor Jenkins build
  build [--no-follow] [--line] [--format <fmt>] [--prior-jobs <N>]
                      Trigger and monitor Jenkins build
  <any-git-command>   Passed through to git

Examples:
Snapshot status of completed Jenkins build jobs:
  buildgit status                  # Jenkins build status snapshot
  buildgit status 31               # Status of build #31
  buildgit status --json           # JSON format for Jenkins status
  buildgit status --line           # One-line status with test results
  buildgit status -n 5 --line      # Last 5 builds, newest first, one line each
  buildgit status -n 5 --line -r   # Last 5 builds, oldest first
  buildgit status --line --gitlog  # All branch builds + git log (default: commits since repo default branch..HEAD)
  buildgit status -n 5 --line -g   # Last 5 builds + all commits in range
  buildgit status --line --gitlog=main..HEAD  # Custom git range
  buildgit status -n 10 --no-tests # Last 10 builds, skip test fetch
  buildgit status --prior-jobs 5   # Latest build + 5 prior one-line builds
  buildgit status --prior-jobs 5 201  # Build #201 + 5 prior one-line builds
  buildgit status --prior-jobs 0   # Latest build, suppress prior-jobs display
  buildgit status --list-stages    # List available pipeline stages
  buildgit status --console-text   # Raw full console text
  buildgit status 60 --console-text "Unit Tests D"  # Raw console for one stage
  buildgit status --all | less     # Full status piped to pager
  buildgit push --no-follow        # Push only, no monitoring

Monitor ongoing Jenkins build jobs:
  buildgit status -f               # Follow builds indefinitely
  buildgit status -f --once        # Follow current/next build, exit when done (10s timeout)
  buildgit status -f --once=20     # Same, but wait up to 20 seconds for build to start
  buildgit status -f --probe-all   # Follow next build on any branch
  buildgit status -f --probe-all --once   # Follow one build on any branch, then exit
  buildgit status -n 3 -f          # Show 3 prior builds, then follow indefinitely
  buildgit status -n 3 -f --once   # Show 3 prior builds, then follow once with timeout
  buildgit status -f --line        # Follow builds with one-line output + progress bar (TTY only)
  buildgit --threads status -f --line # Add active-stage progress rows above the main bar
  buildgit --threads '[%a] %S %p' status -f --line # Custom stage-row format
  buildgit status -f --once --line # Follow one build in one-line mode, then exit
  buildgit status -n 5 -f --line   # Show 5 prior one-line rows, then follow in one-line mode
  buildgit push                    # Push + monitor build
  buildgit push --prior-jobs 5     # Push + show last 5 builds before monitoring
  buildgit push --prior-jobs 0     # Push + suppress prior-jobs display
  buildgit push --line             # Push + compact one-line monitoring with progress bar
  buildgit --threads push          # Push + show live active-stage progress rows on TTY
  buildgit build --line            # Trigger + compact one-line monitoring with progress bar
  buildgit --threads build         # Trigger + show live active-stage progress rows on TTY
  buildgit status -f --prior-jobs 5  # Follow with last 5 builds shown first
  buildgit --job myjob build       # Trigger build for specific job
  buildgit --job myjob/main status # Query explicit multibranch branch job

Build optimization:
  buildgit agents                  # Executor capacity by label
  buildgit agents --nodes          # Executor capacity by node with all labels
  buildgit queue                   # Current Jenkins queue and wait reasons
  buildgit timing --tests          # Slowest stages and test suites for latest successful build
  buildgit timing --tests --by-stage # Group test suites under their parent pipeline stage
  buildgit timing --compare 40 42  # Compare stage timing and deltas across two builds
  buildgit timing -n 3             # Compact timing table for the last 3 builds
  buildgit pipeline 42 --json      # Pipeline graph and agent labels for build #42

Format placeholders for --format (use with --line):
  %s=status  %j=job  %n=build#  %t=tests  %d=duration
  %D=date  %I=iso8601  %r=relative  %c=commit  %b=branch  %%=literal%
  Default: "%s #%n id=%c Tests=%t Took %d on %I (%r)"

Threads format placeholders for --threads (TTY monitoring only):
  %a=agent  %S=stage  %g=progress-bar  %p=percent  %e=elapsed  %E=estimate  %%=literal%
  Width: %14a (max 14 chars, right-aligned), %-14a (left-aligned)
  Default: "  [%-14a] %S %g %p %e / %E"
  Env: BUILDGIT_THREADS_FORMAT

Passthrough:
  buildgit log --oneline -5        # Passed through to git

Environment Variables:
  JENKINS_URL         Base URL of the Jenkins server
  JENKINS_USER_ID     Jenkins username for API authentication
  JENKINS_API_TOKEN   Jenkins API token for authentication
EOF
}

_usage_error() {
    local msg="$1"
    log_error "$msg"
    echo "" >&2
    show_usage >&2
    exit 1
}

_parse_prior_jobs_value() {
    local value="$1"
    local option_name="${2:---prior-jobs}"
    if [[ -z "$value" ]]; then
        _usage_error "${option_name} requires a value"
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        _usage_error "${option_name} value must be a non-negative integer"
    fi
    echo "$value"
}

parse_global_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -j|--job)
                if [[ -z "${2:-}" ]]; then
                    _usage_error "Option $1 requires a job name"
                fi
                JOB_NAME="$2"
                shift 2
                ;;
            -c|--console)
                if [[ -z "${2:-}" ]]; then
                    _usage_error "Option $1 requires a mode (auto or line count)"
                fi
                if [[ "$2" != "auto" ]] && ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    _usage_error "Invalid console mode: $2 (must be 'auto' or a number)"
                fi
                CONSOLE_MODE="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            --threads)
                THREADS_MODE=true
                if [[ $# -gt 1 ]] && [[ "${2}" != -* ]]; then
                    case "$2" in
                        status|push|build)
                            shift
                            ;;
                        *)
                            _THREADS_FORMAT="$2"
                            shift 2
                            ;;
                    esac
                else
                    shift
                fi
                ;;
            -v|--verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --version)
                echo "buildgit ${BUILDGIT_VERSION}"
                exit 0
                ;;
            -*)
                # Unknown option before command - error
                _usage_error "Unknown global option: $1"
                ;;
            *)
                # First non-option is the command
                COMMAND="$1"
                shift
                # Remaining arguments are command arguments
                COMMAND_ARGS=("$@")
                return 0
                ;;
        esac
    done
}
