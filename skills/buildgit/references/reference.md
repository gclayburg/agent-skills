# buildgit — Real-World Examples

## Setup requirements

buildgit assumes:

1. Your project is a git project
2. A git push will automatically trigger a build in a Jenkins CI/CD system.
3. The Jenkins job is setup as a Pipeline or Multibranch Pipeline job.
4. You have a Jenkins user with read/build permissions. It does not need to be an administrator.
5. There are no network/sandbox restrictions to access your Jenkins server.

## Push and monitor a build (with failure output)

If any failures are detected in the build, any tests, or any build pipeline stage, buildgit attempts to show you what failed. It does not fill the output with meaningless log data.
Humans don't need this most of the time. They just need to know what failed. Agents care about the same thing. They don't need their context window filled with useless logs.

Monitoring commands now include a preamble before active monitoring:

```bash
[10:23:48] ℹ Waiting for Jenkins build ralph1 to start...
[10:23:48] ℹ Prior 3 Jobs
SUCCESS     #54 id=6685a31 Tests=19/0/0 Took 5m 38s on 2026-02-22T22:37:21-0700 (4 days ago)
SUCCESS     #55 id=46f85cb Tests=19/0/0 Took 5m 40s on 2026-02-23T00:10:00-0700 (4 days ago)
SUCCESS     #56 id=0046c54 Tests=19/0/0 Took 6m 39s on 2026-02-24T10:14:10-0700 (3 days ago)
[10:23:48] ℹ Estimated build time = 6m 39s
[10:23:58] ℹ Starting
```

Use `--prior-jobs 0` to suppress the prior-jobs block.

For multibranch jobs where you do not know which branch Jenkins will build next, use `--probe-all` with follow mode:

```bash
$ buildgit status -f --probe-all --once --job ralph1
[10:23:48] ℹ Waiting for Jenkins build ralph1 (any branch) to start...
[10:23:58] ℹ Build detected on branch 'feature-x' - following ralph1/feature-x #13
SUCCESS     #13 id=39ab12c Tests=19/0/0 Took 5m 02s on 2026-03-14T10:23:58-0700 (just now)
```

`--probe-all` requires `-f`, rejects explicit branch jobs like `--job ralph1/main`, and falls back to normal single-job follow with a warning when the target job is not multibranch.

On TTY monitoring commands, use the global flag `--threads` before the subcommand to show active pipeline stages above the overall build bar:

```bash
$ buildgit --threads status -f --line
  [agent6 guthrie] Build [====================] 875% 35s / ~4s
IN_PROGRESS Job ralph1 #42 [=>                  ] 14% 35s / ~4m 10s
```

You can customize those per-stage rows with an optional format string or `BUILDGIT_THREADS_FORMAT`:

```bash
$ buildgit --threads '[%a] %S %p' status -f --line
[agent6 guthrie] Build 875%
IN_PROGRESS Job ralph1 #42 [=>                  ] 14% 35s / ~4m 10s
```

Nested parallel branches stay visible here as their local substages advance:

```bash
$ buildgit --threads status -f --line
  [fastnode      ] Simple Branch [====================] 100% 12s / ~12s
  [slownode      ] Nested Branch->Step A [===>                ] 20% 8s / ~39s
  [fastnode      ] Default Nested->Step X [=>                  ] 10% 3s / ~30s
IN_PROGRESS Job buildgit-integration-test-threads #18 [====>               ] 29% 30s / ~1m 44s
```

