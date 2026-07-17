# Changelog


## 2026.7.17

- **Layout:** hoist plugin package from `plugins/amnesia/` to repository root (standard 88plug structure). Marketplace source is now `url` (no longer `git-subdir`).
- Hub catalog + `marketplace-entry.json` updated accordingly.

All notable changes to amnesia are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions correspond to the `version` field in `.claude-plugin/plugin.json`.

---

## [Unreleased]

### Fixed — Python launch under thin PATH

- MCP no longer uses bare `"command": "python3"` (fails when Claude's spawn
  PATH omits Homebrew/pyenv). Launches via `scripts/mcp-server.sh` →
  `scripts/run-python.sh` (env override → venv → PATH → absolute fallbacks,
  floor ≥3.10).
- Hooks use `amnesia::py` / `amnesia::has_py` through the same resolver.
- CI rejects bare `python*` in mcpServers; smoke covers thin PATH + override.

### Changed — license

- **Relicensed from MIT to `FSL-1.1-ALv2`** (Functional Source License,
  Version 1.1, Apache-2.0 Future License). Source remains visible; redistribution
  and modification remain permitted for any Permitted Purpose. A Competing Use —
  offering amnesia (or a substantially similar substitute) as a commercial
  product or service — is no longer a Permitted Purpose. Each released version
  automatically converts to the Apache License 2.0 on the second anniversary of
  its release date. See [`LICENSE.md`](./LICENSE.md) for the full terms.
- `LICENSE` (MIT) removed in favor of `LICENSE.md` (FSL-1.1-ALv2).
- `.claude-plugin/plugin.json` license updated to `FSL-1.1-ALv2`.

---

## [0.3.0] — 2026-05-25

The biggest release to date. The pipeline grew from 4 layers to 7+, a
read-only MCP server landed, L2/L3 race-protection was added, and
observability improved significantly.

### Architecture

- **Foundation helpers** (`lib/common.sh`): `amnesia::log_jsonl`,
  `amnesia::lock`/`unlock`, `amnesia::all_data_roots`,
  `amnesia::rotate_jsonl`, `amnesia::prune_archive`,
  `amnesia::redact_secrets`, `amnesia::git_state` (commit `9451b88`).
- **L2/L3 race-protection**: `markers/l2-in-flight` marker written before
  L2 starts; `amnesia::lock active 30` serializes all writers to `active.md`;
  L3 waits up to 90 s for the marker to clear before proceeding (commit `37ae7fa`).
- **Daily budget cap**: `AMNESIA_DAILY_BUDGET_TOKENS` (default 5 000 000)
  tracks cumulative prompt bytes in `logs/budget-YYYYMMDD.txt`; when the cap
  is hit the summarizer automatically downgrades from `max` to `medium` effort
  (commit `37ae7fa`).
- **Tightened sanity check**: `amnesia::summarize_sanity_check` now requires
  ≥ 3 of 6 expected H2 anchors AND 500 B < body < 8 KB. The old check
  rejected structurally valid output that reordered sections (commit `37ae7fa`).
- **Structured event log**: every helper writes to `logs/events.jsonl` in
  addition to the legacy plaintext `logs/amnesia.log`.

### Capture pipeline

- **Secret redaction**: Bash-command captures are piped through
  `amnesia::redact_secrets` before they reach JSONL. Strips
  `Authorization: Bearer …`, `--token=`, `_KEY=`, and `ghp_`/`sk-`/`xoxb-`/`AKIA`
  prefix tokens (commit `9057399`).
- **`working-state.jsonl` auto-rotation**: at `AMNESIA_WS_MAX_LINES` lines
  (default 5 000), older lines are moved to `logs/archive/<name>-<ts>.jsonl.gz`
  (commit `9057399`).
- **Handoff archive pruning**: `handoff/archive/` is capped at
  `AMNESIA_ARCHIVE_KEEP` (default 50) entries; oldest are deleted (commit `9057399`).
- **Git state in L1**: the L1 handoff now embeds a `## Git state` JSON block
  (branch, HEAD SHA, dirty file count, stash count, remote URL) (commit `9057399`).
- **Citation ranges**: L1 handoff includes `[L:N-M]` ranges that reference the
  transcript lines the handoff was derived from (commit `9057399`).
