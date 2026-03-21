# taskcreator

Use these instructions for breaking down a large specification. The main objective is to create a chunk plan markdown file that can be used later by the implementer to build the software. You are a software architect. Decompose the feature specification into LLM-sized implementation chunks.

Plan file naming, location, and Chunkplan header updates are defined in SKILL.md (Workflow 2).

## chunk plan format
- Use `chunk-template.md` (in this skill's references) for template of sample chunk of chunk plan
- Each chunk has a brief description, which has backing documentation in the referenced spec section
- Each chunk starts as an unmarked checkbox in the `## Contents` list at the top of the plan. This is the **only** place checkboxes appear.
- When a chunk has been implemented, its checkbox in the `## Contents` list is marked complete: `- [ ]` becomes `- [x]`.
- Chunk detail sections (`## Chunk Detail`) use plain `### Chunk N: Title` headings with **no checkbox prefix**. Never put `- [ ]` in the detail section — it creates duplicate checkboxes that break progress counting tools.
- Each chunk detail must include an `#### Implementation Log` subsection, initially empty. The implementing agent fills this in after completing the chunk (see chunk-template.md).

- The chunkplan must explicitly reference the parent spec file path in its header

## Goals
- Break down a large spec into smaller, independently runnable chunks or tasks of work. Chunk and task terms are used interchangeably.
- Each chunk of work must be buildable and testable on its own. See unit testing section below
- Each completed chunk of work must be able to be unit tested to verify that it does what it claims
- Try to minimize tight coupling between different chunks.
- Each chunk when implemented should result in new implementation code, not just documentation updates, or spec or planning updates.
- It is ok for the chunk to be new library code that is not reachable by the main entrypoint just yet.
- Dependencies between chunks should be well documented. e.g. If chunk B calls function from chunk A, that needs to be documented inside chunk B
- An implemented chunk that changes how an end user will use it needs to have documentation delivered along with it. For example, if you add a new option, flag or env setting to a shell script the usage section must also be changed to match.

## Agent Executability
- **Every chunk must be executable by an AI agent.** Chunks are not suggestions or optional guidance—they are concrete tasks that an agent will perform.
- Do not create chunks labeled as "investigation" or "manual" tasks that an agent might interpret as something to skip. If data gathering or API queries are needed, write the chunk with explicit instructions for how the agent should perform them (e.g., specific curl commands, API endpoints, environment variables to use).
- If implementing a chunk requires querying an external system (e.g., public API, database), include the exact commands or code the agent should execute. Reference any required credentials by environment variable name.
- Chunks should not rely on assumptions about system state. If a chunk needs to verify something before proceeding, include that verification step explicitly.
- If a chunk produces artifacts (e.g., fixture files, captured API responses), specify the exact output file path and format expected.
- Agents must attempt each chunk before concluding it cannot be done. If a chunk requires data gathering (API calls, file reads, etc.), the agent should execute those operations.

## Unit Testing
- Each chunk needs to have unit tests created alongside it to verify the code is working.
- Unit tests must be repeatable.
- Running a unit test should not create any side effects.
- A unit test should not use external systems or network communication to run.
- Implementation code must be a testable design. The code can be invoked from a unit test, not just the normal frontend entrypoint.
- Unit tests must be written with a goal of 80% test coverage
- Each test case written should document within the test itself the name of the spec and the section from which it was derived
- Implementation code must use a unit testing framework that is appropriate for the language used. Common frameworks include:
  - Bash shell scripts: bats-core
  - Java: JUnit 5 or Spock tests in Groovy
  - TypeScript: Jest
  - Groovy: Spock
  - Use the project's configured test runner as specified in the project's `CLAUDE.md` or `specs/CLAUDE.md`

## Definition of done
- all unit tests written as a part of this task have been executed and they pass
- all unit tests of the entire project also are still passing
- if you find that this new feature starts to cause the test failure of an existing test, use your judgement to examine and fix either the implementation code or the test code

## Size and Scope
- Decompose this specification into LLM-sized chunks.
- Each chunk must be implementable end-to-end within a single LLM session with a 200k-token context window, including any necessary code, tests, and documentation updates.
- A chunk may produce one or more files, but should be small enough that the full diff plus reasoning fits comfortably inside the context budget.
- Define explicit interfaces/contracts between packages (APIs, types, schemas, events), so packages can be implemented independently.

## Ordering and dependence
- The plan will not specify an order as to which chunks should be built first.
- The dependencies are documented so this decision of which chunk to build next can be deferred to implementation time.

## SPEC Workflow section (mandatory in every plan)

Every generated chunk plan must include a `## SPEC Workflow` section after the `## Chunk Detail` section. This section tells the implementing agent where to find the workflow rules. Include it verbatim (adjusting the spec file path):

```markdown
## SPEC Workflow

**Parent spec:** `<path-to-parent-spec-file.md>`

Read `specs/CLAUDE.md` for full workflow rules. The workflow below applies to chunk plan implementation.

### Initialize Workflow
- Run all unit tests before starting

### Per-Chunk Workflow (every chunk must follow these steps)

1. **Implement the chunk** as described in its Implementation Details section.
2. **Write or update unit tests** as described in the chunk's Test Plan section.
3. **Run all unit tests** and confirm they pass (both new and existing).
4. **Fill in the `#### Implementation Log`** for the chunk you implemented — summarize files changed, key decisions, and anything notable.
5. **Commit and push** per the project conventions. Use a commit message starting with `chunk N/T:` followed by a brief description.

### Finalize Workflow (after ALL chunks are complete)

After all chunks have been implemented, a finalize step runs automatically. The finalize agent reads the entire plan file (including all Implementation Log entries) and performs the finalize steps defined in the `specmgr` skill and in the project's `CLAUDE.md` or `specs/CLAUDE.md`.
```
