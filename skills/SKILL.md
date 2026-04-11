---
name: workreview
description: >
  Generate implementation review reports. Use when: (1) invoked from the
  specmgr finalize step to produce the per-spec review report at
  specs/done-reports/{basename}-review.md. or (2) manual invokation. Triggers on "work review",
  "workreview", "implementation review report", "summarize branch",
  "summarize worktree", "review report for spec", or "generate review report".
metadata:
  tags: review, report, implementation, finalize, branch, summary, worktree
  platforms: Claude, ChatGPT, Gemini, Cursor
---

# Work Review Skill

Produces a reviewer-facing report that summarizes all work done in a given commit range. The report content uses a **single unified template** regardless of whether the skill is invoked from specmgr finalize or standalone — the only things that differ are the output filename and the default scope.

workreview does NOT track implementation details itself. It consumes the `#### Implementation Log` sections that specmgr writes into spec files and chunk plans during implementation, and consolidates them into the report.

---

## Two invocation modes

Both modes use the same report template. They differ only in output filename and default scope.

### Mode A — spec-finalize (called from specmgr)

Invoked from specmgr Workflow 3 (single-pass) or Workflow 4 (chunked) at the finalize step of a DRAFT → IMPLEMENTED transition.

- **Output file:** `specs/done-reports/{spec-basename}-review.md`
- **Example:** `specs/claim-domain-spec.md` → `specs/done-reports/claim-domain-spec-review.md`
- **Scope:** the commits implementing the spec (typically `main..HEAD` of the implementation branch)

### Mode B — standalone branch/worktree summary

Invoked directly by the user to summarize all work in a range of commits.

- **Output file:** `specs/done-reports/{branch}-workreview.md`
- **Example:** on branch `feature-auth` → `specs/done-reports/feature-auth-workreview.md`
- If the branch name contains `/` (e.g. `user/foo`), replace with `-` when forming the filename.
- **Scope:** determined by the scope detection rules below.

---

## Project customizations (always read first)

Before generating the report, read the project root `CLAUDE.md` (and `specs/CLAUDE.md` if present) and look for any workreview-specific customizations the project wants applied. These may include:

- Extra sections to include in the report
- Project-specific detection rules or exclusions
- Custom buildgit invocation flags
- Alternative output paths
- Project-specific summary instructions

Apply any customizations found. Customizations from the project CLAUDE.md take precedence over the defaults in this skill, but must still produce a report consistent with the unified template below.

---

## Scope detection

Determine the commit range in this order:

1. **If the user supplies a git range** (e.g. `v1.0..HEAD`, `main..feature-x`, `abc123..def456`), use it verbatim.
2. **Else if the current branch is not `main` or `master`**, default to `main..HEAD`.
3. **Else** (on `main` or `master` with no supplied range), scope is **all commits** (no range filter — use the full git log).

Record the resolved range at the top of the report under the `**Range:**` header field. Mode A typically falls into case 2 (implementation branch) and uses `main..HEAD`.

---

## Detection rules

### Specs implemented

Use BOTH detection methods and deduplicate:

1. **State transition scan:** scan the git diff in the range for any `*-spec.md` file whose `State:` line changed to `IMPLEMENTED`. These are the authoritative "newly implemented" specs.
2. **Touched-file scan:** list every `specs/**/*-spec.md` file modified in the commit range.

For each spec listed, include a one-line summary derived from the spec's title or first paragraph.

### Bugs fixed

A file indicates a bug fix if EITHER condition holds:

1. The spec file itself contains the word `bug` (case-insensitive) in its filename or body, OR
2. Any file listed in the spec's `References:` header contains the word `bug` (case-insensitive) in its filename or body.

List each matched bug alongside the spec that fixed it. If a bug is referenced but the spec isn't in the commit range, still list it if the referenced bug file was modified or removed in the range.

### Implementation logs

For every spec identified by the "Specs implemented" detection, locate its `#### Implementation Log` and capture the full content verbatim:

- **Non-chunked spec:** the `#### Implementation Log` section lives at the bottom of the spec file itself.
- **Chunked spec:** the spec has a `Chunkplan:` field pointing to `specs/{spec-basename}-chunkplan.md`. Each chunk in the chunk plan has its own `#### Implementation Log` subsection. Collect all of them in chunk order.

The Implementation Log is where specmgr already stores: existing-test-modification rows, compaction counts, skills used, CI/CD verification notes, key decisions, and any Spec-Backing-None flagged decisions. workreview does NOT duplicate these into top-level report sections — it embeds the Implementation Log verbatim and lets the reviewer read them in context.

### Git commits and build status

Invoke buildgit to produce a verbatim git-log-with-build-status section:

- **With a range:** run `buildgit status --gitlog={range}`
- **On main/master with no range:** run `buildgit status --gitlog`

Embed the raw output verbatim inside a fenced code block in the report. Do not reformat or parse it.

### Files changed and created

Derive from `git diff --name-status {range}`:

- **Files Changed:** entries with status `M` (modified). Alphabetical.
- **Files Created:** entries with status `A` (added). Alphabetical.
- Exclude temporary files, build artifacts, and generated output.

---

## Unified report template

