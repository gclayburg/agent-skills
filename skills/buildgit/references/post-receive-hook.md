# Post-Receive Hook Contract

`buildgit push` can deterministically attach to the Jenkins build started by a git server post-receive hook when the hook prints the line formats below. These line formats are the contract between the producer (`scripts/buildme-multibranch.sh`) and the consumer (`scripts/buildgit`).

## Parsed Lines

`buildgit push` scans git push output for these signals, with an optional leading `remote:` prefix and tolerant whitespace:

| Signal | Canonical regex | Meaning |
| --- | --- | --- |
| Build started | `^[[:space:]]*(remote:[[:space:]]*)?Build[[:space:]]+started:[[:space:]]+(https?://[^[:space:]]+)[[:space:]]*$` | The queue item has resolved to a build URL. The trailing `/<digits>/?` path segment is used as the build number, and `buildgit push` skips its start-wait loop. |
| Queue cancelled | `^[[:space:]]*(remote:[[:space:]]*)?WARNING:[[:space:]]+Queue[[:space:]]+item[[:space:]]+([0-9]+)[[:space:]]+was[[:space:]]+CANCELLED(.*)$` | The server-side queue item was cancelled. `buildgit push` reports the item and reason, then exits non-zero. |
| Build queued | `^[[:space:]]*(remote:[[:space:]]*)?Build[[:space:]]+queued:[[:space:]]+(https?://[^[:space:]]*/queue/item/[0-9]+/?)[[:space:]]*$` | The queue item URL is passed to the Jenkins wait loop so it can poll `/queue/item/<id>/api/json` directly. |

Priority is: `Build started`, then `Queue item ... was CANCELLED`, then `Build queued`. If none of these lines are present, `buildgit push` falls back to polling the job's `lastBuild` and the general Jenkins queue.

## One-Time Server Setup

The reference hook script ships at `scripts/buildme-multibranch.sh` in this skill. Install it as the `post-receive` hook for the bare git repository on the git server:

```bash
cp scripts/buildme-multibranch.sh /path/to/repo.git/hooks/post-receive
chmod +x /path/to/repo.git/hooks/post-receive
```

The hook expects:

- Jenkins credentials as `user:pass` where `pass` is normally an API token.
- `JENKINS_URL`, such as `http://jenkins.example.com:8080`.
- The main Jenkins multibranch job name.
- Optional child multibranch job names that must discover new branches before the main build runs.

The hook usage is:

```bash
./buildme-multibranch.sh 'user:pass' 'http://jenkins:8080' 'mainjob' ['childjob1' ...]
```

Test it on the git server with synthetic post-receive input:

```bash
echo "0000000000000000000000000000000000000000 abc123 refs/heads/mybranch" | \
  ./buildme-multibranch.sh 'user:pass' 'http://jenkins:8080' 'mainjob' 'childjob1'
```

Confirm the output includes `Build queued: <queue-url>` and, when Jenkins resolves the queue quickly enough, `Build started: <build-url>`.

## Without This Hook

`buildgit push` still works without these hook lines, but it can only poll `lastBuild` and the general Jenkins queue. That fallback is less deterministic for multibranch jobs and may take the longer timeout path. Install the reference hook when reliable push-to-build detection matters.

## Troubleshooting

If `buildgit push` times out after seeing `Build queued: <url>`, it prints a diagnostic block with the polled job, baseline build, observed `lastBuild.number`, queue item probe status, and queue fields (`cancelled`, `why`, `executable.number`). Use that block to distinguish a stale job path, Jenkins API/network failure, cancelled queue item, or a queue item that resolved without the branch job's `lastBuild` refreshing.
