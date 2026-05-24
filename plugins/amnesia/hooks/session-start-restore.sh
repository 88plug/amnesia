#!/usr/bin/env bash
# Fires on SessionStart with matcher `compact|resume|startup`. Reads active.md
# and emits it as additionalContext so the freshly-started/compacted session has
# the handoff in its first message.
#
# Cross-session restore (source ≠ compact) is gated by:
#   - cwd of the saved handoff must match current cwd (defends against
#     accidentally rehydrating another project's context)
#   - handoff age must be under MAX_AGE_SECONDS (default 24h, configurable)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

amnesia::has_jq || exit 0

MAX_AGE_SECONDS="${AMNESIA_MAX_AGE_SECONDS:-86400}"   # 24h default

STATE_DIR="$(amnesia::ensure_state)"
ACTIVE="$STATE_DIR/handoff/active.md"

SOURCE="$(amnesia::field source)"
CUR_CWD="$(amnesia::field cwd)"
[ -n "$CUR_CWD" ] || CUR_CWD="${CLAUDE_PROJECT_DIR:-${PWD:-/unknown}}"

# No handoff = nothing to inject. Exit silently; harness treats this as a no-op.
[ -f "$ACTIVE" ] || exit 0

# For sources other than `compact`, apply the cross-session guards.
if [ "$SOURCE" != "compact" ]; then
  # cwd guard: the handoff embeds its source cwd in a `- cwd: ` line.
  SAVED_CWD="$(grep -m1 '^- cwd:' "$ACTIVE" | sed -E 's/^- cwd: `(.*)`$/\1/' || true)"
  if [ -n "$SAVED_CWD" ] && [ "$SAVED_CWD" != "$CUR_CWD" ]; then
    amnesia::log info "session-start: cwd mismatch (saved=$SAVED_CWD cur=$CUR_CWD); not injecting"
    exit 0
  fi

  # Age guard.
  if [ -n "${MAX_AGE_SECONDS:-}" ] && [ "$MAX_AGE_SECONDS" -gt 0 ]; then
    NOW_EPOCH="$(date -u +%s)"
    FILE_EPOCH="$(stat -c %Y "$ACTIVE" 2>/dev/null || stat -f %m "$ACTIVE" 2>/dev/null || echo 0)"
    AGE=$(( NOW_EPOCH - FILE_EPOCH ))
    if [ "$AGE" -gt "$MAX_AGE_SECONDS" ]; then
      amnesia::log info "session-start: handoff age ${AGE}s > max ${MAX_AGE_SECONDS}s; not injecting"
      exit 0
    fi
  fi
fi

# Build the injected text. Preamble teaches the recovery protocol; body is the
# handoff verbatim. The harness logs `additionalContextChars` but does not
# enforce a hard cap in 2.1.150; we still keep it reasonable.
BODY="$(cat "$ACTIVE")"
PREAMBLE="$(cat <<EOF
[amnesia / source=${SOURCE:-unknown}] Continuity record from the previous slice of this
session is reattached below. The model that wrote it had full context; you do
not. Treat the handoff as authoritative for *what was happening*, and use the
transcript path it cites for any detail it omits.

If anything below conflicts with what you observe now, trust observation —
files on disk and command outputs supersede the handoff.

--- handoff begins ---
EOF
)"

# Truncate body to a generous-but-finite 18000 chars to stay polite to the
# context window even though no hard cap is enforced.
if [ "${#BODY}" -gt 18000 ]; then
  BODY="${BODY:0:18000}

[...handoff truncated at 18KB; read $ACTIVE for full text...]"
fi

INJECTED="$(printf '%s\n\n%s\n--- handoff ends ---' "$PREAMBLE" "$BODY")"

# Emit the hookSpecificOutput envelope.
jq -n --arg c "$INJECTED" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $c
  }
}'

amnesia::log info "session-start: injected handoff (${#INJECTED} chars, source=$SOURCE)"
exit 0
