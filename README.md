<div align="center">

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./.github/banner-dark.svg">
    <img src="./.github/banner-light.svg" width="720" alt="amnesia — context continuity for Claude Code" />
  </picture>

  <h3>Seamless context continuity across Claude Code compaction.</h3>

  [![version](https://img.shields.io/badge/version-0.2.3-000?style=for-the-badge)](./plugins/amnesia/.claude-plugin/plugin.json)
  [![license](https://img.shields.io/badge/license-FSL--1.1--ALv2-000?style=for-the-badge)](./LICENSE.md)
  [![claude code](https://img.shields.io/badge/claude%20code-2.1.150%2B-000?style=for-the-badge)](https://code.claude.com)
  [![marketplace](https://img.shields.io/badge/install-88plug-000?style=for-the-badge)](https://github.com/88plug/claude-code-plugins)
  [![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/88plug/amnesia)

</div>

```sh
/plugin marketplace add 88plug/claude-code-plugins
/plugin install amnesia@88plug
```

---

When Claude Code's `/compact` (or auto-compact) fires, the model's working memory is replaced by a one-shot summary. Exact file contents, prior tool outputs, verbatim user constraints, mid-task reasoning — all of it is paraphrased away. Long sessions drift after every compact.

**amnesia** makes compaction non-destructive by capturing a structured handoff at every compaction boundary (and proactively *before* the next one) and re-injecting it on the next session start. The agent resumes with explicit knowledge of:

- what it was just doing (working theory + concrete next action)
- which files were in motion and which commands had run
- the user's most recent constraints, verbatim
- and — critically — the path to the on-disk JSONL transcript, which Claude Code never truncates, so any lost detail is recoverable for the cost of one `Read` call

After install, **you never need to do anything**. No commands to run, no files to manage, no visible interruptions. The four slash commands are power-user escapes you'll rarely reach for.

> Recommended install is via the [88plug marketplace](https://github.com/88plug/claude-code-plugins). Installing directly from this repo also works but is less convenient and won't auto-update with curated releases.

## Demo

<!-- TODO: replace with an actual recording or GIF once captured -->
![amnesia restoring context after /compact — placeholder](./.github/demo.gif)

## How it works

Five background events, all invisible to you:

| Event | When | Latency | What it does |
|---|---|---|---|
| **Continuous capture** | every tool call | &lt;50 ms sync | Appends a one-line record to `working-state.jsonl` |
| **L1 mechanical** | after every compaction | &lt;500 ms sync | Writes a deterministic handoff from JSONL + working-state |
| **L2 enrich** | after every compaction | async, ~30–60 s background | Opus 4.7 `--effort max` rewrites the handoff with narrative |
| **L3 refine** | first Stop event after compaction | async, ~30–60 s background | Opus refines the handoff using what just happened post-compact |
| **Preemptive** | UserPromptSubmit at ~75% of context | async, ~30–60 s background | Snapshots state *before* the next compact while everything's still in the model's window |
| **Restore** | SessionStart (compact / resume / startup) | &lt;100 ms sync | Cats the handoff into `additionalContext` for the next turn |

All summarization runs **isolated** from your `CLAUDE.md`, auto-memory, and auto-triggered skills (via `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` and `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` plus a strict system prompt). Without this, the summarizer hallucinates content from your global context — verified empirically and fixed in v0.2.0.

## Cost on subscription plans

Every summarizer invocation is `claude -p` against your OAuth credentials. On a Max-style subscription this **does not bill per-token in dollars**; it draws from your plan quota.

Per L2/L3/preempt call (verified 2026-05-24):
- ~33K Opus 4.7 cache-creation + ~21K cache-read + ~3K output tokens
- ~$0.20 informational (zero actually billed on subscription)
- ~45 s wall-clock, fully async

In a heavy week (say 20 compacts → ~50 summarizer calls counting L1/L2/L3/preempt): ~1–2M plan-quota tokens. Well under the limits of a Max plan.

## Slash commands (power-user escapes — rarely needed)

| Command | When you'd use it |
|---|---|
| `/amnesia:snapshot [focus]` | You're at a natural pause and want a high-fidelity handoff *right now* (the preempt usually catches this automatically). |
| `/amnesia:recall <topic>` | Claude post-compact says it doesn't remember something you know happened. (The skill teaches the agent to do this on its own; this is the manual fallback.) |
| `/amnesia:status` | Diagnose: what's amnesia holding for this project? Useful when debugging. |
| `/amnesia:promote <fact>` | Promote a permanent fact from the handoff into project `CLAUDE.md` or auto-memory, so it survives every compact natively without amnesia. |

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `AMNESIA_EFFORT` | `max` | Override `--effort` level for summarizer calls |
| `AMNESIA_MAX_AGE_SECONDS` | `86400` (24h) | Reject cross-session restore if the handoff is older than this |
| `AMNESIA_PREEMPT_THRESHOLD_BYTES` | `2000000` (~2 MB) | Bytes since the most recent `compact_boundary` at which preempt fires |

## What amnesia explicitly does NOT do

- **No cross-machine sync.** Files are machine-local. Use git or rsync if you need multi-machine continuity.
- **No vector DB, no daemon, no Chroma, no Bun worker.** Bash + Python + native hooks + `claude -p`. Boring on purpose.
- **No general "knowledge store."** Cross-session facts belong in project `CLAUDE.md` or auto-memory — both already survive compaction natively. Amnesia owns the *acute* compaction-survival slice.
- **No `/compact` interception.** Slash commands aren't hookable; we make compaction *survivable* rather than try to prevent it.

## Design rationale

See [`DESIGN.md`](./DESIGN.md) for the long-form rationale, the binary investigation that informed it, the empirical tests that corrected the v0.1.0 design, and citations into the Claude Code 2.1.150 source.

## License

[Functional Source License, Version 1.1, ALv2 Future License](LICENSE.md)
(`FSL-1.1-ALv2`).

Free to use, copy, modify, and redistribute for any purpose *except* a Competing
Use — i.e. offering this software (or a substantially similar substitute) as a
commercial product or service. Each released version automatically converts to
the Apache License 2.0 on the second anniversary of its release date.

For commercial-use inquiries that fall outside the Permitted Purpose:
claude@cryptoandcoffee.com.
