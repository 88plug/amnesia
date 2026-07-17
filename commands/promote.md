---
description: Promote a fact from the current conversation into project CLAUDE.md or auto-memory so it survives compaction natively — no plugin needed.
allowed-tools: Read, Edit, Write, Glob, Bash(ls:*), Bash(cat:*), Bash(mkdir:*), Bash(printf:*), Bash(date:*)
argument-hint: "<the fact to promote, in one line>"
---

# Promote a fact into durable memory

The user has invoked `/amnesia:promote $ARGUMENTS`. The point of this command
is to escape amnesia's plugin-managed handoff entirely: a fact you write to
project-root `CLAUDE.md` or to auto-memory survives every compaction because
Claude Code re-injects those files from disk on every fresh context window.

## Decide the destination

Pick the right surface based on the fact's nature:

| Fact type | Destination | Why |
|---|---|---|
| Stable project convention, rule, architecture invariant | `<project root>/CLAUDE.md` (or `.claude/CLAUDE.md`) | Re-injected verbatim every session. Survives every compaction. |
| Learned constraint specific to your work style or recent feedback | `~/.claude/projects/<slug>/memory/feedback_<slug>.md` | Auto-memory; `MEMORY.md` index reloads each session up to 200 lines/25KB. |
| Ongoing-work fact / current-state pointer | `~/.claude/projects/<slug>/memory/project_<topic>.md` | Same auto-memory surface, project-typed. |
| External reference (URL, dashboard, ticket) | `~/.claude/projects/<slug>/memory/reference_<topic>.md` | Same. |

## Procedure

1. Read the user's fact: `$ARGUMENTS`.
2. Classify it using the table above. If ambiguous, ask the user one question
   (where to put it) before writing — never silently pick.
3. **For CLAUDE.md**: locate the project root via `${CLAUDE_PROJECT_DIR}` and
   use the `Edit` tool to append a one-line entry under the most relevant
   existing section (or add a new `## Notes` section if none fits). Keep it
   ≤ 200 lines total — promote, don't bloat.
4. **For auto-memory**: write a new `.md` file under
   `~/.claude/projects/<slug>/memory/` with YAML frontmatter:
   ```yaml
   ---
   name: <short-kebab-case-slug>
   description: <one-line summary>
   metadata:
     type: feedback | project | reference
   ---
   ```
   Then add one line to `MEMORY.md` in the same directory:
   `- [Title](file.md) — one-line hook`.
5. Confirm to the user: "Promoted `<fact>` to `<path>`. It will reload on every
   session start and survive compaction."

## What the user said

$ARGUMENTS
