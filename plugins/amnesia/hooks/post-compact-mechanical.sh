#!/usr/bin/env bash
# Layer 1 — synchronous, deterministic, no LLM. Always runs after a compaction.
# Writes a structured-but-mechanical handoff to active.md and drops a marker
# that tells the next UserPromptSubmit to ask the main model to refine it.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

amnesia::has_jq || { amnesia::log warn "jq missing; L1 skipped"; exit 0; }
amnesia::has_py || { amnesia::log warn "python3 missing; L1 degraded"; }

STATE_DIR="$(amnesia::ensure_state)"
ACTIVE="$STATE_DIR/handoff/active.md"
ARCHIVE="$STATE_DIR/handoff/archive"
MARKER="$STATE_DIR/markers/need-l3-enrichment"

SESSION_ID="$(amnesia::field session_id)"
TRANSCRIPT="$(amnesia::field transcript_path)"
TRIGGER="$(amnesia::field trigger)"
CWD="$(amnesia::field cwd)"
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-${PWD:-/unknown}}"
COMPACT_SUMMARY="$(amnesia::field compact_summary)"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"

# Pull files-touched + last few turns from the transcript, scoped to the slice
# that just got summarized away. The transcript is append-only so the lines
# preceding the compact boundary are still on disk.
WALKER="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")/..}/hooks/lib/jsonl_walker.py"
TOUCHED_JSON="{}"
LAST_USER_JSON="[]"
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && amnesia::has_py; then
  TOUCHED_JSON="$(python3 "$WALKER" files "$TRANSCRIPT" 2>/dev/null || echo '{}')"
  LAST_USER_JSON="$(python3 "$WALKER" tail "$TRANSCRIPT" -n 3 --role user --max-chars 800 2>/dev/null || echo '[]')"
fi

# Render the handoff. Markdown sections mirror what a human-handoff doc would
# carry: what we were doing, what's on disk, what to do next.
{
  echo "# amnesia handoff (L1 mechanical, source=PostCompact)"
  echo
  echo "- captured: \`$NOW\`"
  echo "- session_id: \`$SESSION_ID\`"
  echo "- cwd: \`$CWD\`"
  echo "- compact trigger: \`${TRIGGER:-unknown}\`"
  echo "- transcript: \`$TRANSCRIPT\`"
  echo
  echo "## Recovery protocol"
  echo
  echo "If you need detail this handoff doesn't cover, the full pre-compaction conversation"
  echo "is on disk at the transcript path above. Use the \`Read\` tool to inspect it directly."
  echo "Lines before the most recent \`compact_boundary\` system entry contain everything"
  echo "the model lost."
  echo
  echo "## Compaction summary (from Claude Code)"
  echo
  if [ -n "$COMPACT_SUMMARY" ]; then
    printf '%s\n' "$COMPACT_SUMMARY"
  else
    echo "_(not provided by harness)_"
  fi
  echo
  echo "## Files touched (since last compact)"
  echo
  if [ "$TOUCHED_JSON" != "{}" ]; then
    printf '%s' "$TOUCHED_JSON" | jq -r '
      to_entries
      | sort_by(.value.last_ts) | reverse
      | .[0:25]
      | .[] | "- `\(.key)` — ops: \(.value.ops | join(",")), last: \(.value.last_ts)"
    '
  else
    echo "_(none recorded; working-state empty or transcript unavailable)_"
  fi
  echo
  echo "## Recent commands (from working-state.jsonl)"
  echo
  if [ -f "$STATE_DIR/working-state.jsonl" ]; then
    tail -n 200 "$STATE_DIR/working-state.jsonl" \
      | jq -r 'select(.tool == "Bash") | "- `\(.cmd_preview)` (exit \(.exit_code // "?"))"' \
      | tail -n 10
  else
    echo "_(no command history yet)_"
  fi
  echo
  echo "## Last user turns (verbatim, pre-compact)"
  echo
  if [ "$LAST_USER_JSON" != "[]" ]; then
    printf '%s' "$LAST_USER_JSON" | jq -r '.[] | "> \(.text | gsub("\n"; "\n> "))\n"'
  else
    echo "_(transcript tail unavailable)_"
  fi
  echo
  echo "---"
  echo "_L2 (Haiku-enriched) handoff may overwrite this file shortly. If it does not,"
  echo "L1 is what survived. To trigger a manual enrichment, run \`/amnesia:snapshot\`._"
} | amnesia::atomic_write "$ACTIVE"

# Archive a timestamped copy so we can audit drift across compacts.
cp "$ACTIVE" "$ARCHIVE/${TS_FILE}-L1-${TRIGGER:-unknown}.md" || true

# Drop the L3 marker so the very next UserPromptSubmit knows to ask the main
# model for a refinement pass while it has full context.
date -u +%s > "$MARKER" || true

amnesia::log info "L1 handoff written; trigger=$TRIGGER session=$SESSION_ID"
exit 0
