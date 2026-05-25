#!/usr/bin/env bash
# Layer 2 — async, runs after L1 to enrich the mechanical handoff with the
# narrative the model would write itself if it could ("what was the model
# trying to do, what decisions did it make, what's the next concrete step").
#
# Fires from hooks.json with `async: true`, so the parent harness has already
# returned to the user; we can take 30-60s here invisibly.
#
# Uses an isolated `claude -p` call (see lib/summarize.sh) at the user's
# default model (Opus 4.7 on subscription) at --effort max. Falls back
# gracefully to L1 if the call fails.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/summarize.sh"
amnesia::read_input
amnesia::has_jq || exit 0

STATE_DIR="$(amnesia::ensure_state)"
ACTIVE="$STATE_DIR/handoff/active.md"
ARCHIVE="$STATE_DIR/handoff/archive"

SESSION_ID="$(amnesia::field session_id)"
TRANSCRIPT="$(amnesia::field transcript_path)"
TRIGGER="$(amnesia::field trigger)"
TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"

# Cap input at ~16KB of transcript tail + the L1 handoff. Bigger input = more
# quota use; we already have L1's distillation to lean on.
TAIL=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TAIL="$(tail -c 16384 "$TRANSCRIPT" 2>/dev/null || true)"
fi
L1_BODY=""
[ -f "$ACTIVE" ] && L1_BODY="$(cat "$ACTIVE")"

PROMPT="$(cat <<PROMPT_EOF
The session was compacted (trigger: ${TRIGGER:-unknown}). Produce a Layer-2
handoff in the exact format below from the two input blocks. ≤ 4000 chars
total. Be specific. Quote file paths, error messages, and recent decisions
verbatim. If a section has nothing to report from the input, write
"_(nothing to report)_" — never invent.

Output MUST begin at H2 (\`## Working theory\`). Do NOT emit a top-level H1 —
the caller wraps your output with its own \`# amnesia handoff (L2 enriched, …)\`.

## Working theory
One paragraph: what was the agent trying to accomplish at the moment of
compaction? Cite specifics from the input.

## Decisions made (since last compact)
- Bullet list of decisions with one-sentence rationale each. Each rationale
  must be traceable to the input.

## Open questions / blockers
- Bullet list. Each item ends with "→ next step: ..." when actionable.

## In-flight task
The single most recent thread of work. Cite the last assistant tool call and
the last user message that motivated it. Quote them.

## Files of interest
- \`path\` — why it matters in ≤8 words.

## Concrete next action
One imperative sentence citing a specific file/command/test from the input.

---
INPUT BLOCK A — Layer-1 mechanical handoff (already structured):

$L1_BODY

---
INPUT BLOCK B — Raw transcript tail (most-recent 16KB):

$TAIL
PROMPT_EOF
)"

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

if ! printf '%s' "$PROMPT" | amnesia::summarize 180 "L2-enrich" > "$TMP_OUT"; then
  amnesia::log warn "L2 summarizer failed; L1 handoff remains in place"
  exit 0
fi

# Sanity check: output must begin at the expected H2 anchor. This catches
# both empty output and the v0.2.0 bug where the model emitted its own H1
# (producing a duplicate header after wrap_handoff added the outer one).
if [ ! -s "$TMP_OUT" ] || ! head -c 200 "$TMP_OUT" | grep -q '^## Working theory'; then
  amnesia::log warn "L2 output looked malformed (missing '## Working theory' anchor); L1 handoff remains in place"
  exit 0
fi

amnesia::wrap_handoff \
  "L2 enriched, source=PostCompact" \
  "$SESSION_ID" \
  "$TRANSCRIPT" \
  "compact trigger: \`${TRIGGER:-unknown}\`" \
  < "$TMP_OUT" \
  | amnesia::atomic_write "$ACTIVE"

cp "$ACTIVE" "$ARCHIVE/${TS_FILE}-L2-${TRIGGER:-unknown}.md" || true
amnesia::log info "L2 enriched handoff written; trigger=$TRIGGER effort=${AMNESIA_EFFORT:-max}"
exit 0