This single template is used for both Mode A and Mode B. Only the title, filename, and default scope differ between modes.

````markdown
# Work Review: {spec title for Mode A, or branch name for Mode B}

**Mode:** `spec-finalize` or `standalone`
**Spec:** `specs/{spec-file}.md` (Mode A only; omit for Mode B)
**Range:** `{resolved git range, or "all commits" if on main/master with no range}`
**Branch:** `{branch}`
**Generated:** `{ISO 8601 date-time, America/Denver}`
**Implementer:** `{agent or human}` (Mode A only; omit for Mode B)

## Summary

{2–4 sentence high-level overview of what shipped in this range. For Mode A this summarizes one spec; for Mode B this aggregates across everything in the range.}

## Specs Implemented

- `specs/foo-spec.md` — {one-line summary}
- `specs/bar-spec.md` — {one-line summary}

If none, write: "No specs were implemented in this range."

## Bugs Fixed

- `specs/todo/some-bug-report.md` → fixed by `specs/somefix-spec.md`
- `specs/another-bug-spec.md` — {one-line summary}

If none, write: "No bug fixes identified in this range."

## Consolidated Summary

A top-level narrative rollup across all implemented specs in the range. This is the reviewer's fast-scan view — one or two bullet points per spec, highlighting the most notable outcome. Do NOT repeat compaction counts, skill lists, or test-modification tables here; those stay inside the embedded Implementation Logs below.

- **`specs/foo-spec.md`:** {1–2 sentence outcome}
- **`specs/bar-spec.md`:** {1–2 sentence outcome}

For Mode A with a single spec, this is a one-paragraph recap.

## Implementation Logs

One subsection per implemented spec, embedding the `#### Implementation Log` content verbatim from its source (spec file for non-chunked, chunk plan for chunked).

All existing-test-modifications, compaction counts, skills used, CI/CD verification notes, key decisions, and Spec-Backing-None flagged decisions live inside these embedded logs — they are NOT hoisted to separate top-level sections.

### `specs/foo-spec.md`

{verbatim `#### Implementation Log` content from the spec file}

### `specs/bar-spec.md` (chunked)

{For a chunked spec, embed each chunk's `#### Implementation Log` in chunk order:}

#### Chunk 1/N
{verbatim content from chunk plan}

#### Chunk 2/N
{verbatim content from chunk plan}

...

If no implementation logs are found in the range, write: "No implementation logs found in this range."

## Git Commits and Build Status

Verbatim output of `buildgit status --gitlog[={range}]`:

```
{verbatim buildgit output — do NOT reformat}
```

## Files Changed (alphabetical)

- `path/to/modified-file.ext`

List only project files that were modified (not created) in the commit range. Exclude temporary files, build artifacts, and generated output. Hotfixes and commits not tied to any spec are surfaced here and in the buildgit section above.

## Files Created (alphabetical)

- `path/to/new-file.ext`

List only new project files added in the commit range. Exclude temporary files, build artifacts, and generated output.

## Key Highlights

- {notable cross-cutting items, design decisions, trade-offs, or things worth explicit reviewer attention — beyond what the embedded Implementation Logs already cover}

## Project-Specific Sections

{Any additional sections required by the project's root CLAUDE.md workreview customizations go here. Omit this section entirely if the project CLAUDE.md adds none.}
````

---

## How the report is built

workreview is a one-shot report generator. It does not perform live logging during implementation — specmgr is responsible for writing the `#### Implementation Log` content as implementation progresses. workreview runs at finalize time (Mode A) or on user demand (Mode B) and consolidates what already exists.

Steps:

1. **Determine mode.** Mode A if invoked from specmgr finalize for a specific spec; Mode B otherwise.
2. **Read project customizations.** Read root `CLAUDE.md` (and `specs/CLAUDE.md`) for any workreview customizations and apply them to the steps below.
3. **Resolve the commit range** per the scope detection rules.
4. **Resolve the output filename:**
   - Mode A: `specs/done-reports/{spec-basename}-review.md`
   - Mode B: `specs/done-reports/{branch}-workreview.md` (replace `/` with `-` in branch name)
5. **Run the detection rules** to populate `## Specs Implemented` and `## Bugs Fixed`.
6. **For each implemented spec, locate and read its `#### Implementation Log`:**
   - Non-chunked: from the bottom of the spec file.
   - Chunked: from every chunk's `#### Implementation Log` in the chunk plan referenced by the spec's `Chunkplan:` field.
7. **Run `buildgit status --gitlog[={range}]`** and capture its output verbatim.
8. **Derive `## Files Changed` and `## Files Created`** from `git diff --name-status {range}`.
9. **Write the `## Consolidated Summary`** as a brief reviewer-facing rollup — do not duplicate metric data from the embedded Implementation Logs.
10. **Write the `## Key Highlights`** section for cross-cutting items not covered in any single Implementation Log.
11. **Write the report file** to the resolved output path.

If specmgr's `#### Implementation Log` content is missing or incomplete for a spec in the range, note it explicitly in the report under that spec's subsection (e.g. "Implementation Log not found — spec was marked IMPLEMENTED but no log is present"). Do not fabricate log content.
