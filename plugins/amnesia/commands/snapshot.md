---
description: Force an amnesia handoff snapshot of the current context now, without waiting for a compaction. Useful at natural pause points.
allowed-tools: Bash(ls:*), Bash(stat:*), Bash(date:*), Bash(mkdir:*), Bash(printf:*), Bash(touch:*), Bash(source:*), Bash(dirname:*), Read, Write, Glob
argument-hint: "[optional focus, e.g. 'focus on the auth refactor'] [--deep]"
---

# Manual snapshot

The user has invoked `/amnesia:snapshot $ARGUMENTS`.

## Behaviour

**Default (no `--deep`)**: non-blocking. The bash block touches
`markers/force-snapshot` in the active state dir and returns immediately. The
next L2 hook execution (normally within ≤60 seconds) sees the marker, runs a
mechanical snapshot, and removes it. Run `/amnesia:status` after ~60s to
confirm the handoff was written.

**With `--deep`**: delegates to the `amnesia:summarizer` agent for a
high-fidelity snapshot. This is slower (LLM call) but produces richer output.
Use it before a long break, after a major architectural decision, or when
`/context` shows you are close to the auto-compact threshold.

## Step 1 — touch the force-snapshot marker

`!`
# Prefer the harness-injected root, else find any installed amnesia plugin.
LIB="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh"
[ -f "$LIB" ] || LIB="$(ls -t "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh 2>/dev/null | head -1)"
[ -f "$LIB" ] && source "$LIB"

STATE="$(amnesia::state_dir 2>/dev/null || printf '%s' "$HOME/.claude/plugins/data/amnesia/projects/unknown")"
mkdir -p "$STATE/markers"
touch "$STATE/markers/force-snapshot"
printf 'force-snapshot marker written to: %s/markers/force-snapshot\n' "$STATE"
printf 'The next L2 hook pass will write the handoff (within ~60s).\n'
printf 'Run /amnesia:status to verify.\n'
``

## Step 2 — if --deep was requested

If `$ARGUMENTS` contains `--deep`, delegate to the summarizer agent for a
richer handoff now:

Use the `Agent` tool with:
- subagent: `amnesia:summarizer`
- task: "Write a high-fidelity handoff snapshot. Focus: $ARGUMENTS (minus the --deep flag). Use the JSONL transcript walker and working-state tail."

The summarizer will write `active.md` directly and return a one-line
confirmation. Relay that confirmation to the user.

## Step 3 — tell the user

If `--deep` was NOT requested:

> Snapshot marker written. The handoff will land within ~60s (next L2 pass).
> Run `/amnesia:status` to verify.

If `--deep` WAS requested:

> Deep snapshot complete. (Relay the summarizer's one-line confirmation.)

User-provided arguments: $ARGUMENTS
