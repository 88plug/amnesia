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

# Build a one-line record. Keep it small; this file grows fast on a long session.
# Fields:
#   ts          - hook firing time (ISO8601 UTC)
#   tool        - tool name (Read|Edit|Bash|...)
#   file_path   - if the tool has one (Read/Edit/Write/MultiEdit)
#   pattern     - if Grep/Glob
#   cmd_preview - first 200 chars of a Bash command
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
    cmd_preview: (
      if (.tool_input.command // null) then
        (.tool_input.command | tostring | .[0:200])
      else null end
    ),
    exit_code: (.tool_response.exit_code // .tool_response.exitCode // null),
    ok: ((.tool_response.is_error // .tool_response.isError // false) | not)
  }
' 2>/dev/null || true)"

[ -n "$RECORD" ] || exit 0
printf '%s\n' "$RECORD" >> "$WS"

exit 0
