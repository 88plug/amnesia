# amnesia

> Context continuity across Claude Code compaction. Seamless by default.

When Claude Code's `/compact` (or auto-compact) fires, the model's working
memory is replaced by a one-shot summary. Exact file contents, prior tool
outputs, verbatim user constraints, mid-task reasoning — all of it is
paraphrased away. Long sessions drift after every compact.

**amnesia** is a Claude Code plugin that makes compaction non-destructive by
capturing a structured handoff at every compaction boundary (and proactively
*before* the next one) and re-injecting it on the next session start. The
agent resumes with explicit knowledge of:

- what it was just doing (working theory + concrete next action)
- which files were in motion and which commands had run
- the user's most recent constraints, verbatim
- and — critically — the path to the on-disk JSONL transcript, which
  Claude Code never truncates, so any lost detail is recoverable for the
  cost of one `Read` call.

After install, **you never need to do anything**. No commands to run, no
files to manage, no visible interruptions. The four slash commands are
power-user escapes you'll rarely reach for.

## Status

v0.2.0 — works on Claude Code **2.1.150**. Empirically tested against an
OAuth subscription using Opus 4.7 with `--effort max`.

## Quick install

```bash
/plugin marketplace add 88plug/amnesia
/plugin install amnesia@88plug
```

That's it. No environment variables, no API keys, no configuration. The
plugin uses your existing OAuth subscription and your default model.

> **Local development** (working on the plugin itself):
> `/plugin marketplace add /path/to/cloned/amnesia` then
> `/plugin install amnesia@88plug` — same marketplace name; the source is
> resolved from the local clone instead of GitHub.

## How it works

Four background events, all invisible to you:

| Event | When | Latency | What it does |
|---|---|---|---|
| **Continuous capture** | every tool call | <50 ms sync | Appends a one-line record to `working-state.jsonl` |
| **L1 mechanical** | after every compaction | <500 ms sync | Writes a deterministic handoff from JSONL + working-state |
| **L2 enrich** | after every compaction | async, ~30–60 s background | Opus 4.7 `--effort max` rewrites the handoff with narrative |
| **L3 refine** | first Stop event after compaction | async, ~30–60 s background | Opus refines the handoff using what just happened post-compact |
| **Preemptive** | UserPromptSubmit at ~75% of context | async, ~30–60 s background | Snapshots state *before* the next compact while everything's still in the model's window |
| **Restore** | SessionStart (compact / resume / startup) | <100 ms sync | Cats the handoff into `additionalContext` for the next turn |

All summarization runs **isolated** from your `CLAUDE.md`, auto-memory, and
auto-triggered skills (via `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` and
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` plus a strict system prompt). Without
this, the summarizer hallucinates content from your global context — verified
empirically and fixed in v0.2.0.

## Cost on subscription plans

Every summarizer invocation is `claude -p` against your OAuth credentials.
On a Max-style subscription this **does not bill per-token in dollars**; it
draws from your plan quota.

Per L2/L3/preempt call (verified 2026-05-24):
- ~33K Opus 4.7 cache-creation + ~21K cache-read + ~3K output tokens
- ~$0.20 informational (zero actually billed on subscription)
- ~45 s wall-clock, fully async

In a heavy week (say 20 compacts → ~50 summarizer calls counting L1/L2/L3/preempt):
~1–2M plan-quota tokens. Well under the limits of a Max plan.

## Slash commands (power-user escapes — rarely needed)

| Command | When you'd use it |
|---|---|
| `/amnesia:snapshot [focus]` | You're at a natural pause and want a high-fidelity handoff *right now* (the preempt usually catches this automatically). |
| `/amnesia:recall <topic>` | Claude post-compact says it doesn't remember something you know happened. (The skill teaches the agent to do this on its own; this is the manual fallback.) |
| `/amnesia:status` | Diagnose: what's amnesia holding for this project? Useful when debugging. |
| `/amnesia:promote <fact>` | Promote a permanent fact from the handoff into project `CLAUDE.md` or auto-memory, so it survives every compact natively without amnesia. |

## Subagent

`@agent-amnesia:summarizer` — a Sonnet-based handoff summarizer the parent
agent can delegate to when it wants a deeper snapshot. Rarely needed; the
preempt typically covers this.

## Skill

`continuity-protocol` — auto-triggers in recovery moments only (right after
compaction, when the user references prior work absent from context, when
specific past detail is needed). Teaches the agent how to silently use the
handoff and fall back to the JSONL transcript for anything missing. The
skill explicitly tells the model **not to narrate restoration** to you.

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `AMNESIA_EFFORT` | `max` | Override `--effort` level for summarizer calls. Drop to `xhigh` / `high` / `medium` / `low` if you want to spend less plan quota per compact. |
| `AMNESIA_MAX_AGE_SECONDS` | 86400 (24h) | Reject cross-session restore if the handoff is older than this. |
| `AMNESIA_PREEMPT_THRESHOLD_BYTES` | 2000000 (2 MB JSONL since last compact ≈ ~75% window) | Bytes since the most recent `compact_boundary` at which the preempt fires. Lower = earlier preempt. |

## State layout

Per-project state lives under `${CLAUDE_PLUGIN_DATA}/projects/<slug>/`:

```
handoff/
  active.md                       # the live handoff (L1 → L2 → L3 → preempt rewrites in order)
  archive/
    YYYYMMDDTHHMMSSZ-{L1|L2|L3|preempt}-{auto|manual}.md
working-state.jsonl               # append-only continuous capture
markers/
  need-l3-enrichment              # L1 drops; L3 (Stop hook) consumes
  preempt-done-this-cycle         # preempt drops; L1 clears on next compact (re-arm)
logs/
  amnesia.log                     # debug log
```

`${CLAUDE_PLUGIN_DATA}` resolves at runtime to
`~/.claude/plugins/data/amnesia-<marketplace>/` — for example,
`~/.claude/plugins/data/amnesia-88plug/` when installed from the public
88plug marketplace. (Claude Code uses `<plugin-name>-<marketplace-name>`,
which lets the same plugin from different marketplaces coexist.)

`<slug>` is your `CLAUDE_PROJECT_DIR` with non-alphanumerics replaced by `-`,
mirroring Claude Code's own `~/.claude/projects/<slug>/` layout. So a project
at `/home/andrew/amnesia` lands under `…/projects/-home-andrew-amnesia/`.

## What amnesia explicitly does NOT do

- **No cross-machine sync.** Files are machine-local. Use git or rsync if
  you need multi-machine continuity.
- **No vector DB, no daemon, no Chroma, no Bun worker.** Bash + Python +
  native hooks + `claude -p`. Boring on purpose.
- **No general "knowledge store."** Cross-session facts belong in project
  `CLAUDE.md` or auto-memory — both already survive compaction natively.
  Amnesia owns the *acute* compaction-survival slice.
- **No `/compact` interception.** Slash commands aren't hookable; we make
  compaction *survivable* rather than try to prevent it.

## Design rationale & research

See [`DESIGN.md`](./DESIGN.md) for the long-form rationale, the binary
investigation that informed it, the empirical tests that corrected the v0.1.0
design, and citations into the Claude Code 2.1.150 source.

## License

MIT
