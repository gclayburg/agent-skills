#!/bin/bash
# buildme-multibranch.sh    Smart Jenkins multibranch pipeline trigger for use as a git post-receive hook
#
# For NEW branches:
#   1. Scans all child multibranch jobs so they discover the branch.
#      Child Jenkinsfiles guard against BranchIndexingCause so no real build runs.
#   2. Scans the main job to discover the branch (which also queues a
#      scan-triggered BranchIndexingCause build).
#   3. Waits for all branch jobs to exist and for the main scan to finish.
#   4. Explicitly triggers the main branch build.  The explicit trigger merges
#      with the scan-triggered build in the Jenkins queue, giving the resulting
#      build two causes (BranchIndexingCause + UserIdCause).  The main
#      Jenkinsfile guard skips only single-cause BranchIndexingCause builds,
#      so this merged build proceeds normally.
#
# For EXISTING branches:
#   Triggers only the main job's specific branch build (no scan needed).
#
# Usage as post-receive hook (reads oldrev/newrev/refname from stdin):
#   ./buildme-multibranch.sh 'user:pass' 'http://jenkins:8080' 'mainjob' ['childjob1' ...]
#
# Manual trigger (no stdin — forces scan of all jobs):
#   echo "0000000000000000000000000000000000000000 abc123 refs/heads/mybranch" | \
#     ./buildme-multibranch.sh 'user:pass' 'http://jenkins:8080' 'mainjob' 'childjob1'

USERPASSWORD="$1"
SERVER="$2"
shift 2

MAINJOB="$1"
shift
CHILDJOBS=("$@")

if [[ -z "$MAINJOB" ]]; then
  echo "Usage: $0 'user:pass' 'http://jenkins:8080' mainjob [childjob1 ...]" >&2
  exit 1
fi

ZERO_REV="0000000000000000000000000000000000000000"

# Encode branch name for Jenkins URL: / becomes %2F
encode_branch() {
  local branch="$1"
  echo "${branch//\//%2F}"
}

# File where web session cookie is saved
COOKIEJAR="$(mktemp)"
cleanup() { rm -f "$COOKIEJAR"; }
trap cleanup EXIT

