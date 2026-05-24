#!/usr/bin/env bash
# Layer 3 — fires once on the first user prompt after a compaction. Asks the
# main model (which has just been restored with full re-injected context) to
# write a refined handoff for the NEXT compact, while it still has the entire
# conversation in mind. This is the highest-fidelity path because the main
# model has more context than any L1 mechanical scan or L2 Haiku summarizer.
#
# Trigger is one-shot: consumes the `need-l3-enrichment` marker on use.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

amnesia::has_jq || exit 0

STATE_DIR="$(amnesia::ensure_state)"
MARKER="$STATE_DIR/markers/need-l3-enrichment"
ACTIVE="$STATE_DIR/handoff/active.md"

# If no marker, silent exit. This is the case for ~99% of user prompts.
[ -f "$MARKER" ] || exit 0

# Stale-marker guard: only fire if the marker is fresh (<10 min). Past that,
# the user is presumably mid-flow and we shouldn't interrupt with a meta-task.
NOW_EPOCH="$(date -u +%s)"
MARKER_EPOCH="$(cat "$MARKER" 2>/dev/null || echo 0)"
AGE=$(( NOW_EPOCH - MARKER_EPOCH ))
if [ "$AGE" -gt 600 ]; then
  rm -f "$MARKER"
  amnesia::log info "L3 marker stale (${AGE}s); discarded without firing"
  exit 0
fi

# Consume the marker.
rm -f "$MARKER"

INSTRUCTION="$(cat <<EOF
[amnesia L3] A compaction just happened. You have just been restored with a
handoff at:
  $ACTIVE

Before answering the user's current message, take ~30 seconds to refine that
handoff for the NEXT compaction. Specifically:

1. Read $ACTIVE (Read tool).
2. Use the Edit tool (or Write if simpler) to fix any places where:
   - the "Working theory" misstates what you were actually doing
   - the "Open questions" list is missing something you remember
   - the "Concrete next action" is vague — make it imperative and specific
   - file paths or commands are missing or wrong
3. Then answer the user's actual prompt normally.

You have full context right now. The next-you who reads this handoff after the
next compaction will not. Write to *that* reader. Be specific. No fluff.

This instruction is from the amnesia plugin and fires once per compaction.
EOF
)"

jq -n --arg c "$INSTRUCTION" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $c
  }
}'

amnesia::log info "L3 enrichment instruction injected"
exit 0
