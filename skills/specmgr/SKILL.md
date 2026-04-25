---
name: specmgr
description: >
  Spec-driven development workflow manager. Use when: (1) creating a DRAFT spec
  from input files or raw ideas, (2) creating a chunk plan
  from a DRAFT spec, (3) implementing a DRAFT spec (DRAFT to IMPLEMENTED transition),
  or (4) managing spec state transitions. Triggers on "create spec",
  "draft spec", "implement spec", "chunk plan", "spec workflow", or references to
  *-spec.md files.
metadata:
  tags: spec, specification, workflow, implementation, planning, chunking
  platforms: Claude, ChatGPT, Gemini, Cursor
---

# Spec-Driven Development Workflow Manager

Individual `*-spec.md` files are treated as the specification for each feature—they define what the feature is and what it must do. These specification files are the authoritative ("canonical") source of requirements for their parts of the application.

- All spec files that are created from other raw report documents should reference those documents in the title header of the spec
- When writing a new spec, review the existing specs in the specs/ directory and identify any that are clearly superseded by your new specification. List only the directly superseded (first-level) specs.

---

## Workflow 1: Create DRAFT Spec

**Triggers:** "create a DRAFT spec from...", "write a spec for...", "draft spec..."

### Before writing the spec

1. Read all input/reference files first
2. Read all files matching `*-spec.md` in the project's `specs/` directory; newer specs take priority over older ones
3. Check `specs/README.md` for the existing spec index

### STOP: Ask clarifying questions

**Do NOT proceed to writing the spec until this step is complete.**

Present your questions to the user about:
- Anything that needs clarification in the input
- Any incompatibilities found with existing specs
- Recommendations or design choices you see

Wait for the user's answers before writing the spec document.

### Naming convention

- Filename format: `specs/<name>-spec.md`
- The `<name>` portion is derived from the input file or feature name (e.g., `featurereport74.md` → `specs/featurereport74-spec.md`)  New specs should NOT have a date in the filename.

### Spec template

Include the following fields at the top of every DRAFT spec:

```
## Title

- **Date:** `<ISO 8601 format with seconds, America/Denver timezone>`
- **References:** list of `<other-raw-report-path.md>` or `<none>`
- **AgentTestPlan:** `<path-to-agent-test-plan.md>` or `none`
- **Supersedes:** list of `<other-spec-file.md>`
- **Chunkplan:** `<path-to-chunkplan.md>` or `none`
- **Chunked:** `true` or `false`
- **State:** one of these valid values: `DRAFT`, `IMPLEMENTED`, `VALIDATED`
```

### Header field commit contract

The header fields above are the **authoritative list of files that define the spec** These files must be added to any worktree used for implementation.

### Setting the `Chunked:` field

- Set to `true` if the spec should be broken into a chunk plan before implementation. Set to `false` if it can be implemented in a single pass.
- Consider `true` when: the spec touches many files across different subsystems, requires multiple independent features or phases, has complex test strategy spanning several areas, or would exceed what an agent can reliably implement and test in one session.
- Consider `false` when: the changes are mechanical/uniform (e.g., same pattern applied across many call sites), the scope is limited to one subsystem, or the spec is a straightforward bug fix.
- This is a recommendation for the human reviewer — the chunk plan is not created until after review.

### Root cause analysis

If the raw issue is a bug or something broken, perform a root cause analysis and include that in the spec.

### Companion agent test plan

Always create a companion agent test plan file alongside the spec: `<spec-basename>-agent-test-plan.md` (e.g., `condense-build-header-spec.md` → `condense-build-header-agent-test-plan.md`). The agent test plan must contain concrete CLI commands that an agent can execute to verify the implementation works end-to-end against the real tool and environment. Link the agent test plan from a `## Agent Test Plan` section at the end of the spec (before the `## SPEC workflow` section), AND record its path in the spec header's `AgentTestPlan:` field so `implement-spec.sh` commits it with the spec.