- **PreCompact sidecar consumption**: L1 reads `markers/pre-compact-snapshot.jsonl`
  when present and incorporates it before the PreCompact marker is cleared (commit `705feb6`).
- **Removed stale "Haiku-enriched" string**: the header now reflects the
  actual model and effort level used (commit `9057399`).

### Hooks (new)

- **`PreCompact` → `pre-compact-snapshot.sh`** (sync, < 100 ms): tails
  `AMNESIA_PRECOMPACT_TAIL_LINES` (default 1 000) lines of the transcript into
  a sidecar file for L1 to consume.
- **`SubagentStart` → `subagent-start-inject.sh`** (sync): injects a trimmed
  handoff (max `AMNESIA_SUBAGENT_CONTEXT_BYTES`, default 3 000 bytes) as
  `additionalContext` for every spawned subagent.
- **`SessionEnd` → `session-end-archive.sh`** (sync): takes a final no-LLM
  snapshot if needed, appends to `sessions.json` index (capped at 200 entries),
  rotates `working-state.jsonl`.
- **Opt-in git sync**: `session-start-pull.sh` + `session-end-push.sh` are
  no-ops unless `AMNESIA_SYNC_REMOTE` is set to a git remote URL. When set,
  the data root becomes a git-tracked directory that is pulled on session start
  and pushed on session end (commit `705feb6`).
- **`asyncRewake: true` for L2 and L3**: both enrichment hooks now use
  `asyncRewake` instead of `async: true`. When the background enrichment
  finishes after SessionStart has already injected the L1 handoff, a stderr
  delta summary surfaces as a system reminder mid-conversation (commit `705feb6`).
- **`Preempt` stays `async: true`**: the pre-compact snapshot hook remains a
  fire-and-forget background task — its result does not need to wake the model.

### MCP server

- New stdio JSON-RPC server at `mcp/server.py` (Python 3.6+
  stdlib only; zero pip dependencies) (commit `b12e628`).
- **`recall`** tool: case-insensitive substring search across the active
  handoff, archived handoffs, and gzipped working-state archives. Returns
  `{path, line_number, snippet, project_slug, mtime}` ordered by recency,
  capped at 32 KB total / 4 KB per snippet.
- **`handoff_get`** tool: returns the full markdown of the current active
  handoff or a specific archived handoff by session ID.
- Server declared in both `plugin.json` (mcpServers key) and
  `.mcp.json` for compatibility with both declaration styles.

### Commands

- `/amnesia:sessions [query] [--all-projects]` — search across archived
  handoffs; supports free-text query and project-scoping (commit `2a87c1f`).
- `/amnesia:migrate [--dry-run|--execute]` — consolidate orphan data roots
  from old marketplace installs (commit `2a87c1f`).
- `/amnesia:diff [--from --to]` — diff two handoff versions side-by-side
  (commit `2a87c1f`).
- `/amnesia:why <claim>` — trace a handoff claim back to its JSONL source
  lines via `[L:N-M]` citations (commit `2a87c1f`).
- **Updated `/amnesia:status`**: now lists all data roots with `[ACTIVE]` /
  `[orphan]` labels, L2/L3 success rates from `events.jsonl`, in-flight
  marker state, and today's budget usage (commit `2a87c1f`).
- **Updated `/amnesia:snapshot`**: now non-blocking (touches a
  `force-snapshot` marker and returns immediately). Pass `--deep` to delegate
  to `@agent-amnesia:summarizer` for a full narrative rewrite (commit `2a87c1f`).
- **All commands**: dead fallback paths fixed to use the canonical
  `ls -t $HOME/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh | head -1`
  discovery pattern (commit `2a87c1f`).

### Env vars (all optional)

