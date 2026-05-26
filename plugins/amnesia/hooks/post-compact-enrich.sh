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
L2_MARKER="$STATE_DIR/markers/l2-in-flight"

# Drop an in-flight marker so L3 and preempt know we're working.
date +%s > "$L2_MARKER" || true

# Always remove the in-flight marker on exit (success, failure, or signal).
trap 'rm -f "$L2_MARKER"' EXIT

SESSION_ID="$(amnesia::field session_id)"
TRANSCRIPT="$(amnesia::field transcript_path)"
TRIGGER="$(amnesia::field trigger)"
TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"

amnesia::log_jsonl "L2" "started" "trigger=${TRIGGER:-unknown}" "effort=${AMNESIA_EFFORT:-max}"

# Acquire lock on active.md before reading or writing.
if ! amnesia::lock active 30; then
  amnesia::log_jsonl "L2" "lock_timeout"
  amnesia::log warn "L2: could not acquire lock on active.md within 30s; exiting"
  exit 0
fi

# Cap input at ~16KB of transcript tail + the L1 handoff. Bigger input = more
# quota use; we already have L1's distillation to lean on.
TAIL=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TAIL="$(tail -c 16384 "$TRANSCRIPT" 2>/dev/null || true)"
fi
L1_BODY=""
[ -f "$ACTIVE" ] && L1_BODY="$(cat "$ACTIVE")"
L1_SIZE="${#L1_BODY}"

START_MS="$(date +%s%3N 2>/dev/null || printf '%d000' "$(date +%s)")"

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
# Note: the EXIT trap already removes L2_MARKER; also clean up TMP_OUT.
trap 'rm -f "$TMP_OUT" "$L2_MARKER"' EXIT

if ! printf '%s' "$PROMPT" | amnesia::summarize 180 "L2-enrich" > "$TMP_OUT"; then
  amnesia::log warn "L2 summarizer failed; L1 handoff remains in place"
  amnesia::unlock active
  exit 0
fi

# Sanity check using the shared function (replaces the old head|grep check).
if ! amnesia::summarize_sanity_check "$TMP_OUT"; then
  amnesia::log_jsonl "L2" "sanity_failed" "out_bytes=$(wc -c < "$TMP_OUT" 2>/dev/null || echo 0)"
  amnesia::log warn "L2 output looked malformed (sanity check failed); L1 handoff remains in place"
  amnesia::unlock active
  exit 0
fi

amnesia::wrap_handoff \
  "L2 enriched, source=PostCompact" \
  "$SESSION_ID" \
  "$TRANSCRIPT" \
  "compact trigger: \`${TRIGGER:-unknown}\`" \
  < "$TMP_OUT" \
  | amnesia::atomic_write "$ACTIVE"

amnesia::unlock active

cp "$ACTIVE" "$ARCHIVE/${TS_FILE}-L2-${TRIGGER:-unknown}.md" || true
amnesia::log info "L2 enriched handoff written; trigger=$TRIGGER effort=${AMNESIA_EFFORT:-max}"

END_MS="$(date +%s%3N 2>/dev/null || printf '%d000' "$(date +%s)")"
DURATION_MS=$(( END_MS - START_MS ))
L2_SIZE="$(wc -c < "$ACTIVE" 2>/dev/null || echo 0)"
DELTA=$(( L2_SIZE - L1_SIZE ))

amnesia::log_jsonl "L2" "finished" "trigger=${TRIGGER:-unknown}" "effort=${AMNESIA_EFFORT:-max}" "duration_ms=$DURATION_MS" "l1_bytes=$L1_SIZE" "l2_bytes=$L2_SIZE" "delta_bytes=$DELTA"

# If L2 output differs meaningfully from L1, emit a stderr delta summary.
# Meaningful = size delta > 500 bytes OR first H2 content differs.
# This is prep for a future asyncRewake: true config change (Agent C decides).
# For now we always exit 0.
if [ "${DELTA#-}" -gt 500 ] 2>/dev/null; then
  if [ "$DELTA" -gt 0 ]; then
    DELTA_HUMAN="+$(( DELTA / 1024 )).$(( (DELTA % 1024) * 10 / 1024 ))KB"
  else
    DELTA_HUMAN="-$(( ${DELTA#-} / 1024 )).$(( (${DELTA#-} % 1024) * 10 / 1024 ))KB"
  fi
  printf 'amnesia L2: handoff refined (%s enriched). Run /amnesia:status to inspect.\n' "$DELTA_HUMAN" >&2
fi

exit 0