```bash
$ buildgit push
To ssh://scranton2:2233/home/git/phandlemono.git
   4ae2fc1..039301d  main -> main
[09:13:35] ℹ Waiting for Jenkins build phandlemono-IT to start...

╔════════════════════════════════════════╗
║          BUILD IN PROGRESS             ║
╚════════════════════════════════════════╝

Job:        phandlemono-IT
Build:      #41
Status:     BUILDING
Trigger:    SCM change
Started:    2026-02-21 09:13:43
Console:    http://palmer.garyclayburg.com:18080/job/phandlemono-IT/41/console



=== Console Output ===
Started by user buildtriggerdude
Obtained Jenkinsfile from git ssh://git@scranton2:2233/home/git/phandlemono.git
org.codehaus.groovy.control.MultipleCompilationErrorsException: startup failed:
WorkflowScript: 59: expecting ')', found 'eSet' @ line 59, column 45.
             for (entry in chang eSet.items
                                 ^

1 error

        at org.codehaus.groovy.control.ErrorCollector.failIfErrors(ErrorCollector.java:309)
        at org.codehaus.groovy.control.ErrorCollector.addFatalError(ErrorCollector.java:149)
        at org.codehaus.groovy.control.ErrorCollector.addError(ErrorCollector.java:119)
        at org.codehaus.groovy.control.ErrorCollector.addError(ErrorCollector.java:131)
        at org.codehaus.groovy.control.SourceUnit.addError(SourceUnit.java:349)
        at org.codehaus.groovy.antlr.AntlrParserPlugin.transformCSTIntoAST(AntlrParserPlugin.java:225)
        at org.codehaus.groovy.antlr.AntlrParserPlugin.parseCST(AntlrParserPlugin.java:191)
        at org.codehaus.groovy.control.SourceUnit.parse(SourceUnit.java:233)
        at org.codehaus.groovy.control.CompilationUnit$1.call(CompilationUnit.java:189)
        at org.codehaus.groovy.control.CompilationUnit.applyToSourceUnits(CompilationUnit.java:966)
        at org.codehaus.groovy.control.CompilationUnit.doPhaseOperation(CompilationUnit.java:626)
        at org.codehaus.groovy.control.CompilationUnit.processPhaseOperations(CompilationUnit.java:602)
        at org.codehaus.groovy.control.CompilationUnit.compile(CompilationUnit.java:579)
        at groovy.lang.GroovyClassLoader.doParseClass(GroovyClassLoader.java:323)
        at groovy.lang.GroovyClassLoader.parseClass(GroovyClassLoader.java:293)
        at PluginClassLoader for script-security//org.jenkinsci.plugins.scriptsecurity.sandbox.groovy.GroovySandbox$Scope.parse(GroovySandbox.java:162)
        at PluginClassLoader for workflow-cps//org.jenkinsci.plugins.workflow.cps.CpsGroovyShell.doParse(CpsGroovyShell.java:188)
        at PluginClassLoader for workflow-cps//org.jenkinsci.plugins.workflow.cps.CpsGroovyShell.reparse(CpsGroovyShell.java:173)
        at PluginClassLoader for workflow-cps//org.jenkinsci.plugins.workflow.cps.CpsFlowExecution.parseScript(CpsFlowExecution.java:653)
        at PluginClassLoader for workflow-cps//org.jenkinsci.plugins.workflow.cps.CpsFlowExecution.start(CpsFlowExecution.java:599)
        at PluginClassLoader for workflow-job//org.jenkinsci.plugins.workflow.job.WorkflowRun.run(WorkflowRun.java:341)
        at hudson.model.ResourceController.execute(ResourceController.java:101)
        at hudson.model.Executor.run(Executor.java:454)
[Checks API] No suitable checks publisher found.
Finished: FAILURE
======================

Finished: FAILURE
[09:13:48] ℹ Duration: 0s
```

## Hierarchical downstream test results

For multi-component pipelines, full output now keeps the parent job row and adds one row per downstream build, then reports aggregate totals:

```bash
$ buildgit --job phandlemono-IT status 73 --all
...
=== Test Results ===
phandlemono-IT       Total:  ? | Passed:  ? | Failed: ? | Skipped: ?
  Build SignalBoot   Total: 15 | Passed: 14 | Failed: 1 | Skipped: 0
  Build Handle       Total: 83 | Passed: 83 | Failed: 0 | Skipped: 0
--------------------
Totals                     98 | Passed: 97 | Failed: 1 | Skipped: 0
====================
```

The compact line output uses those same aggregate totals:

```bash
$ buildgit --job phandlemono-IT status 73
FAILURE     #73 id=a916068 Tests=97/1/0 Took 4m 9s on 2026-03-16T12:37:47-0600 (1 hour ago)

$ buildgit --job phandlemono-IT status 75
SUCCESS     #75 id=c7c0c96 Tests=98/0/0 Took 5m 41s on 2026-03-16T13:02:11-0600 (1 hour ago)
```

JSON output stays top-level compatible and adds a per-job `breakdown` array only when downstream builds exist:

```bash
$ buildgit --job phandlemono-IT status 73 --json | jq '.test_results'
{
  "total": 98,
  "passed": 97,
  "failed": 1,
  "skipped": 0,
  "failed_tests": [...],
  "breakdown": [
    {"job":"phandlemono-IT","build_number":73,"total":null,"passed":null,"failed":null,"skipped":null},
    {"job":"phandlemono-signalboot","stage":"Build SignalBoot","build_number":63,"total":15,"passed":14,"failed":1,"skipped":0},
    {"job":"phandlemono-handle","stage":"Build Handle","build_number":66,"total":83,"passed":83,"failed":0,"skipped":0}
  ]
}
```

