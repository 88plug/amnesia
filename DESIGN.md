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

## 3. The architecture amnesia ships

```
                  +-----------------------+
   PostToolUse → | working-state.jsonl   |  ← continuous, ~0 cost
                  +-----------------------+
                              |
   compaction fires           v
   PreCompact (skipped)
   PostCompact → +--------------------------+
                 | L1 mechanical bash hook  |  ← <500 ms, $0, always runs
                 |   reads transcript tail  |
                 |   reads working-state    |
                 |   writes active.md       |
                 |   drops L3 marker        |
                 +--------------------------+
   PostCompact → +--------------------------+
   (async)       | L2 bash hook (async)     |  ← non-blocking; ~$0.004 warm
                 |   shells to claude -p    |
                 |   Haiku 4.5              |
                 |   overwrites active.md   |
                 +--------------------------+
                              |
   session resumes / next turn
   SessionStart(compact) →  reads active.md → emits additionalContext
   UserPromptSubmit (1st post-compact turn, consumes L3 marker) →
                            injects "refine the handoff" instruction
   ↓
   Main model edits active.md (L3) with its full restored context.
```

Across compactions the same `active.md` is rewritten in place, with each
generation also archived under `handoff/archive/`. The `archive/` is what you
audit when you suspect drift: compare consecutive snapshots to see what each
compaction added vs lost.

### Why three layers and not one?

| If you only had L1 (mechanical) | If you only had L2 (Haiku) | If you only had L3 (main model) |
|---|---|---|
| Fast and free, but no "why." Loses the conceptual thread. | ~$0.004–$0.028/compact, decent, but blocks for 6–10s if not async, and Haiku misses nuance. | Highest fidelity in theory, but ~15% miss rate (model may ignore the system reminder), and fires only on the *next* turn — first response post-compact gets no benefit. |

The three layered together cover each other's failure modes:
- L1 always runs in <500ms with no LLM, guaranteeing *something*.
- L2 (async) enriches L1 with narrative in the background. If `claude -p`
  fails for any reason, L1 stays in place.
- L3 fires on the first post-compact turn while the main model has full
  context — its edits prepare the handoff for the *next* compaction.

The first session after install only gets L1. The second gets L1+L2. The
third gets L1+L2+L3-refined-from-second. Quality grows with use.

### Why `bash` hooks throughout, not `prompt`-type?

Claude Code 2.1.150 supports five hook types: `bash`, `prompt` (direct
in-binary LLM call), `agent` (subagent), `http`, `mcp_tool`. The
`prompt`-type would in theory let L2 skip the `claude -p` shell-out — but
the output channel for `prompt`-type hooks on observational events like
`PostCompact` is undocumented and unexercised by any plugin in the public
catalog. Using `bash` throughout gives us:
- Confirmed working semantics (every official plugin uses `bash`).
- Full control over the output file path and atomic writes.
- Easy debugging (we own the I/O and can log freely).
- Graceful degradation — if `claude -p` fails, L1's output is still on disk.

The `claude --bare -p` invocation costs (when `ANTHROPIC_API_KEY` is set):
- Cold (first call in 5min window): ~$0.028, ~4s wall
- Warm (within 5min): ~$0.004, ~3s wall

Without `ANTHROPIC_API_KEY`, full `claude -p` mode runs but pays a ~34K-token
plugin/MCP discovery tax per cold call (~$0.04 cold, ~10s wall). The plugin
works either way; bare mode is just a noticeable optimization.

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

## 7. Open questions for v0.2+

1. **Empirically measure L3 adherence rate.** The model is asked via system
   reminder to edit `active.md` before answering. How often does it actually
   do it? Instrument and measure.
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
