# buildgit — Full Command Reference

The `buildgit` script and its `lib/jenkins-common.sh` library are bundled in this skill package under `scripts/`. No separate installation is required.

## Usage

```
scripts/buildgit [global-options] <command> [command-options] [arguments]
```

## Global Options

| Option | Description |
|--------|-------------|
| `-j, --job <name>` | Specify Jenkins job name (overrides auto-detection) |
| `-h, --help` | Show help message |
| `--verbose` | Enable verbose output for debugging |

## Commands

### `buildgit status`

Display Jenkins build status.

**Options:**
- `-f, --follow` — Follow builds: monitor current build if in progress, then wait indefinitely for subsequent builds. Exit with Ctrl+C.
- `--json` — Output Jenkins status in JSON format

**Examples:**
```bash
buildgit status              # Jenkins build status snapshot
buildgit status -f           # Follow builds indefinitely
buildgit status --json       # JSON format for Jenkins status
buildgit --job myjob status --json  # Specific job, JSON output
```

**Example output (`buildgit status`):**
```
Jenkins Build Status: ralph1 #42
Result: SUCCESS
```

**Example output (`buildgit status --json`):**
```
{"result":"SUCCESS","building":false,"number":42,"url":"http://jenkins:8080/job/ralph1/42/", ...}
```

**Example output (`buildgit status -f`):**
```
Monitoring build ralph1 #42...
Stage: Build        ✓ (3s)
Stage: Test         ✓ (12s)
Stage: Deploy       RUNNING...
...
Build #42: SUCCESS

Waiting for next build of ralph1...
```

### `buildgit push`

Push commits to remote and monitor the resulting Jenkins build.

**Options:**
- `--no-follow` — Push only, do not monitor Jenkins build
- Other options are passed through to `git push`

**Notes:**
- Does not commit. Users should run: `git commit -m 'message' && buildgit push`
- If nothing to push, displays git's output and exits with git's exit code

**Examples:**
```bash
buildgit push                        # Push + monitor build
buildgit push --no-follow            # Push only, no monitoring
buildgit push origin featurebranch   # Push to specific remote/branch + monitor
buildgit --job myjob push            # Push with specific job
```

**Example output:**
```
[git push output]

Monitoring build ralph1 #43...
Stage: Build        ✓ (3s)
Stage: Test         ✓ (12s)
Build #43: SUCCESS
```

### `buildgit build`

Trigger a Jenkins build and monitor it until completion.

**Options:**
- `--no-follow` — Trigger build and confirm queued, then exit without monitoring

**Examples:**
```bash
buildgit build                       # Trigger + monitor build
buildgit build --no-follow           # Trigger only
buildgit --job myjob build           # Build specific job
```

### Git Passthrough

Any command not explicitly handled is passed through to `git`:

```bash
buildgit log --oneline -5    # Passes to: git log --oneline -5
buildgit diff HEAD~1         # Passes to: git diff HEAD~1
```

## Exit Codes

| Scenario | Exit Code |
|----------|-----------|
| Success (git OK, build OK) | 0 |
| Git command fails | Git's exit code |
| Jenkins build fails | 1 |
| Build is in progress (`status` command) | 2 |
| Nothing to push | Git's exit code |
| Jenkins unavailable during push | Non-zero (after git push completes) |

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| "Jenkins credentials not configured" | Missing env vars | Set `JENKINS_URL`, `JENKINS_USER_ID`, `JENKINS_API_TOKEN` |
| "Could not determine job name" | No `JOB_NAME` in CLAUDE.md and auto-detection failed | Add `JOB_NAME=<name>` to project CLAUDE.md or use `--job` flag |
| "Connection refused" | Jenkins server unreachable | Verify `JENKINS_URL` is correct and server is running |
| Build monitoring hangs | Network issue or build stuck | Ctrl+C to stop, check Jenkins web UI |

## Per-Project Configuration

Add to the project's `CLAUDE.md` or `AGENTS.md`:

```markdown
## Building on Jenkins CI server

- JOB_NAME=my-project
- You have env variables that represent the credentials for Jenkins:
  - JENKINS_URL
  - JENKINS_USER_ID
  - JENKINS_API_TOKEN
```