### Agent test plan guidelines
The point of an agent test plan is to validate that once a spec is implemented, that all the components exist together as part of a coheseive whole.  e.g.

- website (if any) can start up without errors
- expected website content is visible
- cli tool (if any) can run with options modified under spec
- execute basic functionality against known external data according to the spec

A test plan is not:
- a substitute for a unit test
- a substitute for an end to end test
- a substitute for an integration test
- a substitute for passing all CI/CD tests
- a comprehensive test of everything changed in the spec

### SPEC workflow section

Include the following verbatim at the end of every DRAFT spec:

```
## SPEC workflow

1. read `specs/CLAUDE.md` and follow all rules there to implement this DRAFT spec (DRAFT->IMPLEMENTED)
```

### Superseded specs

When creating a new spec, identify any existing specs that are directly superseded by the new specification. List them in the `Supersedes:` field.

---

## Workflow 2: Create Chunk Plan

**Triggers:** "create a plan from spec...", "chunk this spec...", "break down spec...", "create a chunk plan..."

### Instructions

1. Load the `references/taskcreator.md` file from this skill for the full decomposition methodology.
2. Load the `references/chunk-template.md` file from this skill for the chunk format template.
3. Follow all rules in `references/taskcreator.md` to decompose the spec.

### Plan file naming

- Plan files are named: `specs/<spec-basename>-chunkplan.md` (e.g., `majorfeature47-spec.md` → `specs/majorfeature47-chunkplan.md`)
- Plan files are created in the `specs/` directory (not `specs/todo/`), regardless of where the source spec file is located. Plans are ready-to-implement artifacts.
- After the chunk plan file is written, update the parent spec's `Chunkplan:` field to reference the chunk plan file.

### SPEC Workflow in plans

