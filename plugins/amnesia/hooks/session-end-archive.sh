#!/usr/bin/env bash
# SessionEnd hook — final snapshot + sessions index maintenance.
#
# Fires synchronously on SessionEnd. Responsibilities:
#   1. For "dirty" endings (clear, prompt_input_exit, other) where working-state
#      has unprocessed entries: append a brief note to active.md. No LLM calls.
#   2. For ALL endings: append an entry to <state_dir>/sessions.json (capped at
#      200 entries), then rotate working-state.jsonl.
#
# session_id is synthesized from the session_id hook field if present, or from
# the current timestamp + pid as a stable-enough fallback.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

STATE_DIR="$(amnesia::ensure_state)"
ACTIVE="$STATE_DIR/handoff/active.md"
WS="$STATE_DIR/working-state.jsonl"
SESSIONS_JSON="$STATE_DIR/sessions.json"

REASON="$(amnesia::field reason)"
SID="$(amnesia::field session_id)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-/unknown}}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Synthesize a session ID if the harness didn't provide one.
[ -n "$SID" ] || SID="session-$(date -u +%Y%m%dT%H%M%SZ)-$$"

# ── 1. Dirty-ending note ──────────────────────────────────────────────────────
# For endings that may interrupt in-progress work, append a brief note to
# active.md IF working-state.jsonl has been updated more recently than active.md.
# This tells the next session restore that something happened after the last
# LLM-generated handoff without the cost of an LLM call.

DIRTY_REASONS="clear prompt_input_exit other"
if printf '%s' "$DIRTY_REASONS" | grep -qw "${REASON:-other}"; then
  if [ -f "$WS" ] && [ -f "$ACTIVE" ]; then
    WS_MTIME="$(stat -c %Y "$WS" 2>/dev/null || stat -f %m "$WS" 2>/dev/null || echo 0)"
    ACTIVE_MTIME="$(stat -c %Y "$ACTIVE" 2>/dev/null || stat -f %m "$ACTIVE" 2>/dev/null || echo 0)"
    if [ "$WS_MTIME" -gt "$ACTIVE_MTIME" ]; then
      # Pull the last tool call for a one-line summary — no LLM needed.
      LAST_TOOL="$(tail -n 1 "$WS" 2>/dev/null \
        | jq -r '"\(.tool // "unknown") \(.file_path // .cmd_preview // "")" | .[0:120]' \
        2>/dev/null || echo "(working-state updated)")"
      {
        printf '\n---\n'
        printf '> **Session ended** at `%s`, reason=`%s`\n' "$NOW" "${REASON:-unknown}"
        printf '> Last recorded activity: `%s`\n' "$LAST_TOOL"
        printf '> _Appended by session-end-archive.sh — no LLM involved._\n'
      } >> "$ACTIVE" 2>/dev/null || true
    fi
  fi
fi

# ── 2. Sessions index ─────────────────────────────────────────────────────────
# Append the completed session to sessions.json. We read the current array (or
# start a new one), append, cap at 200, and atomically overwrite.

HANDOFF_PATH=""
[ -f "$ACTIVE" ] && HANDOFF_PATH="$ACTIVE"

NEW_ENTRY="$(jq -n \
  --arg sid "$SID" \
  --arg project_dir "$PROJECT_DIR" \
  --arg ended_at "$NOW" \
  --arg reason "${REASON:-unknown}" \
  --arg handoff_path "$HANDOFF_PATH" \
  '{
    session_id:   $sid,
    project_dir:  $project_dir,
    ended_at:     $ended_at,
    reason:       $reason,
    handoff_path: $handoff_path
  }' 2>/dev/null || true)"

if [ -n "$NEW_ENTRY" ]; then
  # Read the existing array (or start fresh).
  EXISTING="[]"
  if [ -f "$SESSIONS_JSON" ]; then
    EXISTING="$(jq -r '.' "$SESSIONS_JSON" 2>/dev/null || echo '[]')"
    # Validate: if not an array, reset.
    if ! printf '%s' "$EXISTING" | jq -e 'type == "array"' >/dev/null 2>&1; then
      EXISTING="[]"
    fi
  fi

  # Append and cap at 200 (drop the oldest).
  printf '%s' "$EXISTING" \
    | jq --argjson entry "$NEW_ENTRY" '. + [$entry] | .[-200:]' 2>/dev/null \
    | amnesia::atomic_write "$SESSIONS_JSON" || true
fi

# ── 3. Rotate working-state.jsonl ─────────────────────────────────────────────
amnesia::rotate_jsonl "$WS"

amnesia::log_jsonl "SessionEnd" "archived" "reason=${REASON:-unknown}" "session_id=$SID"
exit 0
