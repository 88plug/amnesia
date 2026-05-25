# amnesia — Design Doc

This document explains *why* amnesia is shaped the way it is. The findings
below were extracted from the installed Claude Code 2.1.150 bundle at
`/home/andrew/.local/share/claude/versions/2.1.150` plus the official docs at
`code.claude.com/docs`. Where the bundle and the docs disagreed, the bundle
won.

## 1. The problem

Claude Code maintains a single context window. As the window fills, Claude
Code automatically replaces the conversation with a one-shot LLM summary
(the *compaction*). The summary is good enough to keep going — but it
discards:

- exact tool inputs and outputs (Read contents, Bash stdout, Grep matches)
- exact prior assistant text and `<thinking>` blocks (the `<analysis>` block
  is explicitly stripped from the summary itself by `Xv_()` in the bundle)
- exact verbatim user phrasing outside the summary's "All user messages"
  paraphrase
- conversation ordering signals (the summary is thematic, not chronological)
- todo state, plan-mode plans, hook outputs, MCP discovery turns

The summary prompt is reproducible verbatim from the binary (byte offset
`131710721` in 2.1.150). It produces a 9-section markdown summary —
*Primary Request and Intent, Key Technical Concepts, Files and Code Sections,
Errors and fixes, Problem Solving, All user messages, Pending Tasks, Current
Work, Optional Next Step*. The summary then becomes a fake user message with
`isCompactSummary: true` and `isVisibleInTranscriptOnly: true`, and the new
context window starts from there.

The Claude Code docs admit this directly: *"Compaction replaces the conversation
with a structured summary. … It replaces the verbatim conversation: full tool
outputs and intermediate reasoning are gone. Claude can still reference the
work but won't have the exact code it read earlier."* The official escape hatch
is the *transcript path* — the post-compact prelude points the model at the
on-disk JSONL so it can `Read` what was lost.

amnesia's whole reason for existing is to make that escape hatch *easy and
reliable* — and to add a higher-fidelity handoff than the harness's generic
summary can provide.

## 2. The two enabling facts

Two non-obvious facts about Claude Code 2.1.150 make the design tractable.

### 2.1 The on-disk JSONL transcript is append-only

`~/.claude/projects/<slug>/<sessionId>.jsonl` is *never* truncated, even by
compaction. Verified empirically against a 12,565-line transcript with 4
compaction events on this machine: every pre-compaction message is still
byte-for-byte on disk. The `compact_boundary` system line is *appended*;
nothing earlier is rewritten. Claude Code's own message-chain walker
(`I8H` → `S5H`) rewrites `parentUuid` pointers on resume to *skip* the
pre-compaction prefix, but a plugin reading the raw JSONL gets the original
conversation back, intact.

This means **amnesia never has to duplicate content** — it can write a
handoff that *points* at the transcript, and the agent can `Read` for any
detail the handoff omits. Perfect recall on demand, zero context cost until
invoked.

### 2.2 The hook surface has the right shapes in the right places

