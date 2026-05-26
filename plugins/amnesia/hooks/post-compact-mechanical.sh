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
SIDECAR="$STATE_DIR/markers/pre-compact-snapshot.jsonl"

SESSION_ID="$(amnesia::field session_id)"
TRANSCRIPT="$(amnesia::field transcript_path)"
TRIGGER="$(amnesia::field trigger)"
CWD="$(amnesia::field cwd)"
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-${PWD:-/unknown}}"
COMPACT_SUMMARY="$(amnesia::field compact_summary)"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"

# Determine the enrichment effort/model label for the footer note.
AMNESIA_EFFORT="${AMNESIA_EFFORT:-max}"
ENRICHMENT_LABEL="L2 (Opus 4.7 \`--effort ${AMNESIA_EFFORT}\`) enrichment"

# Acquire the active.md write lock (serializes concurrent compactions/sessions).
if ! amnesia::lock active 30; then
  amnesia::log_jsonl "L1" "lock_timeout" "trigger=${TRIGGER:-unknown}"
  amnesia::log warn "L1: could not acquire lock on active.md; skipping"
  exit 0
fi

# Consume the PreCompact sidecar if Agent C created one. Prepend it to any
# transcript tail we scan so L1 has richer source material.
HAD_SIDECAR=false
SIDECAR_LINES=""
if [ -f "$SIDECAR" ]; then
  SIDECAR_LINES="$(cat "$SIDECAR" 2>/dev/null || true)"
  HAD_SIDECAR=true
  rm -f "$SIDECAR" || true
fi

# Pull files-touched + last few turns from the transcript, scoped to the slice
# that just got summarized away. The transcript is append-only so the lines
# preceding the compact boundary are still on disk.
#
# If the sidecar exists, prepend it so the walker sees a richer stream.
WALKER="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")/..}/hooks/lib/jsonl_walker.py"
TOUCHED_JSON="{}"
LAST_USER_JSON="[]"
TRANSCRIPT_LINES=0

if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && amnesia::has_py; then
  TRANSCRIPT_LINES="$(wc -l < "$TRANSCRIPT" 2>/dev/null || echo 0)"

  if [ -n "$SIDECAR_LINES" ]; then
    # Build an augmented transcript: sidecar entries prepended to the real transcript.
    # Use a temp file so jsonl_walker.py gets a single seekable stream.
    AUGMENTED_TRANSCRIPT="$(mktemp /tmp/amnesia-augmented.XXXXXX.jsonl)"
    printf '%s\n' "$SIDECAR_LINES" > "$AUGMENTED_TRANSCRIPT"
    cat "$TRANSCRIPT" >> "$AUGMENTED_TRANSCRIPT"
    TOUCHED_JSON="$(python3 "$WALKER" files "$AUGMENTED_TRANSCRIPT" 2>/dev/null || echo '{}')"
    LAST_USER_JSON="$(python3 "$WALKER" tail "$AUGMENTED_TRANSCRIPT" -n 3 --role user --max-chars 800 2>/dev/null || echo '[]')"
    rm -f "$AUGMENTED_TRANSCRIPT"
  else
    TOUCHED_JSON="$(python3 "$WALKER" files "$TRANSCRIPT" 2>/dev/null || echo '{}')"
    LAST_USER_JSON="$(python3 "$WALKER" tail "$TRANSCRIPT" -n 3 --role user --max-chars 800 2>/dev/null || echo '[]')"
  fi
fi

# Calculate citation range for items extracted from the transcript tail.
# The last 200 lines are the primary source for "recent" data; we cite that window.
CITE_START=$(( TRANSCRIPT_LINES > 200 ? TRANSCRIPT_LINES - 200 : 1 ))
CITE_END="$TRANSCRIPT_LINES"
CITE_RANGE="[L:${CITE_START}-${CITE_END}]"

# Probe current git state (returns {} if not in a git repo).
GIT_STATE="$(amnesia::git_state)"

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
  echo "Citations like \`[L:N-M]\` refer to lines in \`${TRANSCRIPT:-<transcript_path>}\`. Use \`Read\` on that file to recover full bytes."
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
    echo
    echo "_(extracted from transcript lines ${CITE_START}–${CITE_END} ${CITE_RANGE})_"
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
    echo
    echo "_(lines $CITE_RANGE of working-state.jsonl)_"
  else
    echo "_(no command history yet)_"
  fi
  echo
  echo "## Last user turns (verbatim, pre-compact)"
  echo
  if [ "$LAST_USER_JSON" != "[]" ]; then
    printf '%s' "$LAST_USER_JSON" | jq -r '.[] | "> \(.text | gsub("\n"; "\n> "))\n"'
    echo
    echo "_(extracted from transcript ${CITE_RANGE})_"
  else
    echo "_(transcript tail unavailable)_"
  fi
  echo

  # Emit the ## Git state section only when there is meaningful git state.
  if [ "$GIT_STATE" != "{}" ] && [ -n "$GIT_STATE" ]; then
    echo "## Git state"
    echo
    echo '```json'
    printf '%s\n' "$GIT_STATE"
    echo '```'
    echo
  fi

  echo "---"
  echo "_${ENRICHMENT_LABEL} will overwrite this file shortly. If it does not,"
  echo "L1 is what survived. To trigger a manual enrichment, run \`/amnesia:snapshot\`._"
} | amnesia::atomic_write "$ACTIVE"

# Compute bytes written for the log.
BYTES="$(wc -c < "$ACTIVE" 2>/dev/null | tr -d ' ' || echo 0)"

amnesia::unlock active

# Archive a timestamped copy so we can audit drift across compacts.
cp "$ACTIVE" "$ARCHIVE/${TS_FILE}-L1-${TRIGGER:-unknown}.md" || true

# Prune the handoff archive to AMNESIA_ARCHIVE_KEEP entries (default 50).
amnesia::prune_archive "$STATE_DIR"

# Drop the L3 marker so the very next Stop hook (after the first post-compact
# turn finishes) refines the handoff in the background.
date -u +%s > "$MARKER" || true

# Re-arm the preempt marker for the next cycle: clear it so the preempt
# UserPromptSubmit hook can fire again as we approach the next compact.
rm -f "$STATE_DIR/markers/preempt-done-this-cycle" || true

amnesia::log_jsonl "L1" "wrote" "trigger=${TRIGGER:-unknown}" "bytes=$BYTES" "had_sidecar=$HAD_SIDECAR"
amnesia::log info "L1 handoff written; trigger=$TRIGGER session=$SESSION_ID"
exit 0
