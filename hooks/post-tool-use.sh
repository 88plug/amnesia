#!/usr/bin/env bash
# Continuous capture. Fires on every Read/Write/Edit/MultiEdit/Bash/Glob/Grep/WebFetch
# and appends one compact JSON line to working-state.jsonl.
#
# Stays well under 50ms so it never adds perceptible latency to a tool call.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

# If the harness gave us nothing (rare; e.g. ad-hoc invocation), exit silently.
[ -n "${AMNESIA_HOOK_INPUT:-}" ] || exit 0
amnesia::has_jq || exit 0

STATE_DIR="$(amnesia::ensure_state)"
WS="$STATE_DIR/working-state.jsonl"

# Extract fields from the input for per-tool processing.
TOOL_NAME="$(printf '%s' "$AMNESIA_HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
IS_OK="$(printf '%s' "$AMNESIA_HOOK_INPUT" | jq -r '((.tool_response.is_error // .tool_response.isError // false) | not)' 2>/dev/null || echo true)"

# For Bash tools, redact secrets from the command preview before capture.
# For all other tools, build the record directly from the input JSON.
if [ "$TOOL_NAME" = "Bash" ]; then
  RAW_CMD="$(printf '%s' "$AMNESIA_HOOK_INPUT" | jq -r '(.tool_input.command // "") | .[0:200]' 2>/dev/null || true)"
  REDACTED_CMD="$(printf '%s' "$RAW_CMD" | amnesia::redact_secrets)"
  RECORD="$(printf '%s' "$AMNESIA_HOOK_INPUT" | jq -c \
    --arg redacted_cmd "$REDACTED_CMD" '
    {
      ts: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      tool: .tool_name,
      session_id: .session_id,
      file_path: null,
      pattern: null,
      cmd_preview: $redacted_cmd,
      exit_code: (.tool_response.exit_code // .tool_response.exitCode // null),
      ok: ((.tool_response.is_error // .tool_response.isError // false) | not)
    }
  ' 2>/dev/null || true)"
else
  # Build a one-line record. Keep it small; this file grows fast on a long session.
  # Fields:
  #   ts          - hook firing time (ISO8601 UTC)
  #   tool        - tool name (Read|Edit|Bash|...)
  #   file_path   - if the tool has one (Read/Edit/Write/MultiEdit)
  #   pattern     - if Grep/Glob
  #   cmd_preview - first 200 chars of a Bash command (null for non-Bash)
  #   exit_code   - Bash exit code if present
  #   ok          - whether tool_response indicates success
  #   session_id  - parent session uuid
  RECORD="$(printf '%s' "$AMNESIA_HOOK_INPUT" | jq -c '
    {
      ts: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      tool: .tool_name,
      session_id: .session_id,
      file_path: (.tool_input.file_path // .tool_input.path // null),
      pattern: (.tool_input.pattern // .tool_input.query // null),
      cmd_preview: null,
      exit_code: (.tool_response.exit_code // .tool_response.exitCode // null),
      ok: ((.tool_response.is_error // .tool_response.isError // false) | not)
    }
  ' 2>/dev/null || true)"
fi

[ -n "$RECORD" ] || exit 0
printf '%s\n' "$RECORD" >> "$WS"

# Rotate working-state.jsonl if it exceeds AMNESIA_WS_MAX_LINES (default 5000).
amnesia::rotate_jsonl "$WS"

# Structured log: one entry per hook call.
amnesia::log_jsonl "post-tool-use" "captured" "tool=$TOOL_NAME" "ok=$IS_OK"

exit 0