- `PreCompact` fires before compaction. Can block. Cannot trigger a Claude
  action — only run shell. (Anthropic closed feature request #43733 — "let
  PreCompact trigger Claude to write the summary itself" — as not-planned.)
- `PostCompact` fires after compaction completes. Receives Anthropic's
  compaction summary as JSON stdin (`compact_summary` field). Observation
  only — does not feed `additionalContext` back into the live session.
- `SessionStart` with matcher `compact|resume|startup|clear` can emit
  `hookSpecificOutput.additionalContext` which is injected into the
  freshly-started session's first user message.
- `UserPromptSubmit` can emit additionalContext per user turn.
- `PostToolUse` can record everything tool-related continuously.
- All hooks receive `${CLAUDE_PLUGIN_ROOT}` (ephemeral, recreated on update)
  and `${CLAUDE_PLUGIN_DATA}` (persistent across updates, deleted only on
  uninstall) as environment variables.

The `additionalContext` field has **no hard byte cap** in 2.1.150
(`additionalContextChars` is logged but not enforced). The community
"10K char cap" claim was a docs-era constraint that the current binary no
longer enforces; amnesia stays under ~18KB anyway to be polite to the
context budget.

## 3. The architecture amnesia ships (v0.2.0)

```
                  +-----------------------+
   PostToolUse → | working-state.jsonl   |  ← continuous, ~0 cost, <50ms
                  +-----------------------+

   UserPromptSubmit (every turn, async) →
       +---------------------------------------+
       | preempt: if bytes-since-last-compact  |  ← async; runs at most ONCE
       | ≥ 2MB AND not done this cycle:        |    per compact cycle.
       |   claude -p Opus 4.7 --effort max     |    Captures state BEFORE
       |   (isolated; CLAUDE.md+auto-mem off)  |    compaction fires.
       |   → active.md                         |
       +---------------------------------------+

   compaction fires
   PreCompact (unused — shell-only, can't trigger model)

   PostCompact → +-------------------------------+
   (sync)        | L1 mechanical bash hook       |  ← <500 ms, $0, always runs
                 |   reads transcript tail       |
                 |   reads working-state         |
                 |   writes active.md            |
                 |   drops need-l3-enrichment    |
                 |   re-arms preempt marker      |
                 +-------------------------------+
   PostCompact → +-------------------------------+
   (async)       | L2 enrich bash hook (async)   |  ← non-blocking; ~45s async
                 |   claude -p Opus --effort max |
                 |   (isolated)                  |
                 |   overwrites active.md        |
                 +-------------------------------+

   first Stop after compact (async, consumes need-l3-enrichment marker) →
       +---------------------------------------+
       | L3 refine: claude -p Opus --effort   |  ← async; runs ONCE after
       | max (isolated), reads existing       |    the first post-compact
       | handoff + 32KB transcript tail       |    turn finishes. Captures
       | (including just-finished post-compact|    insight from that turn.
       | turn) → overwrites active.md         |
       +---------------------------------------+

   session resumes / next turn →
       SessionStart(compact|resume|startup) → cats active.md into
                                              additionalContext
```

Across compactions the same `active.md` is rewritten in place, with each
generation also archived under `handoff/archive/`. The `archive/` is what you
audit when you suspect drift: compare consecutive snapshots to see what each
layer added.

### Why four layers (L1 + L2 + L3 + preempt)?

| Failure mode | Layer that catches it |
|---|---|
| `claude -p` is unreachable or hangs | L1 ran first, sync, with no LLM — handoff exists |
| Compact happens while you're typing the next prompt | preempt already captured pre-compact state, then L1 captures post |
| L2's bounded 16KB tail missed something important | L3 sees a wider tail + the first post-compact turn the model just performed |
| The first post-compact turn surfaces a new constraint | L3 captures it for the NEXT compact |

The first session after install only gets L1 + L2 + preempt. The second gets
L3-refined-from-first too. Quality grows monotonically.

### Why Opus 4.7 `--effort max` instead of Haiku?

v0.1.0 defaulted to Haiku 4.5 based on per-token API cost analysis (~$0.028
cold, ~$0.004 warm). **This was solving the wrong problem on a subscription
plan**: `claude -p` on subscription uses your OAuth credentials and draws
from plan quota, not API tokens. There's no dollar cost difference between
Haiku and Opus on subscription — only a plan-quota cost.

Verified empirically (2026-05-24, single L2 invocation on a real transcript
tail):

- Opus 4.7 `--effort max`: ~33K cache-creation + ~21K cache-read + ~3K output
  tokens. ~$0.20 informational ($0 billed). ~45s wall-clock.
- Quality: vastly better than Haiku for the handoff task. Faithful, specific,
  grounded.

So v0.2.0 strips the Haiku default and uses the user's main model at
`--effort max`. Configurable via `AMNESIA_EFFORT` env var.

### Why isolation matters

Full `claude -p` mode loads `~/.claude/CLAUDE.md`, project `CLAUDE.md`,
auto-memory, and any auto-triggered skills. v0.1.0's first realistic test
produced a handoff about "intermittent SSH timeouts across the sidecar.network
WireGuard relay fleet" — content that wasn't in the input but was in the
user's CLAUDE.md.

`--bare` would solve this cleanly but is OAuth-incompatible (`--help`:
"Anthropic auth is strictly `ANTHROPIC_API_KEY` … OAuth and keychain are
never read"). On subscription, `--bare` is unavailable.

v0.2.0 isolates via three layers of defense:

1. `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` — skip CLAUDE.md loading
2. `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` — skip auto-memory loading
3. `--append-system-prompt` with explicit instruction: "summarize ONLY what
   is literally in the user message. Never reference any other project,
   codebase, or context. If the input does not state it, do not write it."

Re-tested empirically: the same input that hallucinated WireGuard content
now produces a fully grounded handoff. Every claim traces to the input. The
Concrete-next-action line even correctly identified the meta-question I was
holding ("verify whether OVH references appear verbatim in the tail").

### Why L3 moved from UserPromptSubmit to Stop+async

v0.1.0's L3 fired on `UserPromptSubmit` — it injected a system reminder
telling the model "before answering, refine active.md." Visibly, the user
saw Claude pause for 5–10 s reading and editing a file before responding to
their actual question.

v0.2.0's L3 fires on `Stop` with `async: true` — after the model has already
replied to the user. A separate `claude -p` then does the refinement in the
background. The user sees nothing.

The trade-off: instead of the main model refining the handoff (full context),
a separate Opus call refines it from the JSONL tail. Slightly lower fidelity
than v0.1.0's L3 in theory, but invisible and reliable instead of visible
and adherence-dependent.

### Why `bash` hooks throughout, not `prompt`-type?

Claude Code 2.1.150 supports five hook types: `bash`, `prompt` (direct
in-binary LLM call), `agent` (subagent), `http`, `mcp_tool`. The `prompt`-type
would in theory let L2 skip the `claude -p` shell-out — but the output
channel for `prompt`-type hooks on observational events like `PostCompact`
is undocumented and unexercised by any plugin in the public catalog. Using
`bash` throughout gives us:
- Confirmed working semantics (every official plugin uses `bash`).
- Full control over the output file path and atomic writes.
- Easy debugging (we own the I/O and can log freely).
- Graceful degradation — if `claude -p` fails, L1's output is still on disk.

## 4. What we chose not to build

| Considered | Verdict |
|---|---|
| Pre-emptive UserPromptSubmit at 80% capacity ("model, write your own handoff *now*") | High fidelity but ~15% miss rate, and no reliable way for the hook to see token usage in 2.1.150. Kept as a fallback via `/amnesia:snapshot` skill instead. |
| Auto-memory substrate (write handoff into `~/.claude/projects/<slug>/memory/`) | Only `MEMORY.md` (200-line/25KB index) is auto-loaded after compaction. Topic files load on-demand via the `memory_recall_select` subagent, not reliably. Wrong-shaped for compact handoff. |
| `asyncRewake: true` to inject a system reminder after L2 completes | Promising — rewakes the model with the L2-enriched handoff at exactly the right moment — but adds invasive interrupt semantics. Worth A/B testing in v0.2. |
| Vector DB / Chroma / embedding store | Overkill for the acute compaction slice. The JSONL is already perfectly indexed by message uuid + chronology; grep is fast enough. |
| Cross-machine sync built in | Out of scope. The user can git or rsync the state dir themselves. |
| Intercept `/compact` to rewrite as `/clear` + handoff | Slash commands aren't hookable. who96's "supervisor wrapper" approach is fragile — we just make `/compact` survivable instead. |

## 5. How amnesia differs from existing tools

| Tool | Mechanism | Why amnesia is different |
|---|---|---|
| **claude-mem** (40k+ stars) | Bun worker + Chroma + SQLite + 4 MCP tools + 5 hooks | Heavy (Bun + uv + Chroma daemon). Cross-session knowledge store — overlaps with native auto-memory. amnesia is single-process Bash + Python, owns only the acute compaction slice. |
| **mem0** | Cloud memory layer + MCP | Cloud dependency. amnesia is machine-local by design. |
| **basic-memory** | Plain-markdown KB + SQLite/FAISS via MCP | Knowledge-base oriented. amnesia is task-state oriented. |
| **claude-code-context-handoff** (who96) | PreCompact + SessionEnd + SessionStart bash hooks; supervisor wrapper rewrites `/compact`→`/clear` | Closest mechanism. Captures *mechanically* (last-15 messages + dedup), no semantic layer. amnesia adds Haiku-enriched L2 + main-model L3 + uses the JSONL transcript as authoritative recall surface rather than re-summarizing in-memory. |
| **thepushkarp/handoff** | PreCompact + SessionStart(compact) + Stop hooks; auto-handoff at 90%; placeholder-blocking Stop hook | Stronger workflow (Stop-blocks until handoff is complete). amnesia trades that strictness for layered redundancy — if any layer fails, the next still works. |
| **Cline Memory Bank** (6-file structure ported to Claude Code) | `activeContext.md` + 5 others, read at every session start | Different scope: a project-knowledge memory bank. amnesia handles the acute boundary; `/amnesia:promote` is the bridge for things that should live in the bank. |

The unique slice amnesia owns: **semantic-quality handoff at the moment of
compaction, layered so the cheap path always works and the expensive path
opportunistically upgrades, with the on-disk transcript as the always-available
ground truth.** No other tool we surveyed does all three.

## 6. Files & ground-truth references

- Claude Code 2.1.150 binary (ELF, ~238MB): `/home/andrew/.local/share/claude/versions/2.1.150`
- Full summarization prompt: byte offset `131710721` (and `231028532`) — extracted verbatim
- Post-compact prelude builder (`L0$`): byte offset ~`231034000`
- Threshold math (`Cf4`/`v0$`/`Wf4`): byte offsets `231087709`–`231101800`
- Microcompaction (`PX4`/`Ag6`/`NT$`): byte offset ~`231637003`
- `/compact` command definition (`ou_`): byte offset ~`231895200`
- `/context` definitions (`uc6`/`mc6`): byte offset `232295367`
- Hook event names (presence confirmed via `strings`): `PreCompact`, `PostCompact`, `SessionStart`, `SubagentStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `Notification`, `PermissionRequest`, `SessionEnd`
- Anthropic memory tool spec: https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool.md
- Context window doc: https://code.claude.com/docs/en/context-window
- Hooks reference: https://code.claude.com/docs/en/hooks
- Plugin reference: https://code.claude.com/docs/en/plugins-reference
- Anthropic engineering blog "Effective context engineering for AI agents"
- Anthropic engineering blog "Effective harnesses for long-running agents"

## 7. Open questions for v0.3+

1. **Empirically measure L3-Stop quality vs L1+L2.** v0.1.0's L3 used the main
   model with full context; v0.2.0's L3 uses an isolated `claude -p`. Compare
   the handoffs L3 produces vs L2 against the same transcripts and see if L3
   is materially better than just running L2 again.
2. **`asyncRewake` for L2 delivery.** Skip the SessionStart route entirely;
   instead, L2 exits with code 2 + a rewakeMessage like "Continuity restored.
   Read `active.md`." Wakes the model at exactly the right moment but is more
   invasive.
3. **Cross-machine sync.** Opt-in `git`-based sync of the state dir, or
   integration with a user-configured remote.
4. **Multi-worktree handling.** Today the slug is computed from
   `CLAUDE_PROJECT_DIR` which differs per-worktree. That's correct for
   isolation but means each worktree builds its handoff independently. Worth
   thinking about a project-level handoff that all worktrees share.
5. **Auto-tune `AMNESIA_MAX_AGE_SECONDS`** based on how often the user
   resumes a project — short for actively-worked projects, long for
   intermittent ones.
6. **Skill suppression in the isolated summarizer.** Even with CLAUDE.md and
   auto-memory disabled, auto-triggered skills can still load and pollute
   context. The system-prompt pin handles this defensively, but a clean
   `--no-skills` flag would be better. File request upstream.
7. **Plan-quota accounting.** A single L2/L3/preempt call burns ~33K Opus
   tokens of plan quota. Heavy users with many compacts/day may want a
   `AMNESIA_BUDGET_TOKENS_PER_DAY` cap that drops to lower effort levels or
   skips enrichment once exceeded.