| Variable | Default | Effect |
|---|---|---|
| `AMNESIA_DAILY_BUDGET_TOKENS` | 5 000 000 | Daily prompt-byte cap; exceeding it downgrades effort to `medium` |
| `AMNESIA_WS_MAX_LINES` | 5 000 | `working-state.jsonl` line cap before rotation |
| `AMNESIA_ARCHIVE_KEEP` | 50 | Maximum entries in `handoff/archive/` |
| `AMNESIA_PRECOMPACT_TAIL_LINES` | 1 000 | Lines snapshotted on `PreCompact` |
| `AMNESIA_SUBAGENT_CONTEXT_BYTES` | 3 000 | Byte cap for subagent context injection |
| `AMNESIA_SUMMARY_MIN_BYTES` | 500 | Sanity check lower bound for handoff body |
| `AMNESIA_SUMMARY_MAX_BYTES` | 8 000 | Sanity check upper bound for handoff body |
| `AMNESIA_SYNC_REMOTE` | (unset) | Git remote URL; enables opt-in cross-machine sync |

---

## [0.2.4] — 2026-05-25

### Fixed

- Slash commands now resolve the correct state directory when the plugin is
  installed from a marketplace-suffixed root (e.g. `amnesia-88plug/`). Previously
  `/amnesia:status` reported "no captures" even when hooks were writing live
  (commit `007a59e`).

---

## [0.2.1] — 2026-05-25

### Fixed

- Suppressed duplicate H1 heading in L2/L3/preempt output. The summarizer
  prompt template now starts at H2 (`## Working theory`); the outer
  `wrap_handoff` wrapper provides the sole H1. The sanity check was updated to
  assert H2 anchors (commit `f90bdf4`).

---

## [0.2.0] — 2026-05-25

### Added

- Switched default summarizer model from Haiku 4.5 to Opus 4.7 `--effort max`.
  On subscription plans both models draw from plan quota, not API tokens — the
  difference is quality, not cost. Empirically verified: Opus 4.7 produces
  faithful, specific handoffs; Haiku paraphrases too aggressively.
- Three-layer isolation for all `claude -p` summarizer calls:
  `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`,
  and an `--append-system-prompt` directive. Fixes hallucination of content
  from the user's `CLAUDE.md` and auto-memory.
- L3 moved from `UserPromptSubmit` (synchronous, visible to user) to `Stop`
  with `async: true` (background, invisible). Fidelity slightly lower than
  v0.1.0 L3 in theory; reliability and user experience substantially better.
- Preemptive snapshot on `UserPromptSubmit` at ≥ 2 MB bytes since last compact
  (configurable via `AMNESIA_PREEMPT_THRESHOLD_BYTES`).
- `AMNESIA_EFFORT` env var to override summarizer effort level.
- `AMNESIA_MAX_AGE_SECONDS` env var (default 86 400) to reject stale handoffs
  on cross-session restore.
- `SessionStart` matcher extended to include `startup` (empirically: manual
  `/compact` fires `source=startup`, not `source=compact`).

### Fixed

- v0.1.0 L3 on `UserPromptSubmit` caused a visible 5–10 s pause before the
  model responded. Moved to `Stop` + async.

---

## [0.1.0] — 2026-05-24

Initial release. Three-layer architecture (L1 + L2 + L3) with basic
preemptive capture.

### Added

- `PostToolUse` hook for continuous `working-state.jsonl` capture (< 50 ms sync).
- `PostCompact` L1 mechanical hook: deterministic bash-only handoff from JSONL
  + working-state tail (< 500 ms sync, always runs).
- `PostCompact` L2 enrichment hook: Haiku 4.5 (later Opus 4.7) rewrites the
  L1 handoff with narrative context (async, ~ 45 s).
- `UserPromptSubmit` L3 refinement hook (sync): model refines the handoff
  in-session before answering. (Moved to `Stop` + async in v0.2.0.)
- `SessionStart(compact|resume|startup)` restore hook: cats `active.md` into
  `additionalContext` for the next turn.
- `/amnesia:snapshot`, `/amnesia:recall`, `/amnesia:status`, `/amnesia:promote`
  slash commands.
- `continuity-protocol` skill: teaches the agent to silently use the handoff
  on recovery without narrating the restoration.
- `@agent-amnesia:summarizer` subagent for on-demand deep snapshots.
- MIT license.

---

[Unreleased]: https://github.com/88plug/amnesia/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/88plug/amnesia/compare/v0.2.4...v0.3.0
[0.2.4]: https://github.com/88plug/amnesia/compare/v0.2.1...v0.2.4
[0.2.1]: https://github.com/88plug/amnesia/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/88plug/amnesia/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/88plug/amnesia/releases/tag/v0.1.0