## Custom format string (--format)

```bash
$ buildgit status --format '%s #%n %c'
SUCCESS     #55 9b9d481

$ buildgit status --format '%s Job %j #%n commit=%c branch=%b'
SUCCESS     Job phandlemono-IT #55 commit=9b9d481 branch=main

$ buildgit status -n 3 --format '%s #%n %d'
FAILURE     #53 3m 41s
SUCCESS     #54 5m 40s
SUCCESS     #55 5m 38s
```

Format placeholders: `%s`=status `%j`=job `%n`=build# `%t`=tests `%d`=duration `%D`=date `%I`=iso8601 `%r`=relative `%c`=commit `%b`=branch `%%`=literal%
Default line format: `%s #%n id=%c Tests=%t Took %d on %I (%r)`

Threads placeholders: `%a`=agent `%S`=stage `%g`=progress-bar `%p`=percent `%e`=elapsed `%E`=estimate `%%`=literal%
Default threads format: `  [%-14a] %S %g %p %e / %E`
Set `BUILDGIT_THREADS_FORMAT` or pass `--threads '<fmt>'` to customize live per-stage TTY rows.

If test-report retrieval fails due to communication issues (for example network/sandbox restrictions), `%t` shows `!err!` and buildgit logs:

```bash
[HH:MM:SS] ⚠ Could not retrieve test results (communication error)
```

Normal build output, including queue updates, stage progress, completion summaries, and verbose diagnostics, is written to stdout. stderr is reserved for invalid input, Jenkins communication failures, and transient TTY redraw artifacts.

## Agent failure diagnostics

List the available stages for a build:

```bash
$ buildgit status 60 --list-stages
Build
Unit Tests A
Unit Tests B
Deploy
```

Get one stage's raw console text:

```bash
$ buildgit status 60 --console-text "Unit Tests B"
not ok 1 - follow_completed_build_shows_console_url
# stage detail follows here without banners or truncation
```

If the stage name is a parent wrapper with empty direct console text, buildgit now searches descendant substages automatically. Stage matching also accepts exact, case-insensitive, and unique partial names:

```bash
$ buildgit status 60 --console-text "main build"
===== Main Build -> Compile =====
compile failed fast

===== Main Build -> Unit Tests =====
not ok 1 - unit test failure
```

Get structured failed-test stdout without truncation:

```bash
$ buildgit -v status 60 --json | jq '.test_results.failed_tests[0]'
{
  "class_name": "buildgit_status_follow.bats",
  "test_name": "follow_completed_build_shows_console_url",
  "stdout": "[22:54:28] waiting\n[22:54:29] still waiting\n..."
}
```

## Agent capacity by node (`agents --nodes`)

Use `--nodes` when label overlap matters more than the default label-centric grouping:

```bash
$ buildgit agents --nodes
Node: agent6 guthrie  (3 executors, 0 busy)
  Labels: agent6, dockernode, fastnode, guthrie

Node: agent8_sixcore  (3 executors, 1 busy)
  Labels: agent8_sixcore, fastnode, fullspeed, sixcore
```

JSON output pivots to a top-level `nodes` array:

```bash
$ buildgit agents --nodes --json | jq '.nodes[0]'
{
  "name": "agent6 guthrie",
  "executors": 3,
  "busy": 0,
  "idle": 3,
  "online": true,
  "labels": ["agent6", "dockernode", "fastnode", "guthrie"]
}
```

## Timing by stage (`timing --tests --by-stage`)

```bash
$ buildgit timing --tests --by-stage
Build #42 - total 4m 21s
...
Test suite timing by stage:
  Unit Tests A (wall 51s, agent6 guthrie):
    buildgit_status_follow  2m 2s  (74 tests)
    buildgit_push           1m 1s  (20 tests)
  Unit Tests B (wall 1m 50s, agent8_sixcore):
    nested_stages           3m 29s  (50 tests)
```

In JSON mode, the same run adds `testsByStage` keyed by stage name:

```bash
$ buildgit timing --tests --by-stage --json | jq '.testsByStage["Unit Tests A"]'
[
  {"name":"buildgit_status_follow","tests":74,"durationMs":122300,"failures":0}
]
```

## Build timing comparison (`timing --compare`)

```bash
$ buildgit timing --compare 40 42
Timing comparison: Build #40 vs #42
                      #40        #42       Delta
Total               4m 33s     4m 21s      -12s
  Unit Tests A         48s        51s       +3s
  Unit Tests B       2m 4s      1m 50s     -14s
```

