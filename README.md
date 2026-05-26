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

v0.3.0 — works on Claude Code **2.1.150**. Empirically tested against an
OAuth subscription using Opus 4.7 with `--effort max`.

## Quick install

```bash
/plugin marketplace add 88plug/amnesia
/plugin install amnesia@88plug
/reload-plugins
```

That's it. No environment variables, no API keys, no configuration. The
plugin uses your existing OAuth subscription and your default model.

The `/reload-plugins` step is what Claude Code's docs call the supported
install-time activation path — it registers the plugin's hooks into the
live session so capture starts immediately. Without it, hooks only become
active in the *next* session you start. (Reference:
<https://code.claude.com/docs/en/discover-plugins>, "Apply plugin
changes without restarting".)

> **Local development** (working on the plugin itself):
> `/plugin marketplace add /path/to/cloned/amnesia` then
> `/plugin install amnesia@88plug` — same marketplace name; the source is
> resolved from the local clone instead of GitHub.

## How it works

Eight background events, all invisible to you:

| Event | When | Latency | What it does |
|---|---|---|---|
| **Continuous capture** | every tool call | <50 ms sync | Appends a one-line JSONL record to `working-state.jsonl`; secrets redacted inline |
| **PreCompact** | before every compaction | <100 ms sync | Tails last `AMNESIA_PRECOMPACT_TAIL_LINES` transcript lines into a sidecar for L1 to consume |
| **L1 mechanical** | after every compaction | <500 ms sync | Bash-only handoff from JSONL + working-state + git state + citation ranges; always runs |
| **L2 enrich** | after every compaction | asyncRewake, ~30–60 s | Opus 4.7 `--effort max` rewrites the L1 handoff with narrative; surfaces mid-session via rewake |
| **L3 refine** | first Stop event after compaction | asyncRewake, ~30–60 s | Opus refines using the first post-compact turn; L2/L3 race is serialized via lock |
| **Preemptive** | UserPromptSubmit at ~75% of context | async, ~30–60 s | Snapshots state *before* the next compact fires; runs at most once per compact cycle |
| **SubagentStart** | every subagent spawn | <50 ms sync | Injects a trimmed handoff (max 3 KB) as `additionalContext` for the subagent |
| **SessionEnd** | session teardown | <100 ms sync | Final no-LLM snapshot if needed; appends to `sessions.json` index; rotates working-state |
| **Restore** | SessionStart (compact / resume / startup) | <100 ms sync | Cats `active.md` into `additionalContext`; drift-warns if git state changed since the handoff was written |

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
| `/amnesia:snapshot [focus]` | You're at a natural pause and want a high-fidelity handoff *right now* (non-blocking; pass `--deep` to delegate to the summarizer subagent). |
| `/amnesia:recall <topic>` | Claude post-compact says it doesn't remember something you know happened. (The skill teaches the agent to do this on its own; this is the manual fallback.) |
| `/amnesia:status` | Diagnose: data roots, L2/L3 success rates, in-flight marker state, today's budget usage. |
| `/amnesia:promote <fact>` | Promote a permanent fact from the handoff into project `CLAUDE.md` or auto-memory, so it survives every compact natively without amnesia. |
| `/amnesia:sessions [query]` | Search across all archived handoffs for this project (add `--all-projects` to search every project). |
| `/amnesia:migrate` | Consolidate orphan data roots from old marketplace installs. Use `--dry-run` first, then `--execute`. |
| `/amnesia:diff` | Diff two handoff versions. Pass `--from <ts>` and `--to <ts>` to compare specific archives. |
| `/amnesia:why <claim>` | Trace a handoff claim back to its source transcript lines via `[L:N-M]` citation ranges. |

## MCP server

amnesia ships a read-only **stdio JSON-RPC MCP server** at
`plugins/amnesia/mcp/server.py`. It runs on Python 3.6+ with no external
dependencies (pure stdlib). Claude Code registers it automatically via the
plugin's `mcpServers` declaration; you don't need to configure it.

### Tools

| Tool | Args | What it returns |
|---|---|---|
| `recall` | `query` (string), `max_results` (int, default 10), `scope` (`current_project` \| `all_projects`) | Matches from the active handoff, archived handoffs, and gzipped working-state archives — `{path, line_number, snippet, project_slug, mtime}` ordered by recency. Capped at 32 KB total / 4 KB per snippet. |
| `handoff_get` | `session_id` (optional), `project` (optional) | Full markdown of the active handoff (default) or a specific archived handoff. |

`recall` is the primary tool. The continuity-protocol skill teaches the agent
to call it automatically when context feels thin — you don't need to invoke it
manually. `handoff_get` is for when you want the full handoff document in
context rather than search results.

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

All env vars are optional with sensible defaults. Set them in your shell
profile or project `.env` file — amnesia reads them at hook execution time.

| Env var | Default | Effect |
|---|---|---|
| `AMNESIA_EFFORT` | `max` | Override `--effort` level for summarizer calls. Drop to `xhigh` / `high` / `medium` / `low` to spend less plan quota per compact. |
| `AMNESIA_MAX_AGE_SECONDS` | 86400 (24h) | Reject cross-session restore if the handoff is older than this. |
| `AMNESIA_PREEMPT_THRESHOLD_BYTES` | 2000000 (~2 MB JSONL ≈ 75% window) | Bytes since the most recent `compact_boundary` at which the preempt fires. Lower = earlier preempt. |
| `AMNESIA_DAILY_BUDGET_TOKENS` | 5000000 (~5 MB) | Daily prompt-byte cap. When exceeded, the summarizer downgrades from `max` to `medium` effort automatically. |
| `AMNESIA_WS_MAX_LINES` | 5000 | `working-state.jsonl` line cap. Older lines rotate to `logs/archive/` as gzipped JSONL. |
| `AMNESIA_ARCHIVE_KEEP` | 50 | Maximum entries kept in `handoff/archive/`. Oldest are pruned automatically. |
| `AMNESIA_PRECOMPACT_TAIL_LINES` | 1000 | Lines of transcript snapshotted by the `PreCompact` hook sidecar. |
| `AMNESIA_SUBAGENT_CONTEXT_BYTES` | 3000 | Byte cap for the handoff snippet injected into spawned subagents. |
| `AMNESIA_SUMMARY_MIN_BYTES` | 500 | Sanity check lower bound — handoffs smaller than this are rejected and L1 is kept. |
| `AMNESIA_SUMMARY_MAX_BYTES` | 8000 | Sanity check upper bound — handoffs larger than this are rejected. |
| `AMNESIA_SYNC_REMOTE` | (unset) | Git remote URL. When set, enables cross-machine sync (see below). |

## State layout

Per-project state lives under `${CLAUDE_PLUGIN_DATA}/projects/<slug>/`:

```
handoff/
  active.md                       # the live handoff (L1 → L2 → L3 → preempt rewrites in order)
  archive/
    YYYYMMDDTHHMMSSZ-{L1|L2|L3|preempt}-{auto|manual}.md
working-state.jsonl               # append-only continuous capture (auto-rotates at 5000 lines)
markers/
  need-l3-enrichment              # L1 drops; L3 (Stop hook) consumes
  preempt-done-this-cycle         # preempt drops; L1 clears on next compact (re-arm)
  l2-in-flight                    # L2 sets; L3 waits up to 90 s for it to clear
  pre-compact-snapshot.jsonl      # PreCompact sidecar; L1 consumes
logs/
  amnesia.log                     # debug plaintext log
  events.jsonl                    # structured JSONL event log (success rates, budget, timings)
  budget-YYYYMMDD.txt             # daily prompt-byte accumulator
  archive/
    working-state-YYYYMMDDTHHMMSSZ.jsonl.gz   # rotated working-state segments
sessions.json                     # index of all archived sessions (capped at 200 entries)
```

`${CLAUDE_PLUGIN_DATA}` resolves at runtime to
`~/.claude/plugins/data/amnesia-<marketplace>/` — for example,
`~/.claude/plugins/data/amnesia-88plug/` when installed from the public
88plug marketplace. (Claude Code uses `<plugin-name>-<marketplace-name>`,
which lets the same plugin from different marketplaces coexist.)

`<slug>` is your `CLAUDE_PROJECT_DIR` with non-alphanumerics replaced by `-`,
mirroring Claude Code's own `~/.claude/projects/<slug>/` layout. So a project
at `/home/andrew/amnesia` lands under `…/projects/-home-andrew-amnesia/`.

## Cross-machine sync (opt-in)

Set `AMNESIA_SYNC_REMOTE` to any git remote URL and amnesia will git-track
your entire data root, pulling before each session starts and pushing after
each session ends.

```bash
export AMNESIA_SYNC_REMOTE=git@github.com:you/amnesia-state.git
```

The remote must exist and be push-able. amnesia uses your existing SSH or
HTTPS credentials — it does not manage authentication. On the second machine,
set the same env var; amnesia will clone the remote on first session start if
the local data root does not yet exist.

**This is off by default.** Not setting `AMNESIA_SYNC_REMOTE` means all state
stays machine-local, exactly as in v0.2.x.

## What amnesia explicitly does NOT do

- **Cross-machine sync is OPT-IN.** Files are machine-local by default. Set
  `AMNESIA_SYNC_REMOTE` (see above) if you need multi-machine continuity.
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
