# Build Optimization with buildgit

Use this workflow when the user wants to make Jenkins builds faster, reduce queue time, rebalance test groups, or understand where build time is spent.

## Phase 1: Gather Baseline Data

Run these four commands to understand the current build. All data comes from the Jenkins API — no direct API calls needed.

```bash
# Stage timing + per-test-suite timing (use latest successful build)
buildgit timing --tests

# Executor capacity and labels
buildgit agents

# Pipeline structure, parallelism, agent labels
buildgit pipeline --json

# Recent build history for patterns
buildgit status --line -n 10
```

### What to look for in `timing --tests`

```
Build #74 - total 6m 0s
Sequential stages:
  Build  4s  agent6 guthrie
  Unit Tests  <1s
  Integration Tests  3m 49s  agent6 guthrie
  Deploy  3s  agent7 guthrie
Parallel group: Unit Tests (wall 1m 59s, bottleneck: Unit Tests A)
  Unit Tests A  1m 59s  agent7 guthrie  <- slowest
  Unit Tests B  1m 31s  agent8_sixcore
  Unit Tests C  1m 27s  agent7 guthrie
  Unit Tests D  1m 38s  agent8_sixcore
Test suite timing (top 10 slowest):
  integration_tests  3m 34s  (9 tests)
  status_follow  2m 36s  (74 tests)
  ...
```

Key points:
- **Sequential stages** show time that cannot overlap. Any sequential stage that could run in parallel is an optimization target.
- **Parallel group** shows the wall time and identifies the bottleneck branch. Only speeding up the bottleneck branch reduces wall time.
- **Test suite timing** shows cumulative duration per test suite (sum of all test case durations from JUnit reports). This is NOT wall time — if the test runner executes tests in parallel, wall time will be lower than cumulative time.

### What to look for in `agents`

```
Label: fastnode
  Nodes: 3
  Executors: 9 total, 0 busy, 9 idle
  Node details:
    agent6 guthrie  3 executors  0 busy  online
    agent7 guthrie  3 executors  0 busy  online
    agent8_sixcore  3 executors  0 busy  online
```

Key points:
- **Idle executors** mean unused capacity. If stages are slow but executors are idle, consider adding parallel stages.
- **Label overlap** is critical. Two labels that share the same physical nodes will contend with each other. Cross-reference node names across labels to find overlap. For example, if `dockernode` and `fastnode` both include `agent6 guthrie`, assigning stages to `dockernode` does not avoid `fastnode` contention.
- **Executor count per node** limits how many concurrent stages can run on that node.

### What to look for in `pipeline --json`

The pipeline graph shows which stages run in parallel, which are sequential, and which agent label each uses. Use this to confirm assumptions from `timing` output about the pipeline structure.

## Phase 2: Identify Optimization Opportunities

Common patterns, ordered by typical impact:

### 1. Parallelize sequential stages that are independent

If `timing` shows two sequential stages with no dependency between them, moving them into a parallel block saves the full duration of the faster one.

**Example:** Integration tests ran sequentially after unit tests but had no dependency on them. Moving integration tests into the same parallel block saved ~2 minutes.

### 2. Rebalance parallel test groups

If parallel branches within a group have uneven wall times, the slowest branch determines the group's wall time. Redistribute test files across groups to equalize duration.

**Guidelines for rebalancing:**
- Put each heavy test file (highest cumulative duration) in a separate group as the "anchor."
- Fill remaining capacity with lighter files.
- The catch-all group (dynamic file discovery) ensures new test files are always picked up even if not explicitly assigned.
- Test suite cumulative times from `timing --tests` are the key data for balancing.
- More groups is not always better — each group has fixed overhead (Docker pull, checkout, submodule init). Typical overhead is 10-20 seconds per group.

### 3. Increase within-group test parallelism

Most test runners support parallel test execution (e.g., parallel forks, worker threads, sharding). If a test group has high cumulative time but low wall time, parallelism is working well. If cumulative time is close to wall time, the test runner may be executing tests sequentially. Check your test runner's parallel execution configuration and increase it if the agent has available CPU cores.

### 4. Spread stages across different agent labels to reduce contention

If many parallel stages compete for the same label, they contend for a limited executor pool. Move some stages to different labels if the agents support it.

**Caution:** Labels can overlap. Check `buildgit agents` to verify that the target label uses physically different nodes. Assigning a stage to a different label that includes the same nodes does not reduce contention.

### 5. Use dedicated fast agents for critical-path stages

If one stage is the bottleneck and a faster agent exists, assign that stage a label that targets the fast agent exclusively. Other stages can use broader labels.

### 6. Reduce artificial sleeps in test pipelines

Test infrastructure Jenkinsfiles or test harnesses may contain `sleep` statements that artificially inflate build time. Check for:
- Sleep-based polling loops with excessive intervals (e.g., `sleep 5` where `sleep 1` suffices for HTTP API polls).
- Test pipeline Jenkinsfiles with sleep steps that simulate work — reduce these to the minimum required by timing assertions.

**Example:** An integration test pipeline had 54 seconds of `sleep` per build across 8 stages. Reducing to 22 seconds (while preserving timing assertions of >=7s per branch) saved ~30 seconds from the critical path.

## Phase 3: Make Changes and Measure

### Push and monitor in one step

```bash
buildgit push --line
```

This pushes the commit, waits for Jenkins to pick it up, and monitors the build with a progress bar. Use this for every iteration.

### Compare results

After each change, run `buildgit timing --tests` again and compare:
- Total build time
- Each parallel branch wall time
- Which branch is the new bottleneck
- Test suite cumulative times (did anything slow down?)

### Build history for trend analysis

```bash
buildgit status --line -n 10
```

Check that recent builds are consistently faster, not just one lucky run.

### Diagnosing failures

If a build fails after optimization changes:

```bash
# See which stage failed
buildgit status --all

# Get raw console output for the failed stage
buildgit status --console-text "Stage Name"
```

Common failure causes after rebalancing:
- **Agent label mismatch**: Stage assigned to a label with no available agents, or agents that lack required infrastructure (SSH keys, Docker images, network access).
- **Resource contention**: Too many parallel stages overwhelm a node's CPU/memory/network.
- **Stale host keys**: Agents with cached SSH known_hosts that don't match the current git server key. Fix with `ssh-keyscan` before checkout.

## Phase 4: Understand the Limits

Once you've parallelized, rebalanced, and trimmed waste, the remaining build time comes from:
- **External dependencies**: Integration tests that trigger real builds and wait for them. Their time is dominated by the external pipeline, not your test harness.
- **Jenkins overhead**: Docker image pulls, agent provisioning, SCM checkout, queue wait. These are fixed costs per stage.
- **Inherently slow tests**: Some tests do real I/O, network calls, or complex setup. These set a floor on wall time within their group.

The critical path will converge on the slowest irreducible stage. Further improvement requires changing the test architecture itself, not the pipeline layout.

## Key Constraints

- Use recent **successful** builds for timing analysis. Failed builds have incomplete timing.
- `queue` and `agents` describe current Jenkins state. `timing` and `pipeline` describe build structure and historical execution.
- High queue time with idle executors usually means label mismatch, not capacity shortage.
- A faster branch inside a parallel block does not improve wall time if a sibling branch is the bottleneck.
- Optimize one suspected bottleneck at a time and re-measure before making further changes.
- Test suite timing from JUnit reports is cumulative (sum of test durations), not wall time. Wall time depends on the test runner's parallel execution within the group.
