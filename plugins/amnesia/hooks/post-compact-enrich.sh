#!/usr/bin/env bash
# Layer 2 — async, Haiku-driven. Runs detached after L1 to enrich the
# mechanical handoff with narrative ("what was the model trying to do, what
# decisions did it make, what's the next concrete step").
#
# `async: true` in hooks.json means the harness has already returned; we can
# take 5-15s here without blocking anything user-visible.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

amnesia::has_jq || exit 0

STATE_DIR="$(amnesia::ensure_state)"
ACTIVE="$STATE_DIR/handoff/active.md"
ARCHIVE="$STATE_DIR/handoff/archive"

SESSION_ID="$(amnesia::field session_id)"
TRANSCRIPT="$(amnesia::field transcript_path)"
TRIGGER="$(amnesia::field trigger)"

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"

# Skip entirely if `claude` CLI is unreachable or if neither auth path is set.
if ! command -v claude >/dev/null 2>&1; then
  amnesia::log warn "claude CLI not on PATH; L2 skipped"
  exit 0
fi

# Choose summarizer mode:
#   - if ANTHROPIC_API_KEY is set, use `--bare -p` (no plugin/MCP startup tax,
#     ~$0.004/warm call, ~4s wall)
#   - otherwise fall back to full `-p` (OAuth-friendly but costs the ~34k-token
#     plugin/MCP discovery tax; ~$0.028 cold, ~10s wall)
MODE_FLAGS="-p"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  MODE_FLAGS="--bare -p"
fi

# Cap input: feed the model the L1 handoff (already a distillate) + a tail of
# the transcript. We deliberately keep input ≤ ~20k tokens to bound cost.
TAIL=""
if [ -f "$TRANSCRIPT" ]; then
  TAIL="$(tail -c 16384 "$TRANSCRIPT" 2>/dev/null || true)"
fi

L1_BODY=""
[ -f "$ACTIVE" ] && L1_BODY="$(cat "$ACTIVE")"

# Build the prompt as a heredoc so quoting stays sane.
PROMPT="$(cat <<EOF
You are summarizing the tail end of a Claude Code session at the moment of
compaction. The session was compacted (trigger: ${TRIGGER:-unknown}); the model's
working memory was just replaced by a one-shot summary, and we need a
high-fidelity handoff so the next turn can resume without re-deriving lost work.

Below is the deterministic Layer-1 handoff (mechanical, no narrative) plus the
raw tail of the JSONL transcript. Read both, then produce a Layer-2 handoff in
the exact format below. Be specific. Quote file paths, error messages, and
recent decisions verbatim. No fluff, no preamble, no "I'll now...". If a
section has nothing concrete to say, write "_(nothing to report)_" — never invent.

Output format (markdown, ≤ 4000 chars total):

# amnesia handoff (L2 enriched)

## Working theory
One paragraph: what was the model trying to accomplish at the moment of compact?

## Decisions made (since last compact)
- Bullet list of decisions with one-sentence rationale each.

## Open questions / blockers
- Bullet list. Each item ends with "→ next step: ..." when actionable.

## In-flight task
The single most recent thread of work. Cite the last assistant tool call and the
last user message that motivated it.

## Files of interest
- \`path\` — why it matters in 8 words or fewer.

## Concrete next action
One sentence. Imperative voice. Cite a specific file/command/test.

---
Layer-1 handoff:

$L1_BODY

---
Transcript tail (most-recent 16KB):

$TAIL
EOF
)"

# Run with a hard budget and a tight system prompt. Capture stdout; on any
# failure, leave L1 untouched.
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

if ! echo "$PROMPT" | timeout 55 claude $MODE_FLAGS \
    --model claude-haiku-4-5-20251001 \
    --no-session-persistence \
    --max-budget-usd 0.05 \
    --append-system-prompt "You are a terse, faithful session-handoff summarizer. Never invent. Cite verbatim where possible. Output markdown only." \
    --output-format text \
    > "$TMP_OUT" 2>>"$STATE_DIR/logs/amnesia.log"; then
  amnesia::log warn "L2 claude -p failed; L1 handoff remains in place"
  exit 0
fi

# Sanity check: the output should be markdown starting with a header. If it's
# empty or obviously broken, don't overwrite L1.
if [ ! -s "$TMP_OUT" ] || ! head -c 200 "$TMP_OUT" | grep -q '^#'; then
  amnesia::log warn "L2 output looked malformed; L1 handoff remains in place"
  exit 0
fi

# Splice L1's recovery-protocol preamble onto L2's enrichment so the recovery
# protocol survives even if the agent only ever reads the active file.
{
  echo "# amnesia handoff (L2 enriched by Haiku, source=PostCompact)"
  echo
  echo "- captured: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
  echo "- session_id: \`$SESSION_ID\`"
  echo "- compact trigger: \`${TRIGGER:-unknown}\`"
  echo "- transcript: \`$TRANSCRIPT\`"
  echo
  echo "## Recovery protocol"
  echo
  echo "If detail below is insufficient, the full pre-compaction transcript is on disk at the path above."
  echo "Use the \`Read\` tool. Everything before the most recent \`compact_boundary\` system entry is intact."
  echo
  echo "---"
  echo
  cat "$TMP_OUT"
} | amnesia::atomic_write "$ACTIVE"

cp "$ACTIVE" "$ARCHIVE/${TS_FILE}-L2-${TRIGGER:-unknown}.md" || true
amnesia::log info "L2 enriched handoff written; trigger=$TRIGGER"
exit 0
