# amnesia

> Context continuity across Claude Code compaction.

When Claude Code's `/compact` (or auto-compact) fires, the model's working
memory is replaced by a one-shot summary. Exact file contents, prior tool
outputs, verbatim user constraints, mid-task reasoning — all of it is
paraphrased away. The fresh context window starts with a summary that's good
enough to keep going, but not good enough to keep going *without losing
fidelity*. Long sessions drift after every compact.

**amnesia** is a Claude Code plugin that makes compaction non-destructive by
capturing a structured handoff at every compaction boundary and re-injecting
it on the next session start. The agent resumes with explicit knowledge of:

- what it was just doing (working theory + concrete next action)
- which files were in motion and which commands had run
- the user's most recent constraints, verbatim
- and — critically — the path to the on-disk JSONL transcript, which
  Claude Code never truncates, so any lost detail is recoverable for the
  cost of one `Read` call.

It's small (~600 lines of Bash + Python + Markdown), machine-local, requires
no daemon or vector DB, and lives entirely inside the standard
Claude Code plugin surface.

## Status

v0.1.0 — works on Claude Code **2.1.150** and likely the 2.1.x line.
Tested as a local-marketplace dev install.

## Quick install

```bash
# From this repo root:
/plugin marketplace add /home/andrew/amnesia
/plugin install amnesia@amnesia-dev
# In any session: confirm it loaded
/plugin
```

That's it. The next `/compact` (or auto-compact) writes a handoff. The next
session start (resume, fresh launch in this project, or the very next turn
after compaction) re-injects it.

## How it works

Three capture layers fire in order:

| Layer | Hook | Cost | Latency | Fidelity |
|---|---|---|---|---|
| **L1 mechanical** | `PostCompact` → bash | $0 | <500 ms | What/where/when |
| **L2 enrich** | `PostCompact` → bash + `async:true` (shells to `claude -p` Haiku) | ~$0.004 warm / $0.028 cold | non-blocking | + why/decisions |
| **L3 main-model refine** | `UserPromptSubmit` (one-shot via marker) | ~$0.05 marginal | 0 (amortized) | Highest — the freshly-restored main model edits the handoff while it has full context |

And one rehydration hook:

- `SessionStart` (matcher: `compact|resume|startup`) → cats the handoff
  into `additionalContext`. Cross-session restore is gated by `cwd` equality
  and a configurable age window (`AMNESIA_MAX_AGE_SECONDS`, default 24h).

Plus a continuous capture:

- `PostToolUse` (Read/Write/Edit/MultiEdit/Bash/Glob/Grep/WebFetch) →
  appends a one-line record to `working-state.jsonl`. Cheap, deterministic;
  L1 reads it to enumerate files touched and commands run.

## Slash commands

| Command | Purpose |
|---|---|
| `/amnesia:snapshot [focus]` | Force a high-fidelity handoff now — useful at natural pause points before risky compacts. |
| `/amnesia:recall <topic>` | Recover detail the handoff doesn't cover by reading the on-disk transcript. |
| `/amnesia:status` | Show what amnesia has captured for this project (handoff age, archive count, marker state, log tail). |
| `/amnesia:promote <fact>` | Write a durable fact into project CLAUDE.md or auto-memory so it survives compaction natively (no plugin needed). |

## Subagent

`@agent-amnesia:summarizer` — a Sonnet-based handoff summarizer the parent
agent can delegate to when it wants a deeper snapshot than `/amnesia:snapshot`
produces (e.g. before a long break).

## Skill

`continuity-protocol` — auto-triggers when context feels thin, when the user
references prior work, or right after a compaction. Teaches the model how to
read the handoff and how to fall back to the JSONL transcript when needed.

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `AMNESIA_MAX_AGE_SECONDS` | 86400 (24h) | Reject cross-session restore if the handoff is older. |
| `ANTHROPIC_API_KEY` | unset | If set, L2 uses `claude --bare -p` (no plugin/MCP startup tax — much faster and cheaper). If unset, L2 falls back to full `claude -p` which is OAuth-friendly but ~10x slower and ~7x costlier per cold call. |

## State layout

Per-project state lives under `${CLAUDE_PLUGIN_DATA}/projects/<slug>/`:

```
handoff/
  active.md                 # the live handoff (overwritten by L1 → L2 → L3 in order)
  archive/
    YYYYMMDDTHHMMSSZ-L{1|2}-{auto|manual}.md
working-state.jsonl         # append-only continuous capture
markers/
  need-l3-enrichment        # one-shot marker for the next UserPromptSubmit
logs/
  amnesia.log               # debug log
```

`<slug>` is your `CLAUDE_PROJECT_DIR` with non-alphanumerics replaced by `-`,
mirroring Claude Code's own `~/.claude/projects/<slug>/` layout.

## What amnesia explicitly does NOT do

- **No cross-machine sync.** Files are machine-local. Use git or rsync if you
  need multi-machine continuity.
- **No vector DB, no daemon, no Chroma, no Bun worker.** Bash + Python +
  native hooks. Boring on purpose.
- **No general "knowledge store."** Cross-session facts belong in project
  CLAUDE.md or auto-memory — both already survive compaction natively.
  Amnesia owns the *acute* compaction-survival slice.
- **No `/compact` interception.** Slash commands aren't hookable; we make
  compaction *survivable* rather than try to prevent it.

## Design rationale & research

See [`DESIGN.md`](./DESIGN.md) for the long-form rationale, the binary
investigation that informed it, and citations into the Claude Code 2.1.150
source.

## License

MIT
