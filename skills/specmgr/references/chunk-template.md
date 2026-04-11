# Chunk Template

Use this format for each chunk in a chunk plan.

---

## Template

```markdown
## Contents

| Status | Chunk   | Title            | Dependencies                    |
|--------|---------|------------------|----------------------------------|
| [ ]    | Chunk A | <Chunk A Title>  | Dependencies of chunk A, or NONE |
| [ ]    | Chunk B | <Chunk B Title>  | Dependencies of chunk B, or NONE |
| [ ]    | Chunk C | <Chunk C Title>  | Dependencies of chunk C, or NONE |
| [ ]    | Chunk N | <Chunk N Title>  | Dependencies of chunk N, or NONE |


## Chunk Detail

### Chunk N: <Chunk N Title>

#### Description

<Brief summary of what this chunk accomplishes>

#### Spec Reference

See spec [<Section Name>](./<spec-filename>.md#<anchor>) sections X.X-X.X.

#### Dependencies

- <List chunk dependencies, e.g., "Chunk M (<function or feature name>)">
- None (if no dependencies)

#### Produces

- `<path/to/source/file>`
- `<path/to/test/file>.<ext>`

#### Implementation Details

1. <First implementation step>:
   - <Sub-detail>
   - <Sub-detail>
2. <Second implementation step>:
   - <Sub-detail>
   - <Sub-detail>
3. <Additional steps as needed>

#### Test Plan

**Test File:** `test/<feature_name>.<ext>`

| Test Case | Description | Spec Section |
|-----------|-------------|--------------|
| `<test_case_name>` | <What is being tested> | X.X |
| `<test_case_name>` | <What is being tested> | X.X |

**Mocking Requirements:**
- <External dependencies to mock>

**Dependencies:** <Chunk dependencies needed for test setup>

#### Implementation Log

<!-- Filled in by the implementing agent after completing this chunk.
     Required fields:
     - Files changed, key decisions, anything the finalize step needs to know
     - Compaction events during this chunk: N (count of system-reminder compaction events observed during this chunk's agent run)
     - Skills used during this chunk: list of skills invoked via the Skill tool, or "None" -->
```

---

## Notes

- Replace all `<placeholder>` values with actual content
- Chunk numbers (N, M) should be sequential within the plan
- Spec anchors should match markdown heading IDs in the spec document
- Test case names should use snake_case
- Checkboxes (`- [ ]`) appear ONLY in the `## Contents` list, never in chunk detail headings — duplicate checkboxes break progress counting tools
- The `#### Implementation Log` subsection is filled in by the implementing agent (per chunk), not the plan creator.
