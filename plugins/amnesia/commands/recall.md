---
description: Recall detail the current handoff doesn't cover by reading the on-disk JSONL transcript. Use when context feels thin or a specific past detail is missing.
allowed-tools: Bash(ls:*), Bash(grep:*), Bash(tail:*), Bash(head:*), Bash(jq:*), Bash(python3:*), Bash(find:*), Bash(printf:*), Bash(sed:*), Bash(source:*), Bash(dirname:*), Read, Grep
argument-hint: "<topic, file, command, or 'last <N> turns'>"
---

# Recall from the transcript

The user has invoked `/amnesia:recall $ARGUMENTS`. Recover the requested detail
from the on-disk session transcript, which Claude Code never truncates even
across compactions.

If the amnesia MCP server is running, prefer the `recall` tool — it greps
across all handoffs and is faster than raw transcript scanning. Fall back to
the procedure below when the MCP tool is unavailable or the query needs
full transcript fidelity.

## Procedure

1. **Locate the transcript.** Claude Code stores per-session transcripts at
   `~/.claude/projects/<project-slug>/<session-id>.jsonl`, where the slug is
   the current working directory with every non-alphanumeric replaced by `-`.

   Find the most-recently-modified transcript for *this* project:

   `!`
   # Prefer the harness-injected root, else find any installed amnesia plugin.
   LIB="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh"
   [ -f "$LIB" ] || LIB="$(ls -t "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh 2>/dev/null | head -1)"
   [ -f "$LIB" ] && source "$LIB"

   SLUG="$(amnesia::slug 2>/dev/null || printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[^A-Za-z0-9]/-/g')"
   ls -t "$HOME/.claude/projects/$SLUG/"*.jsonl 2>/dev/null | head -3
   ``

2. **Use the amnesia transcript walker** for structured queries (preferred over
   raw `grep` for typed extractions):

   `!`
   # Resolve walker path via the plugin root.
   LIB="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh"
   [ -f "$LIB" ] || LIB="$(ls -t "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh 2>/dev/null | head -1)"
   WALKER="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$LIB")" 2>/dev/null)}/hooks/lib/jsonl_walker.py"
   printf 'Walker at: %s\n' "$WALKER"
   ``

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
