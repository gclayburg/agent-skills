---
name: specmgr
description: >
  Spec-driven development workflow manager. Use when: (1) creating a DRAFT spec
  from input files or raw ideas, (2) creating a chunk plan
  from a DRAFT spec, (3) implementing a DRAFT spec (DRAFT to IMPLEMENTED transition),
  or (4) managing spec state transitions. Triggers on "create spec", "draft spec",
  "implement spec", "chunk plan", "spec workflow", or references to *-spec.md files.
metadata:
  tags: spec, specification, workflow, implementation, planning, chunking
  platforms: Claude, ChatGPT, Gemini
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

- Filename format: `specs/YYYY-MM-DD_<name>-spec.md` (date in America/Denver TZ)
- The `<name>` portion is derived from the input file or feature name (e.g., `featurereport74.md` → `specs/2026-02-15_featurereport74-spec.md`)

### Spec template

Include the following fields at the top of every DRAFT spec:

```
## Title

- **Date:** `<ISO 8601 format with seconds, America/Denver timezone>`
- **References:** list of `<other-raw-report-path.md>` or `<none>`
- **Supersedes:** list of `<other-spec-file.md>`
- **Chunkplan:** `<path-to-chunkplan.md>` or `none`
- **Chunked:** `true` or `false`
- **State:** one of these valid values: `DRAFT`, `IMPLEMENTED`, `VALIDATED`
```

### Setting the `Chunked:` field

- Set to `true` if the spec should be broken into a chunk plan before implementation. Set to `false` if it can be implemented in a single pass.
- Consider `true` when: the spec touches many files across different subsystems, requires multiple independent features or phases, has complex test strategy spanning several areas, or would exceed what an agent can reliably implement and test in one session.
- Consider `false` when: the changes are mechanical/uniform (e.g., same pattern applied across many call sites), the scope is limited to one subsystem, or the spec is a straightforward bug fix.
- This is a recommendation for the human reviewer — the plan is not created until after review.

### Root cause analysis

If the raw issue is a bug or something broken, perform a root cause analysis and include that in the spec.

### Companion manual test plan

Always create a companion manual test plan file alongside the spec: `<spec-basename>-test-plan.md` (e.g., `2026-03-14_condense-build-header-spec.md` → `2026-03-14_condense-build-header-test-plan.md`). The test plan must contain concrete CLI commands that an agent can execute to verify the implementation works end-to-end against the real tool and environment. Link the test plan from a `## Manual Test Plan` section at the end of the spec (before the `## SPEC workflow` section).

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

---

## Workflow 3: Implement DRAFT Spec (DRAFT → IMPLEMENTED)

**Triggers:** "implement DRAFT spec...", "implement spec..."

When implementing a DRAFT spec or bug fix, follow these steps in order.

### Before writing code

- [ ] **Run all unit tests** and confirm they pass. Do not proceed if tests are failing.

### Implement the feature or fix

- [ ] **Write the code** as described in the spec's Specification section.
- [ ] **Write or update unit tests** as described in the spec's Test Strategy section.
- [ ] **Run all unit tests** and confirm they pass (both new and existing).

### Run manual test plan (if present)

- [ ] **Check if the spec references a manual test plan** (look for a `## Manual Test Plan` section or a companion `*-test-plan.md` file). If one exists, execute every test command in the plan against the real CLI tool and verify the results match the expected output. If any test fails, fix the code and re-run until all tests pass. Do not skip this step — unit tests alone are not sufficient to prove the implementation works end-to-end.

### Update documentation and metadata

- [ ] **Update the spec file:** Change its `State:` field to `IMPLEMENTED` and add it to the spec index in `specs/README.md`.
- [ ] **Handle referenced files:** If the spec lists files in its `References:` header, move those files to `specs/done-reports/` and update the reference paths in the spec accordingly.
- [ ] **Run any additional project-specific finalize steps** as specified in the project's `CLAUDE.md` or `specs/CLAUDE.md`. This is the extension point where project-specific documentation updates, skill file updates, and custom push/CI commands are executed.

---

## Spec State Machine

- **DRAFT**: Spec written, not yet implemented.
- **IMPLEMENTED**: Code written, tests passing, docs updated.
- **VALIDATED**: Human has manually verified the implementation.

### IMPLEMENTED → VALIDATED

- Perform all manual testing to make sure the change does what it claims (human does this)
- Mark the `State:` of the spec to `VALIDATED`

---

## Multi-chunk plan workflow tiers

When implementing a spec via a chunk plan, the workflow is split into two tiers:

**Initialize workflow** (runs before any chunks are implemented)
- Run all unit tests before starting

**Per-chunk workflow** (each chunk does these):
- Implement the chunk
- Write/update unit tests
- Run all unit tests
- Run manual test plan if the spec references one
- Fill in the chunk's `#### Implementation Log`
- Commit (with chunk number in message, e.g. `"chunk 3/5: implement feature X"`) and push

**Finalize workflow** (runs once after all chunks complete):
- Update CHANGELOG.md, README.md, and any other project documentation
- Update the spec file state to IMPLEMENTED
- Move reference files to `specs/done-reports/`
- Update CLAUDE.md if any user-facing interface changes
- Run any additional project-specific finalize steps (per project's CLAUDE.md)
- Push and verify CI

Single-spec implementation (without a plan) continues to do everything in one pass as described above.