Positive deltas mean the newer build was slower for that row. Negative deltas mean it improved.

## Multi-build timing table (`timing -n`)

```bash
$ buildgit timing -n 3
Build  Total   Unit A  Unit B  Integration  Deploy
#40    4m 36s    51s   3m 28s     4m 25s       4s
#41    4m 33s    48s   2m  4s     4m 22s       4s
#42    4m 21s    51s   1m 50s     4m 10s       4s
```

If you also pass `--tests`, buildgit prints the compact table first and then the detailed suite timing for only the newest build in the requested range.

## Pipeline test-suite summaries

Human-readable pipeline output now includes a per-stage test summary when that stage published JUnit results:

```bash
$ buildgit pipeline 42
...
└─ Unit Tests B [fastnode] -- sequential
     6 suites, 156 tests, 5m 24s cumulative
```

JSON output now includes per-stage `testSuites` arrays:

```bash
$ buildgit pipeline 42 --json | jq '.stages[] | select(.name=="Unit Tests B") | .testSuites'
[
  {"name":"nested_stages","tests":50,"durationMs":209000,"failures":0}
]
```

## Show status for last N builds (--line)

```bash
$ buildgit status --line -n 5
FAILURE     #34 id=09a1b2c Tests=?/?/? Took 3m 41s on 2026-02-14T09:41:10-0700 (6 days ago)
FAILURE     #35 id=1bc2d3e Tests=?/?/? Took 3m 27s on 2026-02-14T09:52:58-0700 (6 days ago)
NOT_BUILT   #36 id=2cd3e4f Tests=?/?/? Took 3m 52s on 2026-02-16T11:07:44-0700 (4 days ago)
SUCCESS     #37 id=3de4f5a Tests=19/0/0 Took 5m 41s on 2026-02-16T12:26:03-0700 (4 days ago)
SUCCESS     #38 id=4ef5a6b Tests=19/0/0 Took 5m 32s on 2026-02-17T08:14:52-0700 (3 days ago)
```

## Show one relative build

```bash
$ buildgit status -2
# Shows exactly one build: two builds before the latest
```

## Show last N builds in full or JSONL mode

```bash
$ buildgit status -n 3
# Prints 3 full build reports, oldest first

$ buildgit status -n 3 --json
{"job":"phandlemono-IT","build":{"number":36,...}}
{"job":"phandlemono-IT","build":{"number":37,...}}
{"job":"phandlemono-IT","build":{"number":38,...}}
```

## Show last N builds then follow (--line -f)

```bash
$ buildgit status --line -n 5 -f
FAILURE     #34 id=09a1b2c Tests=?/?/? Took 3m 41s on 2026-02-14T09:41:10-0700 (6 days ago)
FAILURE     #35 id=1bc2d3e Tests=?/?/? Took 3m 27s on 2026-02-14T09:52:58-0700 (6 days ago)
NOT_BUILT   #36 id=2cd3e4f Tests=?/?/? Took 3m 52s on 2026-02-16T11:07:44-0700 (4 days ago)
SUCCESS     #37 id=3de4f5a Tests=19/0/0 Took 5m 41s on 2026-02-16T12:26:03-0700 (4 days ago)
SUCCESS     #38 id=4ef5a6b Tests=19/0/0 Took 5m 32s on 2026-02-17T08:14:52-0700 (3 days ago)
IN_PROGRESS Job phandlemono-IT #39 [>                   ] 1% 5s / ~5m 32s
```

## Full status output for a successful build (`--all`)

