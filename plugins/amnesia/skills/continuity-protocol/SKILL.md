---
name: continuity-protocol
description: How to silently use the amnesia handoff after a compaction, resume, or fresh-session restart. Use ONLY in recovery moments — when you see an amnesia handoff in your initial context, when the user references prior work absent from your context, or when you need a specific past detail (file contents, exact error, prior decision) you don't have. Never use during normal in-flow work, and never narrate the recovery to the user.
---

# amnesia continuity protocol

You are operating with the **amnesia** plugin installed. Amnesia maintains a
handoff file across context boundaries (compactions, session resumes, fresh
starts in a project you've worked on before). This skill tells you how to
recognize and use that surface.

## What amnesia gives you

A persistent markdown handoff file at:
`${CLAUDE_PLUGIN_DATA}/projects/<slug>/handoff/active.md`

where `<slug>` is the current `CLAUDE_PROJECT_DIR` with non-alphanumerics
replaced by `-`. The file contains, in this order:

1. **A recovery-protocol preamble** (this same protocol, restated).
2. **The Claude Code compaction summary** (if the trigger was a compaction).
3. **Files touched** since the last compact.
4. **Recent Bash commands** with exit codes.
5. **Verbatim recent user turns.**
6. (When L2 ran) **Working theory, decisions, open questions, in-flight task,
   files of interest, concrete next action.**

The file is overwritten by successive amnesia layers — assume it has the most
detail available at the time you read it.

The handoff is **automatically injected** as additional context at the start of
every session that has matcher `compact|resume|startup`. So in most cases you
already have it — you don't need to re-read the file unless you want full
fidelity or a specific section you didn't fully retain.

## Beyond the handoff: the full transcript is on disk

This is the most important fact in this skill.

Claude Code stores the entire conversation as a JSONL transcript at:
`~/.claude/projects/<slug>/<session-id>.jsonl`

This file is **append-only**. It is never truncated, even by compaction. Every
message, every tool call, every tool output that ever happened in the session
is still on disk in that file, byte-for-byte. Lines before the most recent
`compact_boundary` system entry are the *full* pre-compaction history that
your in-memory context window no longer contains.

**If you need a detail the handoff doesn't cover** — exact file contents you
read earlier, the precise error message you saw, a specific decision the user
made — `Read` the transcript directly. You can also use the amnesia walker:

```bash
# Use run-python.sh (not bare python3) — Claude's PATH often lacks Homebrew/pyenv.
PY="${CLAUDE_PLUGIN_ROOT}/scripts/run-python.sh"
W="${CLAUDE_PLUGIN_ROOT}/hooks/lib/jsonl_walker.py"
bash "$PY" "$W" tail <transcript> -n 20
bash "$PY" "$W" tail <transcript> -n 5 --role user --after-compact
bash "$PY" "$W" files <transcript>
bash "$PY" "$W" summary <transcript>
```

Don't re-derive lost work when you can recover it for the cost of one file read.

If you need a specific past detail and the handoff doesn't cover it, use the
`recall` MCP tool (amnesia ships one) instead of guessing — it greps across
all your handoffs.

Citations in the handoff like `[L:1234-1240]` are line ranges in the on-disk
JSONL transcript. Use `Read` on the transcript at those ranges to recover
exact bytes when needed.

## When to act

| Situation | What to do |
|---|---|
| You were just restored after a compaction (you see this skill or the handoff in your initial context) | Skim the handoff. If the "Concrete next action" line is specific, follow it. If something feels off, `Read` the transcript before proceeding. |
| You're resuming a session (source: resume) | Same as above — the handoff was machine-local and is gated by cwd + age. |
| The user references prior work and you have no memory of it | First check if a handoff was injected and you missed it. Then run `/amnesia:recall <topic>`. |
| You need exact prior content (a file you read, a command output, a user constraint) | `Read` the JSONL transcript. The walker's `tail` and `summary` subcommands help. |
| You hit a natural pause and want to safeguard against the next compact | Suggest running `/amnesia:snapshot` — it writes a manual high-fidelity handoff. |
| You learn a durable fact the user will want every session | Suggest `/amnesia:promote` — it writes the fact into project CLAUDE.md or auto-memory so it survives compaction natively, no plugin needed. |

## The Layer-3 refinement instruction

Sometimes on the first turn after a compaction you will receive a system
reminder asking you to refine the handoff before answering. This is amnesia
L3 — the highest-fidelity capture path. Honor it: spend ~30 seconds editing
`active.md` to fix what the mechanical/Haiku layers got wrong, then answer the
user normally. You have full context right now; the next-you who reads this
handoff after the next compaction will not. Write to *that* reader.

## What amnesia does NOT do

- It does not prevent compaction. Compaction is the harness's job; amnesia
  makes it survivable.
- It does not cross machines. The handoff file is machine-local.
- It does not replace project CLAUDE.md or auto-memory. Those are still the
  right surfaces for stable rules and learned facts — promote durable items
  there with `/amnesia:promote`. Amnesia owns the *acute* handoff slice.

## Anti-patterns

- Don't re-Read the handoff every turn. It was injected once at session start;
  unless you've forgotten it, the file on disk is the same thing.
- Don't paraphrase the handoff back to the user. Never say "based on the
  handoff…", "I see we were…", "according to amnesia…". Just act on it
  silently. The user already knows where they were — they don't need a recap.
- Don't update `active.md` mid-session yourself. The hooks own it (L2 enrich,
  L3 Stop refine, preempt at high context). Manual updates only via the
  explicit `/amnesia:snapshot` slash command.