The SPEC Workflow block embedded in plans must use generic language:
- "Run all unit tests" (do not hardcode a test runner command — the project's `CLAUDE.md` or `specs/CLAUDE.md` specifies the test runner)
- "Commit and push" (do not hardcode a push command — the project's conventions apply)
- "Update project documentation as specified in the project's CLAUDE.md or specs/CLAUDE.md"

#### Create Implementation log 

All implementations will have an implementation log that is modifed as needed during implementation. Guidelines:
1. after implementation: summarize files changed, key decisions, and anything notable learned during implementation
2. Count compaction events (system-reminder summarizing prior conversation) that occured during implementation.  If unknown, use 0.
3. Record list of skills invoked with `Skill` tool during implementation, or `NONE`.

Location of Implementation log: 
- If implementing a DRAFT Spec not chunked, The implementation log should be created in a new section `#### Implementation Log` at the bottom of the spec file
- If implementing a spec with a chunkplan, the chunk plan file is the live log destination during implementation — each chunk's notes go into its own `#### Implementation Log` subsection in the chunk plan

#### Existing test modification policy

When your implementation causes a pre-existing test to fail, you may fix it and continue — do not stop to ask. However:

1. **Determine spec backing first.** Before changing an existing test, identify which section of the spec requires the behavioral change that invalidates the old test.
2. **If the spec backs the change:** fix the test and log the change in the `#### Implementation Log` section.
3. **If no spec section backs the change:** you still may fix it and continue, but you MUST log it with `Spec Backing: None` in the implementation log. These entries will be flagged for reviewer attention.
4. **What counts as modifying an existing test:** changing assertions, expected values, fixture data, test domain names, or any other change whose purpose is to make a previously-passing test continue to pass under new behavior. Adding new test cases is not a modification.
5. **Never weaken a test to avoid a failure.** Changing fixture data to sidestep new validation (e.g. removing a `.com` suffix so domain validation is never triggered) is weakening, not fixing. If the test was exercising a code path that your implementation changed, the test should still exercise that code path — with correct updated expectations.

---

## Workflow 3: Implement DRAFT Spec (DRAFT → IMPLEMENTED)

**Triggers:** "implement DRAFT spec...", "implement spec..."

When implementing a DRAFT spec or bug fix, follow these steps in order.

### 3a Before writing code

- [ ] **Check for chunk plan** if there is a chunk plan use Workflow 4 instead of this one
- [ ] **Check build status** and confirm the last build is successful. Do not proceed if the build is setup but broken.  It is ok if there is no build setup for this project yet.
- [ ] **Run all unit tests** and confirm they pass. Do not proceed if there are existing tests but they are failing.

### 3b Implement the feature or fix

- [ ] **Write the code** as described in the spec's Specification section.
- [ ] **Write or update unit tests** as described in the spec's Test Strategy section.
- [ ] **Run all unit tests** and confirm they pass (both new and existing).
- [ ] **Write implementation log notes** in a new section `#### Implementation Log`.  See `#### Create Implementation log` section above
- [ ] **Check if the spec references an agent test plan** (look for a `## Agent Test Plan` section or a companion `*-agent-test-plan.md` file). If one exists, execute the test plan and verify it is successful.
- [ ] **CI/CD gate — MANDATORY before marking IMPLEMENTED.** The spec CANNOT be marked IMPLEMENTED unless the CI/CD build is confirmed GREEN (no failures). Follow this procedure:
- [ ]  **Commit and push** per the project conventions. Use a commit message starting with `impl spec: <xyz.md>` followed by a brief description.
- [ ]  **Fix build errors** Use `buildgit` skill to push your changes. Wait for the build to complete. Fix any errors shown.  Repeat this step as necessary until the build is GREEN.
- [ ]  **Run all Finalize steps in workflow 5**  All steps in Workflow 5 must be executed, including workreview generation, changelog/spec updates, and state transition.  

## Workflow 4: Implement DRAFT Spec using chunk plan (DRAFT → IMPLEMENTED)

**Triggers:** "implement DRAFT spec with chunk plan ...", "implement chunk X from chunk plan..."

> **Note:** Even when asked to implement only "one chunk," if that chunk turns out to be the final incomplete chunk, Workflow 5 (Finalize) is mandatory immediately after 4b completes. Do not wait for a separate user instruction to finalize.

### 4a Before writing code
- [ ] **Check for chunk plan** if there is no chunk plan, use Workflow 3 instead of this one
- [ ] **Run all unit tests NOW, before writing any code**, and confirm they pass. This establishes the baseline. Do not proceed if tests are failing. If the test commands themselves are broken (e.g. missing tools, build infrastructure failures, repository configuration errors), do NOT skip tests and continue — this is a blocking failure. Output `RALPH_BLOCKED=<reason>` as the final line and stop.
- [ ] **Note the spec's `AgentTestPlan:` header field.** If it is non-empty, you will execute that test plan during Workflow 5a. Record the path now so it is not forgotten when you reach finalization.

### 4b Per-Chunk Workflow (every chunk must follow these steps)

- [ ] **Write implementation log notes** in a new section `#### Implementation Log`.  See `#### Create Implementation log` section above

- [ ]  **Implement the chunk** as described in its Implementation Details section.
- [ ]  **Write or update unit tests** as described in the chunk's Test Plan section.
- [ ]  **Run all unit tests** and confirm they pass (both new and existing). The **Existing test modification policy** from Workflow 3b applies here as well.
- [ ]  **Mark chunk complete** Mark ONLY the one chunk you implemented as completed in chunkplan (change '- [ ]' to '- [x]').
- [ ]  **Commit and push** per the project conventions. Use a commit message starting with `chunk N/T:` followed by a brief description.
- [ ]  **Fix build errors** Use `buildgit` skill to push your changes. Wait for the build to complete. Fix any errors shown.  Repeat this step as necessary until the build is GREEN.
- [ ]  **Check if this was the last chunk.** Scan the Contents table in the chunk plan. If every chunk row is now `[x]`, proceed immediately to Workflow 5 (Finalize) without waiting for further user instruction. Finalization is a mandatory part of the implementation — it is not a separate user request.

**Blocking failure rule:** If at any point during the per-chunk workflow you encounter a failure that you cannot fix (broken build infrastructure, missing tools, repository configuration errors, or test failures unrelated to your chunk's changes), do NOT output `REMAINING_CHUNKS=n`. Instead, output `RALPH_BLOCKED=<brief reason>` as the final line and stop immediately. Do not attempt the next chunk. If a chunk is abandoned due to `RALPH_BLOCKED`, still record the compaction count and skills used up to the blocking point in the chunk's Implementation Log before stopping.

### Workflow 5 Finalize Implementation

Use this workflow **after** Workflow 3 (single-pass) or **after** all chunks in Workflow 4 are complete. All Steps in Workflow 5 are **MANDATORY** when implementing a spec or a chunkplan.
If any required finalize step cannot be completed, output `SPEC_BLOCKED=<reason>` and stop.

### 5a Run agent test plan (if present)

- [ ] **Check if the spec references an agent test plan** (look for a `## Agent Test Plan` section or a companion `*-agent-test-plan.md` file). If one exists, execute the test plan and verify it is successful.

### 5b Verify CI/CD build is green

- [ ] **CI/CD gate — MANDATORY before marking IMPLEMENTED.** The spec CANNOT be marked IMPLEMENTED unless the CI/CD build is confirmed GREEN (no failures). Follow this procedure:
  1. Check if the project has a `buildgit` skill installed (look for a `SKILL.md` in a `skill/buildgit/` directory) and a configured build job (e.g. `JENKINS_URL` is set, or a Jenkinsfile exists).
  2. **If buildgit is available and a build job is configured:** Run `buildgit status` (or equivalent) and verify the latest build result is SUCCESS with no test failures. If the build is failing, fix the issues and push again. Repeat until the build is GREEN. Do NOT proceed to mark the spec IMPLEMENTED while the build is broken.
  3. **If buildgit is NOT installed or no build job is configured:** This is acceptable — note it in the `#### Implementation Log` section  under `## CI/CD Verification` Proceed to the next step.

### 5c Work review report — 

- [ ] **Read the `workreview` skill** — locate `workreview/SKILL.md` (commonly under `.agents/skills/workreview/` or `.claude/skills/workreview/` in the repo or user skills path) and follow it completely.
- [ ] **Run workreview** — produce the implementation review report (default path: `specs/done-reports/{spec-basename}-review.md`.

If the `workreview` skill is missing from the environment, stop and report that as a **blocking** finalize failure — do not mark the spec IMPLEMENTED without the review artifact.

### 5d Update documentation and metadata

- [ ] **Update the spec file:** Change its `State:` field to `IMPLEMENTED` and add it to the spec index in `specs/README.md`.
- [ ] **Handle referenced files:** If the spec lists files in its `References:` header, move those files to `specs/done-reports/` and update the reference paths in the spec accordingly.
- [ ] **Run any additional project-specific finalize steps** as specified in the project's `CLAUDE.md` or `specs/CLAUDE.md`. This is the extension point where project-specific documentation updates, skill file updates, and custom push/CI commands are executed.

---

## Spec State Machine

- **DRAFT**: Spec written, not yet implemented.
- **IMPLEMENTED**: Code written, tests passing, docs updated, and the **workreview** report from Workflow 5c is produced before the `State:` field is set to this value. This is the normal post-implementation resting state and it is acceptable for a spec or its chunks to remain here indefinitely until a human validation pass happens.
- **VALIDATED**: Human has manually verified the implementation. Validation is a separate later step from implementation.

### IMPLEMENTED → VALIDATED

- Perform all manual testing to make sure the change does what it claims (human does this)
- Mark the `State:` of the spec to `VALIDATED`
- For chunked work, it is valid to move every completed chunk from `IMPLEMENTED` to `VALIDATED` in one later pass after the human verifies the integrated feature end-to-end. Do not require each chunk to be validated immediately after its implementation.
