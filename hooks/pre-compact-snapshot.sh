#!/usr/bin/env bash
# PreCompact hook — lossless tail capture before context compaction.
#
# Fires synchronously on PreCompact. Tails the last AMNESIA_PRECOMPACT_TAIL_LINES
# (default 1000) lines of the transcript into markers/pre-compact-snapshot.jsonl
# so post-compact-mechanical.sh can read raw tool activity that compaction would
# otherwise discard.
#
# Design constraints:
#   - Sync, must finish fast (<100ms). No LLM calls.
#   - NEVER exits non-zero — must not block compaction.
#   - post-compact-mechanical.sh consumes and deletes the sidecar.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

STATE_DIR="$(amnesia::ensure_state)"
SNAPSHOT="$STATE_DIR/markers/pre-compact-snapshot.jsonl"

TRANSCRIPT="$(amnesia::field transcript_path)"
TAIL_LINES="${AMNESIA_PRECOMPACT_TAIL_LINES:-1000}"

# If no transcript provided (e.g. manual /compact with no live session), log and exit.
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  amnesia::log_jsonl "PreCompact" "snapshot_skipped" "reason=no_transcript"
  exit 0
fi

# Tail the transcript. Use a tmp file + mv so readers never see a partial write.
TMP_SNAP="${SNAPSHOT}.tmp.$$"
trap 'rm -f "$TMP_SNAP"' EXIT

if tail -n "$TAIL_LINES" "$TRANSCRIPT" > "$TMP_SNAP" 2>/dev/null; then
  mv "$TMP_SNAP" "$SNAPSHOT"
  N="$(wc -l < "$SNAPSHOT" 2>/dev/null || echo 0)"
  amnesia::log_jsonl "PreCompact" "snapshot_written" "lines=$N"
else
  amnesia::log_jsonl "PreCompact" "snapshot_failed" "reason=tail_error"
fi

exit 0
