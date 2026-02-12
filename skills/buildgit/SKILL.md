---
name: buildgit
description: Jenkins CI/CD build monitor. Check build status, push and monitor builds
---

# buildgit

A unified CLI for git operations with Jenkins CI/CD integration.

## Prerequisites

Before running any command, verify:
1. Jenkins env vars are set: `JENKINS_URL`, `JENKINS_USER_ID`, `JENKINS_API_TOKEN`
2. Project has `JOB_NAME=<name>` in its CLAUDE.md or AGENTS.md

If any prerequisite is missing, tell the user what's needed instead of attempting the command.

The `buildgit` script is bundled at `scripts/buildgit` within this skill package.

## Commands

| Command | Purpose |
|---------|---------|
| `scripts/buildgit status` | Jenkins build status snapshot |
| `scripts/buildgit status -f` | Follow builds in real-time (Ctrl+C to stop) |
| `scripts/buildgit status --json` | Machine-readable Jenkins build status |
| `scripts/buildgit push` | Push + monitor Jenkins build until complete |
| `scripts/buildgit push --no-follow` | Push only, no build monitoring |
| `scripts/buildgit build` | Trigger a new build + monitor until complete |
| `scripts/buildgit build --no-follow` | Trigger only, no monitoring |
| `scripts/buildgit --job <name> <cmd>` | Override auto-detected job name |

## Interpreting Output

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success (build passed, or git command succeeded) |
| 1 | Build failed, or an error occurred |
| 2 | Build is currently in progress |

**Build states:**
- `SUCCESS` — build passed, all tests green
- `FAILURE` — build failed; output includes failed stage and error details
- `BUILDING` — build is still running
- `ABORTED` — build was manually cancelled

For failures, summarize the failed stage name, error logs, and test failure details for the user.

## Dynamic Context

To inject live build state into context before reasoning about build issues:

```
!`scripts/buildgit status --json 2>/dev/null`
```

## Reference

See [references/reference.md](references/reference.md) for full command documentation, example output, and troubleshooting.
