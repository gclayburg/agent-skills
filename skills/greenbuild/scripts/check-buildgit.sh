#!/usr/bin/env bash
#
# check-buildgit.sh
#
# Locate the buildgit skill installed next to greenbuild and check that it is
# new enough for the commands greenbuild tells the agent to run.
#
# Usage:
#   check-buildgit.sh [<path-to-buildgit-script>]
#
# Default path: <this skill>/../buildgit/scripts/buildgit
#
# Exit codes:
#   0  buildgit found and new enough; prints its absolute path
#   1  buildgit missing, unreadable, or older than GREENBUILD_MIN_BUILDGIT
#
# Spec: greenbuild-skill-spec.md § 2

set -uo pipefail

# First buildgit release with `buildgit wait`, exit code 4 for "no new
# build", and bail reports that target the failing downstream job.
GREENBUILD_MIN_BUILDGIT="1.4.15"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
buildgit_path="${1:-${script_dir}/../../buildgit/scripts/buildgit}"

if [[ ! -f "$buildgit_path" ]]; then
    echo "greenbuild: buildgit not found at ${buildgit_path}" >&2
    echo "Install the buildgit skill next to greenbuild (for example .agents/skills/buildgit)." >&2
    exit 1
fi

buildgit_dir="$(cd "$(dirname "$buildgit_path")" && pwd)"
buildgit_abs="${buildgit_dir}/$(basename "$buildgit_path")"

if ! version_output=$(bash "$buildgit_abs" --version); then
    echo "greenbuild: could not run buildgit at ${buildgit_abs}" >&2
    exit 1
fi
version_line="${version_output%%$'\n'*}"
version="${version_line#buildgit }"
core="${version%%-*}"

if ! [[ "$core" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "greenbuild: could not read the buildgit version from '${version_line}' (${buildgit_abs})" >&2
    exit 1
fi

# Compare MAJOR.MINOR.PATCH numerically; a prerelease suffix is ignored.
version_at_least() {
    local have="$1" want="$2"
    local h1 h2 h3 w1 w2 w3
    IFS='.' read -r h1 h2 h3 <<< "$have"
    IFS='.' read -r w1 w2 w3 <<< "$want"
    if (( h1 != w1 )); then (( h1 > w1 )); return; fi
    if (( h2 != w2 )); then (( h2 > w2 )); return; fi
    (( h3 >= w3 ))
}

if ! version_at_least "$core" "$GREENBUILD_MIN_BUILDGIT"; then
    echo "greenbuild: buildgit ${version} is older than ${GREENBUILD_MIN_BUILDGIT}, which greenbuild requires. Update the buildgit skill." >&2
    echo "  found: ${buildgit_abs}" >&2
    exit 1
fi

echo "buildgit ${version} OK (requires >= ${GREENBUILD_MIN_BUILDGIT}): ${buildgit_abs}"
exit 0
