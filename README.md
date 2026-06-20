<div align="center">

# amnesia

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/88plug/amnesia)

Context continuity for Claude Code — keep the agent's working state intact across every `/compact`, auto-compact, and resume.

[![plugin-validate](https://github.com/88plug/amnesia/actions/workflows/plugin-validate.yml/badge.svg)](https://github.com/88plug/amnesia/actions/workflows/plugin-validate.yml)
[![License: FSL-1.1-ALv2](https://img.shields.io/badge/license-FSL--1.1--ALv2-blue?style=flat)](LICENSE.md)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-8A2BE2?style=flat)](https://github.com/88plug/claude-code-plugins)
[![Docs](https://img.shields.io/badge/docs-online-2ea44f?style=flat)](https://88plug.github.io/amnesia/)

</div>

## Install

```sh
/plugin marketplace add 88plug/claude-code-plugins
/plugin install amnesia@88plug
```

> [!TIP]
> That is the whole setup. After install, amnesia runs entirely in the background — no commands to run, no files to manage, no visible interruptions.

## Quickstart (under 60 seconds)

1. Install with the two commands above.
2. Work normally. Let a `/compact` (or auto-compact) happen mid-task.
3. On the next turn, the agent already knows what it was doing — the working theory, the next action, the files in motion, and your most recent constraints — instead of resuming from a lossy summary.

To confirm amnesia is active, run `/amnesia:status` and you will see the captured handoff for the current project.

## What it does

When Claude Code's `/compact` (or auto-compact) fires, the model's working memory is replaced by a one-shot summary. Exact file contents, prior tool outputs, verbatim user constraints, and mid-task reasoning are all paraphrased away, so long sessions drift after every compact.

amnesia makes compaction non-destructive. It captures a structured handoff at every compaction boundary — and proactively before the next one — then re-injects it on the next session start. The agent resumes with explicit knowledge of:

- what it was just doing (working theory plus the concrete next action)
- which files were in motion and which commands had run
- the user's most recent constraints, verbatim
- the path to the on-disk JSONL transcript, which Claude Code never truncates, so any lost detail is recoverable for the cost of one `Read`

> [!NOTE]
> Recommended install is via the [88plug marketplace](https://github.com/88plug/claude-code-plugins). Installing directly from this repo also works but is less convenient and will not auto-update with curated releases.

## How it works

amnesia runs as background hooks. Each event is invisible to you.

| Event | When | Latency | What it does |
|---|---|---|---|
| Continuous capture | Every tool call | <50 ms sync | Appends a one-line record to `working-state.jsonl` |
| L1 mechanical | After every compaction | <500 ms sync | Writes a deterministic handoff from JSONL plus working-state |
| L2 enrich | After every compaction | ~30-60 s async | Opus 4.7 `--effort max` rewrites the handoff with narrative |
| L3 refine | First Stop after compaction | ~30-60 s async | Opus refines the handoff using what happened post-compact |
| Preemptive | At ~75% of context | ~30-60 s async | Snapshots state before the next compact, while it is still in the window |
| Restore | SessionStart (compact / resume / startup) | <100 ms sync | Cats the handoff into `additionalContext` for the next turn |

All summarization runs isolated from your `CLAUDE.md`, auto-memory, and auto-triggered skills (via `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` and `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` plus a strict system prompt). Without this, the summarizer hallucinates content from your global context — verified empirically and fixed in v0.2.0.

## Cost on subscription plans

Every summarizer invocation is `claude -p` against your OAuth credentials. On a Max-style subscription this does not bill per token in dollars; it draws from your plan quota.

<details>
<summary>Per-call cost detail (verified 2026-05-24)</summary>

Per L2/L3/preempt call:

- ~33K Opus 4.7 cache-creation, ~21K cache-read, ~3K output tokens
- ~$0.20 informational (zero actually billed on subscription)
- ~45 s wall-clock, fully async

In a heavy week (say 20 compacts, so ~50 summarizer calls counting L1/L2/L3/preempt): ~1-2M plan-quota tokens. Well under the limits of a Max plan.

</details>

## Slash commands

You rarely need these — amnesia works on its own. They are power-user escapes.

| Command | When you would use it |
|---|---|
| `/amnesia:snapshot [focus] [--deep]` | Force a high-fidelity handoff now, at a natural pause (preempt usually catches this automatically). |
| `/amnesia:recall <topic>` | The agent post-compact says it does not remember something you know happened. |
| `/amnesia:status` | Diagnose what amnesia is holding for this project: last handoff, working-state size, recent compaction events, hook health. |
| `/amnesia:promote <fact>` | Promote a permanent fact into project `CLAUDE.md` or auto-memory, so it survives compaction natively without amnesia. |
| `/amnesia:sessions [query] [--all-projects]` | List or search archived handoffs for this project (or all projects). |
| `/amnesia:diff [--from <p>] [--to <p>]` | Show what changed between the previous and current handoff. |
| `/amnesia:why <claim>` | Trace a claim in the current handoff back to the JSONL transcript line that produced it. |
| `/amnesia:migrate [--dry-run \| --execute]` | Consolidate amnesia state from orphaned data roots into the active one. |

amnesia also ships an MCP server exposing `recall` and `handoff_get` tools, so the agent can pull from the transcript or the current handoff on its own.

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `AMNESIA_EFFORT` | `max` | Override the `--effort` level for summarizer calls |
| `AMNESIA_MAX_AGE_SECONDS` | `86400` (24h) | Reject cross-session restore if the handoff is older than this |
| `AMNESIA_PREEMPT_THRESHOLD_BYTES` | `2000000` (~2 MB) | Bytes since the most recent `compact_boundary` at which preempt fires |

## What amnesia does not do

- No cross-machine sync. Files are machine-local. Use git or rsync if you need multi-machine continuity.
- No vector DB, no daemon, no Chroma, no Bun worker. Bash, Python, native hooks, and `claude -p`. Boring on purpose.
- No general knowledge store. Cross-session facts belong in project `CLAUDE.md` or auto-memory, which already survive compaction natively. amnesia owns the acute compaction-survival slice.
- No `/compact` interception. Slash commands are not hookable, so amnesia makes compaction survivable rather than trying to prevent it.

## Design rationale

See [`DESIGN.md`](DESIGN.md) for the long-form rationale, the binary investigation that informed it, the empirical tests that corrected the v0.1.0 design, and citations into the Claude Code 2.1.150 source.

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for guidelines, and [`CHANGELOG.md`](CHANGELOG.md) for release history.

## License

Licensed under the [Functional Source License, Version 1.1, ALv2 Future License](LICENSE.md) (`FSL-1.1-ALv2`).

You may use, copy, modify, and redistribute it for any purpose except a Competing Use — offering this software (or a substantially similar substitute) as a commercial product or service. Each released version automatically converts to the Apache License 2.0 on the second anniversary of its release date.

For commercial-use inquiries outside the Permitted Purpose: claude@cryptoandcoffee.com.
