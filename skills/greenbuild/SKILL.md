---
name: greenbuild
description: Commit the changes made by the current thread, wait for this branch's in-flight Jenkins work to finish, push the branch, and drive that exact commit to a green Jenkins build. Diagnose and fix failures, commit each fix, and repeat until SUCCESS. Requires the buildgit skill (1.4.15 or newer) installed next to this one. Use whenever the user invokes "/greenbuild" or says "greenbuild", "make the build green", "commit and push once Jenkins is free", "fix the build until it passes", "keep fixing until CI is green", or "check the build and fix anything broken".
license: MIT
metadata:
  requires: buildgit >= 1.4.15
---

# greenbuild

Ship the current thread's work to Jenkins and loop until the build for the resulting commit is green. This skill orchestrates careful git scoping, the `buildgit` skill, code edits, verification, commits, and Jenkins monitoring. It works for any git repository whose pushes are built by Jenkins and monitored with buildgit.

Paths in this document are relative to this SKILL.md's directory unless they say otherwise. Below, `buildgit` means the buildgit skill's script, `../buildgit/scripts/buildgit` from this directory. Run it by that full path, from the repository root.

## Workflow

Run the full workflow for a bare `/greenbuild` invocation. Do not stop merely because an older build is green: success means the current `HEAD` is the commit Jenkins built successfully.

1. **Check and load buildgit** — run `scripts/check-buildgit.sh`. It prints the buildgit path and exits 0 when the buildgit skill next to this one is new enough; otherwise stop and report its message (the user must update or install the buildgit skill). Then read `../buildgit/SKILL.md` completely before running any buildgit command. Its command and monitoring rules are authoritative.

2. **Learn the project's rules** — read the repository's `AGENTS.md` / `CLAUDE.md` (and module-level ones for the code you touch) for its branch and commit policy, commit-message conventions, and testing and bugfix rules. Do not hard-code Jenkins job names: buildgit finds the job from the project's `JOB_NAME=` line in `AGENTS.md` (or the git origin) and adds the current branch for a multibranch job. Pass `--job` only when the project's instructions say to.

3. **Inventory and protect the worktree** — inspect the current branch with `git status`, `git diff`, and `git diff --cached`.
   - Use the conversation and tool history to identify every uncommitted file or hunk changed by the current thread.
   - Preserve unrelated user changes. Do not reset, delete, stash, or commit work that the thread did not make.
   - If thread-owned and unrelated work overlap in a file, stage only the attributable hunks. If ownership cannot be determined safely, ask the user before committing that ambiguous work.
   - Invoking greenbuild is the user's explicit request to commit this thread's changes and push the current branch, including the resolution of an already-started merge the user asked you to resolve, and to commit fixes for failures Jenkins reports during this workflow. That covers repositories that allow commits or pushes on their default branch only when the user asks. It never authorizes starting a new merge, rebasing, force-pushing, or committing unrelated work. If the repository's rules forbid committing or pushing on this branch even on request, stop and ask.

4. **Verify and commit all thread-owned changes** — run the relevant local checks in proportion to the changes, then commit everything attributable to the current thread.
   - Stage only the identified files or hunks; never use `git add -A` or `git add .`.
   - Review `git diff --cached` before committing so no thread-owned work is omitted and no unrelated work is included.
   - Write a cohesive commit message from the actual diff, following the project's conventions (including any required `Co-Authored-By` trailer). Pass multi-line messages on stdin (`git commit -F -`).
   - Never amend an existing commit. If there are no uncommitted thread-owned changes, do not create an empty commit; continue with any existing unpushed commits.

5. **Wait for this branch's builds** — do this before every push. Builds of other branches may run alongside yours, and Jenkins queues what it cannot run yet. Wait only for this branch; never wait for the whole server to go idle.
   - Run `buildgit wait --queue`. It waits until this branch's latest build has finished and nothing for this branch is queued, then prints that build's one-line result. It never bails on a failed stage and never waits for a new build, so it returns within about 5 seconds of the branch going idle. For a multibranch pipeline, the root build waits for its downstream jobs, so the root build finishing means the branch is idle.
   - Exit 0 or 1 means the branch is idle (the last build passed or failed): go ahead and push. Exit 4 means the branch has no builds yet: push. Exit 2 only happens with `--timeout`.
   - Do not build this wait out of `status -f --once`: without `--no-bail-on-red` it returns exit 3 at once on a build that already has a failed stage, and `--once=N` on a finished build waits N seconds for a new build. Do not poll `agents --nodes` for this; it is slow and adds nothing.
   - Never send buildgit output to `/dev/null`; keep it, with its timestamps, in a scratchpad log so the timing can be reviewed.
   - Never cancel or interrupt any build to make room, including another branch's. Treat an unreachable Jenkins service, an offline agent, or this branch's build stuck in the queue well past the time other builds take as an infrastructure blocker and report it.
   - A build of this branch still running after a bail-on-red exit counts as busy. Bail-on-red stops monitoring, not the build. Do not relax this gate to get a fix in sooner, and do not cancel the doomed build.