CRUMB=$(curl --silent --show-error -f -u "$USERPASSWORD" --cookie-jar "$COOKIEJAR" \
  "$SERVER/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
if [[ $? -ne 0 ]]; then
  echo "Failed to obtain Jenkins crumb" >&2
  exit 1
fi

# Trigger a multibranch scan (discovers branches, may trigger builds)
trigger_scan() {
  local job="$1"
  echo "Scanning multibranch job: $job"
  curl --silent --show-error -f -X POST -u "$USERPASSWORD" --cookie "$COOKIEJAR" -H "$CRUMB" \
    "$SERVER/job/$job/build"
}

# Check if a branch job exists in a multibranch project
branch_exists() {
  local job="$1"
  local branch="$2"
  local encoded
  encoded=$(encode_branch "$branch")
  curl --silent --fail -u "$USERPASSWORD" --cookie "$COOKIEJAR" \
    "$SERVER/job/$job/job/$encoded/api/json" >/dev/null 2>&1
}

# Wait for multibranch scan log to show "Finished:" line (scan complete)
# Uses the progressive log text endpoint which is reliably available
wait_for_indexing_complete() {
  local job="$1"
  local max_wait="${2:-60}"
  local interval=2
  local elapsed=0
  local log_text

  while true; do
    log_text=$(curl --silent --fail -u "$USERPASSWORD" --cookie "$COOKIEJAR" \
      "$SERVER/job/$job/indexing/logText/progressiveText?start=0" 2>/dev/null) || true

    if [[ -z "$log_text" ]]; then
      echo "WARNING: Could not read indexing log for '$job'; continuing" >&2
      return 0
    fi

    if [[ "$log_text" == *"Finished:"* ]]; then
      return 0
    fi

    if [[ $elapsed -ge $max_wait ]]; then
      echo "WARNING: Timed out waiting for indexing log completion in '$job' after ${max_wait}s" >&2
      return 1
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
  done
}

# Wait for a branch to appear in a multibranch job (up to timeout)
wait_for_branch() {
  local job="$1"
  local branch="$2"
  local max_wait="${3:-60}"
  local interval=3
  local elapsed=0

  while ! branch_exists "$job" "$branch"; do
    if [[ $elapsed -ge $max_wait ]]; then
      echo "WARNING: Timed out waiting for branch '$branch' in job '$job' after ${max_wait}s" >&2
      return 1
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  return 0
}


# Trigger a specific branch build and verify Jenkins accepted it into the queue.
# Does NOT wait for the build to start — that can take arbitrarily long
# and would cause the git push HTTP connection to time out.
# On success, prints the Jenkins queue item URL for reference.
# Retries once if the first trigger returns no queue item.
trigger_branch_build_verified() {
  local job="$1"
  local branch="$2"
  local encoded
  local headers
  local http_status
  local queue_url

  encoded=$(encode_branch "$branch")

  _do_trigger() {
    headers="$(mktemp)"
    http_status=$(curl --silent --show-error -w "%{http_code}" \
      -X POST -D "$headers" -o /dev/null \
      -u "$USERPASSWORD" --cookie "$COOKIEJAR" -H "$CRUMB" \
      "$SERVER/job/$job/job/$encoded/build" 2>/dev/null)
    queue_url=$(awk 'BEGIN{IGNORECASE=1} /^Location:/ {print $2}' "$headers" | tr -d '\r' | tail -n 1)
    rm -f "$headers"
  }

  echo "Triggering build: $job/$branch"
  _do_trigger

  if [[ "$http_status" == 4* ]] || [[ "$http_status" == 5* ]]; then
    echo "ERROR: Jenkins rejected trigger for $job/$branch (HTTP $http_status)" >&2
    return 1
  fi

  if [[ -z "$queue_url" ]]; then
    echo "WARNING: No queue item returned (HTTP $http_status) — retrying in 5s" >&2
    sleep 5
    _do_trigger
  fi

  if [[ -z "$queue_url" ]]; then
    echo "ERROR: Jenkins did not create a queue item for $job/$branch (HTTP $http_status)" >&2
    echo "  Check $SERVER/job/$job/job/$encoded/ for existing builds or config issues" >&2
    return 1
  fi

  echo "Build queued: $queue_url"

  # Brief diagnostic: check queue item state after a short wait so we can
  # report whether Jenkins ran, cancelled, or blocked the queued build.
  sleep 5
  local queue_id="${queue_url%/}"
  queue_id="${queue_id##*/}"
  local qjson
  qjson=$(curl --silent --fail -u "$USERPASSWORD" --cookie "$COOKIEJAR" \
    "$SERVER/queue/item/$queue_id/api/json" 2>/dev/null) || true

  if [[ -z "$qjson" ]]; then
    echo "Queue item $queue_id already gone after 5s (ran or was cancelled)"
  elif [[ "$qjson" == *'"cancelled":true'* ]]; then
    local why
    why=$(printf '%s' "$qjson" | grep -o '"why":"[^"]*"' | head -1)
    echo "WARNING: Queue item $queue_id was CANCELLED ($why)" >&2
  elif [[ "$qjson" == *'"executable"'* ]]; then
    local build_url
    build_url=$(printf '%s' "$qjson" | grep -o '"url":"[^"]*"' | tail -1 | cut -d'"' -f4)
    echo "Build started: $build_url"
  else
    local why
    why=$(printf '%s' "$qjson" | grep -o '"why":"[^"]*"' | head -1)
    echo "Queue item $queue_id still waiting after 5s ($why)"
  fi

  return 0
}

# Read post-receive hook input from stdin
# Collect unique branches and whether any are new. Keep this bash 3.2 compatible
# for macOS agents, so use newline-delimited sets instead of associative arrays.
NEW_BRANCHES=""
EXISTING_BRANCHES=""
HAS_INPUT=false

branch_set_contains() {
  local set="$1"
  local branch="$2"
  [[ "
$set
" == *"
$branch
"* ]]
}

branch_set_add() {
  local set="$1"
  local branch="$2"
  if branch_set_contains "$set" "$branch"; then
    printf '%s' "$set"
  elif [[ -n "$set" ]]; then
    printf '%s\n%s' "$set" "$branch"
  else
    printf '%s' "$branch"
  fi
}

while read -t 1 oldrev newrev refname; do
  HAS_INPUT=true
  # Skip tag pushes and branch deletions
  if [[ "$refname" != refs/heads/* ]] || [[ "$newrev" == "$ZERO_REV" ]]; then
    continue
  fi
  branch="${refname#refs/heads/}"
  if [[ "$oldrev" == "$ZERO_REV" ]]; then
    NEW_BRANCHES=$(branch_set_add "$NEW_BRANCHES" "$branch")
  else
    EXISTING_BRANCHES=$(branch_set_add "$EXISTING_BRANCHES" "$branch")
  fi
done

# If no stdin (manual invocation), fall back to scanning all jobs
if [[ "$HAS_INPUT" == false ]]; then
  echo "No post-receive input detected, scanning all jobs"
  for JOB in "$MAINJOB" "${CHILDJOBS[@]}"; do
    trigger_scan "$JOB"
    if [[ $? -ne 0 ]]; then
      echo "Failed to trigger scan for job: $JOB" >&2
      exit 1
    fi
  done
  exit 0
fi

# Process new branches: scan children first, then scan main job
while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  echo "New branch detected: $branch"

  # Scan child jobs so they discover the new branch
  # (BranchIndexingCause guard in child Jenkinsfiles prevents actual builds)
  for CHILD in "${CHILDJOBS[@]}"; do
    trigger_scan "$CHILD"
    if [[ $? -ne 0 ]]; then
      echo "WARNING: Failed to scan child job: $CHILD" >&2
    fi
  done

  # Scan the main job to discover the new branch
  # (BranchIndexingCause guard in Jenkinsfile prevents auto-build from scan)
  trigger_scan "$MAINJOB"
  if [[ $? -ne 0 ]]; then
    echo "Failed to scan main job: $MAINJOB" >&2
    exit 1
  fi

  # Wait for the branch to appear in all jobs so the main pipeline
  # can call child jobs without "no such project" errors
  wait_for_branch "$MAINJOB" "$branch"
  for CHILD in "${CHILDJOBS[@]}"; do
    wait_for_branch "$CHILD" "$branch"
  done

  # Wait for the main scan to fully finish before triggering a build.
  # This ensures all branch jobs are created before we fire the explicit trigger.
  wait_for_indexing_complete "$MAINJOB"

  # Explicitly trigger the main branch build.  This merges with the
  # scan-triggered BranchIndexingCause queue item, producing a two-cause
  # build that the main Jenkinsfile guard allows through.
  trigger_branch_build_verified "$MAINJOB" "$branch"
  if [[ $? -ne 0 ]]; then
    echo "Failed to trigger build for $MAINJOB/$branch" >&2
    exit 1
  fi
done <<EOF
$NEW_BRANCHES
EOF

# Process existing branches: trigger only the main job's specific branch build
while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  # Skip if this branch was also handled as new (shouldn't happen, but be safe)
  if branch_set_contains "$NEW_BRANCHES" "$branch"; then
    continue
  fi
  trigger_branch_build_verified "$MAINJOB" "$branch"
  if [[ $? -ne 0 ]]; then
    echo "Failed to trigger build for $MAINJOB/$branch" >&2
    exit 1
  fi
done <<EOF
$EXISTING_BRANCHES
EOF

exit 0
