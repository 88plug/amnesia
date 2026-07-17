#!/usr/bin/env bash
# SubagentStart hook — inject a trimmed working-state summary into subagents.
#
# Fires synchronously on SubagentStart. Reads the current active.md, extracts
# only the highest-value sections (Working theory, In-flight task, Concrete
# next action, Files of interest), caps output at AMNESIA_SUBAGENT_CONTEXT_BYTES
# (default 3000), and emits it as additionalContext so the subagent starts
# with awareness of what the parent was doing.
#
# Sections intentionally dropped: Decisions made, Open questions/blockers,
# Citations, Recovery protocol — these add bulk without improving task-focus.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

amnesia::has_jq || exit 0

STATE_DIR="$(amnesia::ensure_state)"
ACTIVE="$STATE_DIR/handoff/active.md"

# No handoff → nothing to inject; exit silently.
[ -f "$ACTIVE" ] || exit 0

MAX_BYTES="${AMNESIA_SUBAGENT_CONTEXT_BYTES:-3000}"

# Extract only the sections worth injecting into a fresh subagent context.
# We pull lines between the H2 anchors we care about, drop the rest.
TRIMMED="$(awk '
  /^## Working theory/       { capture=1 }
  /^## In-flight task/       { capture=1 }
  /^## Files of interest/    { capture=1 }
  /^## Concrete next action/ { capture=1 }
  /^## Decisions made/       { capture=0 }
  /^## Open questions/       { capture=0 }
  /^## Recovery protocol/    { capture=0 }
  /^## Compaction summary/   { capture=0 }
  /^## Recent commands/      { capture=0 }
  /^## Last user turns/      { capture=0 }
  /^---$/                    { capture=0 }
  capture { print }
' "$ACTIVE" 2>/dev/null || true)"

# If extraction yielded nothing meaningful, fall back to raw active.md head.
if [ -z "$(printf '%s' "$TRIMMED" | tr -d '[:space:]')" ]; then
  TRIMMED="$(head -c "$MAX_BYTES" "$ACTIVE" 2>/dev/null || true)"
fi

# Cap at MAX_BYTES; mark truncation clearly.
BYTE_COUNT="${#TRIMMED}"
if [ "$BYTE_COUNT" -gt "$MAX_BYTES" ]; then
  TRIMMED="${TRIMMED:0:$MAX_BYTES}
[truncated]"
fi

PREAMBLE="[amnesia / subagent context] You are a subagent spawned with a fresh context. The parent agent's working state is reattached below. Use silently — don't narrate."

INJECTED="$(printf '%s\n\n%s' "$PREAMBLE" "$TRIMMED")"

# Emit the hookSpecificOutput envelope expected by the SubagentStart hook.
jq -n --arg c "$INJECTED" '{
  hookSpecificOutput: {
    hookEventName: "SubagentStart",
    additionalContext: $c
  }
}'

N="${#INJECTED}"
amnesia::log_jsonl "SubagentStart" "injected" "bytes=$N"
exit 0