6. **Push and monitor** — if commits need to be pushed, run `buildgit push`. It runs `git push` (to the branch's upstream) and follows the resulting build in one command. Do not chain `status -f` after it.
   - If the branch has no upstream yet (`git rev-parse --abbrev-ref @{u}` fails), push it once with `buildgit push -u origin HEAD`.
   - Monitoring stops the moment a stage fails (bail-on-red, exit 3) instead of waiting for the rest of the pipeline. Start diagnosing immediately; do not wait for the build to finish and do not cancel it.
   - **On exit 3, start `buildgit wait --queue` as a background command at once**, before diagnosing. Diagnose and fix while it runs. When both the fix is committed and the wait has returned, push right away. Never wait serially after the fix.
   - If there is nothing to push, check whether Jenkins already has a completed build for the current `HEAD`.
   - Judge `HEAD` by its **most recent** build (`buildgit status --line -n 5`), not by an older green build of the same commit. If that most recent build is `SUCCESS`, report completion.
   - If the most recent build of `HEAD` is a failure, do not stop at reporting it, and do not call an earlier green build of the same commit "done". Go to step 7 and drive the commit to a fresh green build. A failure that looks like a flaky test is still a defect to fix.
   - If the current `HEAD` has not been built, run `buildgit build`.
   - Run `push` and `build` from the repository root, and do not pipe them into `tail`, `head`, `grep`, or `tee`. A pipeline exits with its last command's code, so a bail (exit 3) or a failure (exit 1) reads as 0, a green build. If you must trim the output, end the command with `; exit ${PIPESTATUS[0]}`.
   - Interpret the exit code:

     | Exit | Meaning | Next step |
     |------|---------|-----------|
     | 0 | Build passed | Report completion |
     | 3 | A stage failed; the build is still running | Start `buildgit wait --queue` in the background, go to step 7 — the verdict is already known |
     | 1 | Build failed, or an error occurred | Go to step 7 |
     | 2 | Still in progress (monitoring capped by `MAX_BUILD_TIME`) | `buildgit wait`, then judge the result |

7. **Classify the failure before deciding what to do** — read the `classification` field, which the bail report prints and `buildgit status --json` exposes.
   - **`infra`** — a CI fault (docker agent, registry, disk), not a defect in the code. Do **not** edit anything. Retry the same commit once with `buildgit build`, after the same-branch wait in step 5.
     - **One retry per commit, never more.** If the retry also reports `infra`, stop and report an infrastructure blocker per the stop conditions. A persistently sick agent must surface, not silently consume CI capacity in a loop.
     - Say explicitly in the final report that a retry was spent and why.
   - **`code`** — a real defect. Continue to step 8. This includes a suspected flaky test (a hook or test timeout, an intermittent assertion, or a build that passed on the same commit): do not dismiss it as noise or merely report it. Diagnose the nondeterminism, fix the test (keep what it verifies; leave product behavior unchanged unless the flake is a product race), and drive the build to green. Retriggering without a fix is allowed only for `infra`.
   - **`unknown`** — could not be attributed. Inspect manually before choosing; do not spend the infra retry on a guess.

8. **Diagnose a non-green result** — gather enough detail to fix the failure.
   - When you arrived here via exit code 3, **the build may still be running**. Target the stage the bail report named rather than assuming a completed build, and expect test reports to be incomplete.
   - The bail report ends with ready-to-run commands. Run them as printed:
     - `Stage log:` prints the failing stage's console. When the stage runs in a downstream job, the report says `Failing job: <job> #N, stage '<name>'` and the command already targets that job.
     - `Failed tests:` (`buildgit --job <job> status <N> --json`) gives `failure.root_cause_job` and `test_results.failed_tests` with stack traces. Run it once the build has finished (or again then, if it ran while tests were still missing). One call; do not also run `status <N> --all`.
   - A full stage path such as `A->B->C` also works directly: `buildgit status <N> --console-text 'A->B->C'` reads the stage from the downstream job that runs it.
   - Other useful commands: `buildgit -v status --json` for untruncated failed-test stdout; `buildgit status --list-stages` then `buildgit status --console-text <stage>`; `buildgit --console auto status` for a curated error summary.

9. **Fix and verify** — edit the offending code or tests in this repository, following the repository's testing and bugfix rules (for example a test-first bugfix procedure). Prove the failure locally where practical, implement the fix, and run focused plus proportionate broader verification.

10. **Commit the fix** — stage only the fix files or hunks, review the staged diff, and create a new commit using the commit rules from step 4. Never amend or fold unrelated work into the fix.

11. **Loop** — return to the same-branch wait in step 5, then push and monitor again. Continue until Jenkins reports `SUCCESS` for the current `HEAD` or a stop condition applies.

## Stop conditions

- The most recent Jenkins build for the current `HEAD` is `SUCCESS` → done. An earlier green build does not count when a later build of the same commit failed.
- Two consecutive fix attempts produce the same or a worse failure → stop and ask the user how to proceed.
- The failure is in shared infrastructure (Jenkins agent offline, registry unreachable, queue stuck) rather than the code → stop and report; don't keep pushing.
- A failure classified `infra` recurs after its one permitted retry → stop and report an infrastructure blocker. Do not spend a second retry, and do not start editing code to work around it.
- Thread-owned changes cannot be separated safely from unrelated work → stop before committing and ask the user how to scope the commit.
- `scripts/check-buildgit.sh` fails → stop and report its message.

## Completion report

Report the committed SHA and subject, which remote and branch received the push, the final Jenkins job and build number, final status, test totals, and duration. If any build was retried as an `infra` failure, say so and name the stage that failed. Also report whether the worktree is clean and identify any unrelated local changes that were intentionally left untouched.