```bash
$ buildgit status --all

╔════════════════════════════════════════╗
║           BUILD SUCCESSFUL             ║
╚════════════════════════════════════════╝

Job:        phandlemono-IT
Build:      #39
Status:     SUCCESS
Trigger:    Manual by Ralph AI Read Only
Commit:     4ae2fc1  fix: resolve port 9222 conflict and remove deliberate build failures
            ✓ Your commit (HEAD)
Started:    2026-02-20 20:23:56
Agent:      agent8_sixcore
Console:    http://palmer.garyclayburg.com:18080/job/phandlemono-IT/39/console

# Stage agent labels are resolved per stage from Jenkins "Running on ..." lines.
# Parallel branches may show different agents.
# Branch-local sequential substages stay nested as Branch->Substage, keep the
# parent branch marker/agent, and are included in the branch duration.
[09:00:08] ℹ   Stage: [agent8_sixcore] Declarative: Checkout SCM (<1s)
[09:00:08] ℹ   Stage: [agent8_sixcore] Checkout (<1s)
[09:00:08] ℹ   Stage: [agent8_sixcore] Analyze Component Changes (<1s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Declarative: Checkout SCM (<1s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Checkout (<1s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Check for Relevant Changes (<1s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Clean (<1s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Setup (8s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Build (13s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Test (2s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->TestContainers IT (21s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Playwright e2e IT (1m 14s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Coverage (2s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Package (1m 40s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Archive Artifacts (8s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Declarative: Post Actions (<1s)
[09:00:08] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle (4m 5s)
[09:00:08] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Declarative: Checkout SCM (<1s)
[09:00:08] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Checkout (<1s)
[09:00:08] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Check for Relevant Changes (<1s)
[09:00:08] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Artifactory configuration (<1s)
[09:00:08] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->System Diagnostics (2s)
[09:00:08] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Docker Diagnostics (4s)
[09:00:08] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->main build (1m 4s)
[09:00:09] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Docker Build (25s)
[09:00:09] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Docker Push (13s)
[09:00:09] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Deploy registerdemo (19s)
[09:00:09] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Publish to Artifactory (37s)
[09:00:09] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Archive Artifacts (41s)
[09:00:09] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Publish build info (<1s)
[09:00:09] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Declarative: Post Actions (2s)
[09:00:09] ℹ   Stage:   ║2 [agent8_sixcore] Build SignalBoot (3m 44s)
[09:00:09] ℹ   Stage: [agent8_sixcore] Trigger Component Builds (4m 5s)
[09:00:09] ℹ   Stage: [agent8_sixcore] Verify Docker Images (6s)
[09:00:09] ℹ   Stage: [agent8_sixcore] Setup Handle (19s)
[09:00:09] ℹ   Stage: [agent8_sixcore] Integration Tests (22s)
[09:00:09] ℹ   Stage: [agent8_sixcore] E2E Tests (1m 14s)
[09:00:09] ℹ   Stage: [agent8_sixcore] Declarative: Post Actions (<1s)

=== Test Results ===
phandlemono-IT      Total: 19 | Passed: 19 | Failed: 0 | Skipped: 0
  Build SignalBoot  Total: 15 | Passed: 15 | Failed: 0 | Skipped: 0
  Build Handle      Total: 64 | Passed: 64 | Failed: 0 | Skipped: 0
--------------------
Totals                    98 | Passed: 98 | Failed: 0 | Skipped: 0
====================

Finished: SUCCESS
[09:00:09] ℹ Duration: 6m 13s
```

## Full status — build in progress (-f)

```bash
$ buildgit status -f

[09:02:13] ℹ Waiting for next build of phandlemono-IT...

╔════════════════════════════════════════╗
║          BUILD IN PROGRESS             ║
╚════════════════════════════════════════╝

Job phandlemono-IT #40 has been running for unknown

Job:        phandlemono-IT
Build:      #40
Status:     BUILDING
Trigger:    Manual by Ralph AI Read Only
Commit:     4ae2fc1  fix: resolve port 9222 conflict and remove deliberate build failures
            ✓ Your commit (HEAD)
Started:    2026-02-21 09:02:43
Agent:      agent8_sixcore
Console:    http://palmer.garyclayburg.com:18080/job/phandlemono-IT/40/console
[09:02:49] ℹ   Stage: [agent8_sixcore] Declarative: Checkout SCM (<1s)
[09:02:49] ℹ   Stage: [agent8_sixcore] Checkout (<1s)
[09:02:49] ℹ   Stage: [agent8_sixcore] Analyze Component Changes (<1s)
[09:03:01] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Declarative: Checkout SCM (<1s)
[09:03:07] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Checkout (<1s)
[09:03:07] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Check for Relevant Changes (<1s)
[09:03:07] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Clean (<1s)
[09:03:07] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Declarative: Checkout SCM (<1s)
[09:03:07] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Checkout (<1s)
[09:03:07] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Check for Relevant Changes (<1s)
[09:03:07] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Artifactory configuration (<1s)
[09:03:13] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->System Diagnostics (2s)
[09:03:13] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Docker Diagnostics (3s)
[09:03:19] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Setup (9s)
[09:03:26] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Build (12s)
[09:03:33] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->Test (2s)
[09:03:53] ℹ   Stage:   ║1 [agent8_sixcore] Build Handle->TestContainers IT (21s)
[09:04:20] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->main build (1m 2s)
[09:04:35] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Docker Build (20s)
[09:04:49] ℹ   Stage:   ║2 [agent7        ] Build SignalBoot->Docker Push (8s)
IN_PROGRESS Job phandlemono-IT #40 [======>             ] 35% 2m 12s / ~6m 13s
```
