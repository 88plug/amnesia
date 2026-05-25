---
description: Force an amnesia handoff snapshot of the current context now, without waiting for a compaction. Useful at natural pause points.
allowed-tools: Bash(ls:*), Bash(cat:*), Bash(stat:*), Bash(date:*), Bash(mkdir:*), Bash(printf:*), Bash(tail:*), Bash(jq:*), Bash(python3:*), Read, Write, Glob
argument-hint: "[optional focus, e.g. 'focus on the auth refactor']"
---

# Manual snapshot

The user has invoked `/amnesia:snapshot`. Write a high-fidelity handoff for the
current session to the amnesia handoff file *before* the next compaction wipes
your working memory.

## What to capture

A markdown document in this exact structure (≤ 4000 chars):

```markdown
# amnesia handoff (manual, source=/amnesia:snapshot)

- captured: <ISO8601 UTC>
- focus: <user-provided focus from $ARGUMENTS, or "general">

## Working theory
One paragraph: what are you trying to accomplish right now?

## Decisions made (this session)
- Bullet list of decisions with one-sentence rationale each.

## Open questions / blockers
- Bullet list. Each item ends with "→ next step: …" when actionable.

## In-flight task
The single most recent thread of work — cite the file/command/test currently in motion.

## Files of interest
- `path` — why it matters in 8 words or fewer.

## Concrete next action
One sentence. Imperative voice. Cite a specific file/command/test.
```

Be specific. Quote file paths, error messages, and recent user constraints
verbatim. No fluff, no preamble.

## Where to write it

Resolve the handoff path via the plugin's shared helper so this command writes
to the same directory the hooks read from (the marketplace-suffixed
`amnesia-<marketplace>/` dir under `~/.claude/plugins/data/`, not the
unsuffixed legacy fallback):

`!`
for c in "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh" "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh "$HOME/amnesia/plugins/amnesia/hooks/lib/common.sh"; do
  [ -f "$c" ] && { source "$c"; break; }
done
STATE="$(amnesia::state_dir 2>/dev/null)"
mkdir -p "$STATE/handoff"
printf '%s\n' "$STATE/handoff/active.md"
``

Use the `Write` tool to write the document to that exact path (overwriting any
existing `active.md`). Then confirm to the user with the path and a one-line
summary of what you captured.

## Optional focus argument

If `$ARGUMENTS` is non-empty, treat it as a steering hint — what the user wants
emphasized in the handoff. Otherwise, snapshot generally.

User-provided focus: $ARGUMENTS
