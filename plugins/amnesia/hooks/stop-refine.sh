#!/usr/bin/env bash
# Layer 3 — fires on Stop with async:true. Runs the FIRST time the model
# finishes a turn after a compaction (consumes the need-l3-enrichment marker
# that L1 dropped). Refines active.md using the just-finished turn — which
# is the first turn where the freshly-restored model exercised its full
# post-compact context — to capture details L1's mechanical scan and L2's
# bounded-input enrichment missed.
#
# This is the path that used to inject a "refine the handoff" instruction
# via UserPromptSubmit (visible to user as a pause before the model's reply).
# Stop+async is invisible: the model has already replied; we work in the
# background.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/summarize.sh"
amnesia::read_input
amnesia::has_jq || exit 0

STATE_DIR="$(amnesia::ensure_state)"
ACTIVE="$STATE_DIR/handoff/active.md"
ARCHIVE="$STATE_DIR/handoff/archive"
MARKER="$STATE_DIR/markers/need-l3-enrichment"

# Marker check: only fire after a real compaction. ~99% of Stop events have no
# marker and we exit silently.
[ -f "$MARKER" ] || exit 0

# Stale-marker guard: discard markers older than 1 hour. Past that, the post-
# compact turn we wanted to learn from is too far away to be meaningful.
NOW_EPOCH="$(date -u +%s)"
MARKER_EPOCH="$(cat "$MARKER" 2>/dev/null || echo 0)"
AGE=$(( NOW_EPOCH - MARKER_EPOCH ))
if [ "$AGE" -gt 3600 ]; then
  rm -f "$MARKER"
  amnesia::log info "L3 marker stale (${AGE}s); discarded without firing"
  exit 0
fi

# Consume the marker; subsequent Stop events do nothing until the next compact.
rm -f "$MARKER"

SESSION_ID="$(amnesia::field session_id)"
TRANSCRIPT="$(amnesia::field transcript_path)"
TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"

# Feed the summarizer the EXISTING L2 handoff plus a larger transcript tail
# (32KB instead of 16KB) since the model just used post-compact context that
# we want captured for next time.
TAIL=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TAIL="$(tail -c 32768 "$TRANSCRIPT" 2>/dev/null || true)"
fi
CURRENT=""
[ -f "$ACTIVE" ] && CURRENT="$(cat "$ACTIVE")"

PROMPT="$(cat <<PROMPT_EOF
A Claude Code session was just compacted, and the restored agent has just
finished its FIRST post-compact turn. The current handoff (input block A)
was written before that turn happened. Refine it for the NEXT compaction
using everything the just-finished turn revealed — what the user actually
wanted, what the agent actually did, and what's actually next.

Output the FULL refined handoff in the same structure as the current one,
≤ 4000 chars. Be specific. If the existing handoff already nailed a section,
keep it. If the just-finished turn revealed a better "Concrete next action,"
update it. Never invent — only use facts from the input.

# amnesia handoff (L3 refined)

## Working theory
…

## Decisions made (since last compact)
- …

## Open questions / blockers
- …

## In-flight task
…

## Files of interest
- …

## Concrete next action
…

---
INPUT BLOCK A — current handoff (pre-Stop refinement):

$CURRENT

---
INPUT BLOCK B — Raw transcript tail (most-recent 32KB, includes the first
post-compact turn that just finished):

$TAIL
PROMPT_EOF
)"

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

if ! printf '%s' "$PROMPT" | amnesia::summarize 180 "L3-refine" > "$TMP_OUT"; then
  amnesia::log warn "L3 summarizer failed; existing handoff (L1 or L2) remains in place"
  exit 0
fi

if [ ! -s "$TMP_OUT" ] || ! head -c 200 "$TMP_OUT" | grep -q '^#'; then
  amnesia::log warn "L3 output looked malformed; existing handoff remains in place"
  exit 0
fi

amnesia::wrap_handoff \
  "L3 refined, source=Stop-after-compact" \
  "$SESSION_ID" \
  "$TRANSCRIPT" \
  "refined-from-post-compact-turn: \`yes\`" \
  < "$TMP_OUT" \
  | amnesia::atomic_write "$ACTIVE"

cp "$ACTIVE" "$ARCHIVE/${TS_FILE}-L3.md" || true
amnesia::log info "L3 refined handoff written"
exit 0
