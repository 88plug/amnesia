---
description: Recall detail the current handoff doesn't cover by reading the on-disk JSONL transcript. Use when context feels thin or a specific past detail is missing.
allowed-tools: Bash(ls:*), Bash(cat:*), Bash(grep:*), Bash(tail:*), Bash(head:*), Bash(jq:*), Bash(python3:*), Bash(find:*), Read, Grep
argument-hint: "<topic, file, command, or 'last <N> turns'>"
---

# Recall from the transcript

The user has invoked `/amnesia:recall $ARGUMENTS`. Recover the requested detail
from the on-disk session transcript, which Claude Code never truncates even
across compactions.

## Procedure

1. **Locate the transcript.** Claude Code stores per-session transcripts at
   `~/.claude/projects/<project-slug>/<session-id>.jsonl`, where the slug is
   the current working directory with every non-alphanumeric replaced by `-`.

   Find the most-recently-modified transcript for *this* project:

   `!`ls -t ~/.claude/projects/$(printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[^A-Za-z0-9]/-/g')/*.jsonl 2>/dev/null | head -3``

2. **Use the amnesia transcript walker** for structured queries (preferred over
   raw `grep` for typed extractions):

   `!`echo "Walker at: ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/cache/amnesia-dev/amnesia/latest}/hooks/lib/jsonl_walker.py"``

   Subcommands:
   - `python3 <walker> tail <transcript> -n 20` → last 20 turns as JSON
   - `python3 <walker> tail <transcript> -n 5 --role user` → last 5 user messages
   - `python3 <walker> tail <transcript> --after-compact` → only turns since last compaction
   - `python3 <walker> files <transcript>` → file paths touched, with ops
   - `python3 <walker> summary <transcript>` → most recent compact summary text

3. **For free-text queries**, fall back to `grep` on the JSONL — every message,
   tool input, and tool output is a single JSON line.

4. **Report back** with: the recovered detail, the line/timestamp it came
   from, and (if relevant) a one-line note on what was lost vs preserved by
   the last compaction.

## What the user asked for

$ARGUMENTS

Use the procedure above to recover that. Be concrete; cite exact text from the
transcript where possible. If the request is "last N turns" or similar, lean
on the walker's `tail` subcommand. If it's a specific topic, use `grep` to find
matching lines first, then `jq` to extract the readable content.
