#!/usr/bin/env bash
# Preemptive snapshot. Fires on UserPromptSubmit with async:true. When the
# JSONL transcript suggests we're approaching the auto-compact threshold,
# fire an isolated summarizer to update active.md BEFORE compaction happens.
#
# Rationale: the L1/L2/L3 layers run AFTER compaction, using the tail of an
# already-summarized conversation. A preemptive snapshot captures the full
# pre-compact state while the JSONL still has every line. If auto-compact
# fires shortly after, the post-compact L2 can re-enrich; if the user runs
# /compact themselves, the preempt's snapshot is already on disk and will be
# loaded by SessionStart(compact).
#
# Cost discipline: at most ONE preempt per compact cycle (gated by marker).
# Re-armed by post-compact-mechanical.sh after each compaction.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/summarize.sh"
amnesia::read_input
amnesia::has_jq || exit 0
amnesia::has_py || exit 0

STATE_DIR="$(amnesia::ensure_state)"
ACTIVE="$STATE_DIR/handoff/active.md"
ARCHIVE="$STATE_DIR/handoff/archive"
PREEMPT_DONE="$STATE_DIR/markers/preempt-done-this-cycle"
L2_MARKER="$STATE_DIR/markers/l2-in-flight"

# Already preempted this cycle → silent exit.
[ -f "$PREEMPT_DONE" ] && exit 0

# L2-in-flight guard: if L2 is running and its marker is recent (<90s),
# skip the preempt to avoid racing with L2 on active.md.
if [ -f "$L2_MARKER" ]; then
  NOW_EPOCH="$(date -u +%s)"
  L2_EPOCH="$(cat "$L2_MARKER" 2>/dev/null || echo 0)"
  L2_AGE=$(( NOW_EPOCH - L2_EPOCH ))
  if [ "$L2_AGE" -lt 90 ]; then
    amnesia::log_jsonl "preempt" "skipped_l2_in_flight" "l2_age_s=$L2_AGE"
    amnesia::log info "preempt: L2 in-flight (${L2_AGE}s old); skipping"
    exit 0
  fi
fi

SESSION_ID="$(amnesia::field session_id)"
TRANSCRIPT="$(amnesia::field transcript_path)"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# Estimate context usage from JSONL line count since the most recent
# compact_boundary. There's no first-class API for this in 2.1.150 hooks.
# Tuning: typical Claude Code lines average 1-3 KB; 60K tokens ≈ 240 KB
# of JSONL ≈ ~1500 lines for typical content. We use bytes-since-boundary
# as a proxy (more stable than line count when tool results are large).
THRESHOLD_BYTES="${AMNESIA_PREEMPT_THRESHOLD_BYTES:-2000000}"  # ~2MB ≈ ~75% of 200K-token window

WALKER="$(dirname "${BASH_SOURCE[0]}")/lib/jsonl_walker.py"
BOUNDARY_LINE="$(python3 -c "
import sys; sys.path.insert(0, '$(dirname "$WALKER")')
import jsonl_walker as w
b = w.last_compact_boundary_offset('$TRANSCRIPT')
print(b if b is not None else -1)
" 2>/dev/null || echo "-1")"

# Compute bytes since the boundary. If no boundary, the whole file counts.
TOTAL_BYTES="$(stat -c %s "$TRANSCRIPT" 2>/dev/null || stat -f %z "$TRANSCRIPT" 2>/dev/null || echo 0)"
BYTES_SINCE_BOUNDARY="$TOTAL_BYTES"
if [ "$BOUNDARY_LINE" != "-1" ]; then
  # Approximate: skip the bytes before the boundary line.
  BYTES_BEFORE="$(head -n "$((BOUNDARY_LINE + 1))" "$TRANSCRIPT" | wc -c)"
  BYTES_SINCE_BOUNDARY=$(( TOTAL_BYTES - BYTES_BEFORE ))
fi

if [ "$BYTES_SINCE_BOUNDARY" -lt "$THRESHOLD_BYTES" ]; then
  exit 0  # not close enough to compact yet
fi

# We're close. Drop the marker NOW (before the slow LLM call) so a quick
# successive prompt doesn't trigger a second preempt.
date -u +%s > "$PREEMPT_DONE" || true
amnesia::log info "preempt triggered (bytes since boundary: $BYTES_SINCE_BOUNDARY ≥ $THRESHOLD_BYTES)"

# Acquire lock on active.md before reading or writing.
if ! amnesia::lock active 30; then
  amnesia::log_jsonl "preempt" "lock_timeout"
  amnesia::log warn "preempt: could not acquire lock on active.md within 30s; exiting"
  exit 0
fi

amnesia::log_jsonl "preempt" "started" "bytes_since_boundary=$BYTES_SINCE_BOUNDARY" "threshold=$THRESHOLD_BYTES" "effort=${AMNESIA_EFFORT:-max}"

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
TAIL="$(tail -c 16384 "$TRANSCRIPT" 2>/dev/null || true)"
L1_BODY=""
[ -f "$ACTIVE" ] && L1_BODY="$(cat "$ACTIVE")"

START_MS="$(date +%s%3N 2>/dev/null || printf '%d000' "$(date +%s)")"

PROMPT="$(cat <<PROMPT_EOF
A Claude Code session is approaching its compaction threshold. Compaction
HAS NOT happened yet — every line of the transcript is still in the model's
context. Produce a preemptive handoff that captures the current working
state BEFORE the lossy summarization fires. Same format as a normal handoff.
≤ 4000 chars. Be specific. Never invent — only use facts from the input.

Output MUST begin at H2 (\`## Working theory\`). Do NOT emit a top-level H1 —
the caller wraps your output with its own \`# amnesia handoff (preemptive, …)\`.

## Working theory
…

## Decisions made (so far this session)
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
INPUT BLOCK A — existing handoff if any (older context):

$L1_BODY

---
INPUT BLOCK B — Raw transcript tail (most-recent 16KB, pre-compact):

$TAIL
PROMPT_EOF
)"

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

if ! printf '%s' "$PROMPT" | amnesia::summarize 180 "preempt" > "$TMP_OUT"; then
  amnesia::log warn "preempt summarizer failed; previous handoff remains"
  amnesia::unlock active
  exit 0
fi

# Sanity check using the shared function (replaces the old head|grep check).
if ! amnesia::summarize_sanity_check "$TMP_OUT"; then
  amnesia::log_jsonl "preempt" "sanity_failed" "out_bytes=$(wc -c < "$TMP_OUT" 2>/dev/null || echo 0)"
  amnesia::log warn "preempt output malformed (sanity check failed); previous handoff remains"
  amnesia::unlock active
  exit 0
fi

amnesia::wrap_handoff \
  "preemptive, source=UserPromptSubmit-near-compact" \
  "$SESSION_ID" \
  "$TRANSCRIPT" \
  "bytes-since-last-compact: \`$BYTES_SINCE_BOUNDARY\`" \
  < "$TMP_OUT" \
  | amnesia::atomic_write "$ACTIVE"

amnesia::unlock active

cp "$ACTIVE" "$ARCHIVE/${TS_FILE}-preempt.md" || true
amnesia::log info "preemptive handoff written"

END_MS="$(date +%s%3N 2>/dev/null || printf '%d000' "$(date +%s)")"
DURATION_MS=$(( END_MS - START_MS ))
OUT_BYTES="$(wc -c < "$ACTIVE" 2>/dev/null || echo 0)"

amnesia::log_jsonl "preempt" "finished" "duration_ms=$DURATION_MS" "out_bytes=$OUT_BYTES"

exit 0
