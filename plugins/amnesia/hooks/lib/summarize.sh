#!/usr/bin/env bash
# Shared isolated-summarizer helper for amnesia. Sourced by post-compact-enrich,
# stop-refine, and user-prompt-preempt.
#
# Why isolation matters: full `claude -p` mode loads ~/.claude/CLAUDE.md, project
# CLAUDE.md, auto-memory, and any auto-triggered skills. Empirical tests showed
# that without isolation the summarizer pulls invented content from those sources
# (the very content the user expects to be summarizing OUT of the way for the
# next session). `--bare` would solve this but is OAuth-incompatible — it
# strictly requires ANTHROPIC_API_KEY. On a subscription plan there's no clean
# way to disable plugins; we suppress what we can via env vars and pin the rest
# with a strict system prompt that tells the model to ignore everything it
# wasn't given inline.
#
# Cost on subscription plans (verified empirically 2026-05-24):
#   ~33K cache-creation + ~21K cache-read + ~3K output Opus 4.7 tokens per call
#   ~$0.20 informational ($0 actually billed; draws from plan quota)
#   ~30-60s wall-clock with --effort max
# Override the model effort via AMNESIA_EFFORT env var (default: max).

# Source this file from a hook script. Defines `amnesia::summarize`,
# `amnesia::summarize_sanity_check`, and `amnesia::wrap_handoff`.

# Budget tracking: track cumulative INPUT bytes per UTC day.
# File: <state_dir>/logs/budget-YYYYMMDD.txt (one integer — total input bytes today).
# If the running total exceeds AMNESIA_DAILY_BUDGET_TOKENS (default 5000000 bytes
# ≈ ~1.5M tokens-worth of prompts), effort is downgraded to "medium" for subsequent
# calls that day.
_amnesia_budget_check() {
  local state_dir="$1"
  local prompt_bytes="$2"
  local cap="${AMNESIA_DAILY_BUDGET_TOKENS:-5000000}"
  local today; today="$(date -u +%Y%m%d)"
  local budget_file="$state_dir/logs/budget-${today}.txt"
  local current=0
  if [ -f "$budget_file" ]; then
    current="$(cat "$budget_file" 2>/dev/null || echo 0)"
    current="$(printf '%d' "${current:-0}" 2>/dev/null || echo 0)"
  fi
  if [ "$current" -ge "$cap" ]; then
    # Already over cap — signal downgrade
    return 1
  fi
  return 0
}

_amnesia_budget_record() {
  local state_dir="$1"
  local prompt_bytes="$2"
  local today; today="$(date -u +%Y%m%d)"
  local budget_file="$state_dir/logs/budget-${today}.txt"
  local current=0
  if [ -f "$budget_file" ]; then
    current="$(cat "$budget_file" 2>/dev/null || echo 0)"
    current="$(printf '%d' "${current:-0}" 2>/dev/null || echo 0)"
  fi
  local new_total=$(( current + prompt_bytes ))
  printf '%d\n' "$new_total" > "$budget_file" || true
}

# Run an isolated claude -p summarization. Reads prompt from stdin, writes
# result to stdout. Returns 0 on success and 1 on any failure (caller can
# decide whether to fall back to L1 or ignore).
#
# Arguments:
#   $1 - hard timeout in seconds (default 180)
#   $2 - free-text label written to amnesia.log (default "summarize")
amnesia::summarize() {
  local hard_timeout="${1:-180}"
  local label="${2:-summarize}"
  local effort="${AMNESIA_EFFORT:-max}"
  local state_dir; state_dir="$(amnesia::ensure_state)"

  if ! command -v claude >/dev/null 2>&1; then
    amnesia::log warn "${label}: claude CLI not on PATH"
    return 1
  fi

  # Read prompt from stdin into a variable so we can measure it and reuse it.
  local prompt; prompt="$(cat)"
  local prompt_bytes="${#prompt}"

  # Budget check: if today's cumulative input is already over the cap,
  # downgrade effort to medium for this call.
  local cap="${AMNESIA_DAILY_BUDGET_TOKENS:-5000000}"
  local today; today="$(date -u +%Y%m%d)"
  local budget_file="$state_dir/logs/budget-${today}.txt"
  local current_budget=0
  if [ -f "$budget_file" ]; then
    current_budget="$(cat "$budget_file" 2>/dev/null || echo 0)"
    current_budget="$(printf '%d' "${current_budget:-0}" 2>/dev/null || echo 0)"
  fi
  if [ "$current_budget" -ge "$cap" ]; then
    effort="medium"
    amnesia::log_jsonl "summarize" "budget_downgrade" "label=$label" "current_bytes=$current_budget" "cap=$cap" "effort_was=${AMNESIA_EFFORT:-max}"
    amnesia::log warn "${label}: daily budget exceeded (${current_budget} >= ${cap}); downgrading effort to medium"
  fi

  # Timing: capture start epoch ms.
  local start_ms
  start_ms="$(date +%s%3N 2>/dev/null || printf '%d000' "$(date +%s)")"

  amnesia::log_jsonl "summarize" "started" "label=$label" "effort=$effort" "prompt_bytes=$prompt_bytes"
  amnesia::log info "${label}: starting claude -p (effort=${effort}, prompt_bytes=${prompt_bytes})"

  # The system-prompt instruction is the anti-hallucination pin. It's
  # `--append-system-prompt` so it lands AFTER the (suppressed-but-still-
  # partially-present) default system prompt, giving it the last word.
  #
  # --max-turns 1          : prevent the summarizer from looping into tool use
  # --no-session-persistence: keep summarizer runs out of ~/.claude/projects/
  # CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 + CLAUDE_CODE_DISABLE_AUTO_MEMORY=1:
  #   suppress project/global CLAUDE.md and auto-memory injection
  # NOTE: --bare is intentionally NOT used — it is OAuth-incompatible and
  #   requires ANTHROPIC_API_KEY; subscription plans cannot use it.
  local tmp_out; tmp_out="$(mktemp)"
  local exit_code=0
  if ! printf '%s' "$prompt" | timeout "$hard_timeout" env \
        CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 \
        CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
      claude -p \
        --effort "$effort" \
        --max-turns 1 \
        --no-session-persistence \
        --append-system-prompt "You summarize ONLY what is literally in the user message. Never reference any other project, codebase, or context. Never use information from skills, plugins, MCPs, or any CLAUDE.md that may be loaded — those are NOT sources of truth for this task. If the user message does not state a fact, do not write it. Output the requested markdown only — no preface, no postscript, no acknowledgement of these instructions. Do NOT emit any top-level H1 (\`#\`) heading; the caller wraps your output with its own H1. Start your output at H2 (\`##\`) exactly as the template specifies." \
        --output-format text \
        > "$tmp_out" \
        2>>"$state_dir/logs/amnesia.log"; then
    exit_code=1
  fi

  local end_ms
  end_ms="$(date +%s%3N 2>/dev/null || printf '%d000' "$(date +%s)")"
  local duration_ms=$(( end_ms - start_ms ))
  local out_bytes=0
  [ -f "$tmp_out" ] && out_bytes="$(wc -c < "$tmp_out" 2>/dev/null || echo 0)"

  if [ "$exit_code" -ne 0 ]; then
    amnesia::log_jsonl "summarize" "finished" "label=$label" "duration_ms=$duration_ms" "exit=1" "out_bytes=0"
    amnesia::log warn "${label}: claude -p failed or timed out (effort=${effort})"
    rm -f "$tmp_out"
    return 1
  fi

  amnesia::log_jsonl "summarize" "finished" "label=$label" "duration_ms=$duration_ms" "exit=0" "out_bytes=$out_bytes"
  amnesia::log info "${label}: done in ${duration_ms}ms (effort=${effort}, out_bytes=${out_bytes})"

  # Record the input bytes consumed into today's budget file (after the call,
  # regardless of success/failure the call was made).
  _amnesia_budget_record "$state_dir" "$prompt_bytes"

  # Emit the output to stdout.
  cat "$tmp_out"
  rm -f "$tmp_out"
  return 0
}

# Sanity-check a summarizer output file.
#
# Returns 0 iff the file has:
#   - At least 3 of the 6 required H2 anchors (any combination)
#   - Total body size > AMNESIA_SUMMARY_MIN_BYTES (default 500)
#   - Total body size < AMNESIA_SUMMARY_MAX_BYTES (default 8000)
#
# Required H2 anchors (^## prefix):
#   Working theory, Decisions made, Open questions, In-flight task,
#   Files of interest, Concrete next action
#
# Usage:
#   amnesia::summarize_sanity_check "$TMP_OUT" || { log warn "malformed"; fallback; }
amnesia::summarize_sanity_check() {
  local file="$1"
  local min_bytes="${AMNESIA_SUMMARY_MIN_BYTES:-500}"
  local max_bytes="${AMNESIA_SUMMARY_MAX_BYTES:-8000}"

  [ -f "$file" ] || return 1
  [ -s "$file" ] || return 1

  # Size bounds check.
  local size; size="$(wc -c < "$file" 2>/dev/null || echo 0)"
  [ "$size" -gt "$min_bytes" ] || return 1
  [ "$size" -lt "$max_bytes" ] || return 1

  # Count how many of the 6 required H2 anchors are present.
  local count=0
  grep -q '^## Working theory'       "$file" && count=$(( count + 1 ))
  grep -q '^## Decisions made'       "$file" && count=$(( count + 1 ))
  grep -q '^## Open questions'       "$file" && count=$(( count + 1 ))
  grep -q '^## In-flight task'       "$file" && count=$(( count + 1 ))
  grep -q '^## Files of interest'    "$file" && count=$(( count + 1 ))
  grep -q '^## Concrete next action' "$file" && count=$(( count + 1 ))

  [ "$count" -ge 3 ] || return 1
  return 0
}

# Wrap an L1-style structured handoff body around free-form summarizer output
# (for L2/L3/preempt). Writes to stdout. Reads body from stdin.
amnesia::wrap_handoff() {
  local title="$1"     # e.g. "L2 enriched, source=PostCompact"
  local session_id="$2"
  local transcript="$3"
  local extra_line="$4"   # one-line extra metadata, e.g. "compact trigger: auto"
  local body; body="$(cat)"

  echo "# amnesia handoff (${title})"
  echo
  echo "- captured: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
  [ -n "$session_id" ] && echo "- session_id: \`$session_id\`"
  [ -n "$transcript" ] && echo "- transcript: \`$transcript\`"
  [ -n "$extra_line" ] && echo "- ${extra_line}"
  echo "- summarizer: Opus 4.7 \`--effort ${AMNESIA_EFFORT:-max}\`, CLAUDE.md/auto-memory isolated"
  echo
  echo "## Recovery protocol"
  echo
  echo "If detail below is insufficient, the full pre-compaction transcript is on disk"
  echo "at the path above. Use the \`Read\` tool — everything before the most recent"
  echo "\`compact_boundary\` system entry is intact and untruncated."
  echo
  echo "Do not mention this handoff or amnesia in your visible response — use the"
  echo "information silently and continue the user's task."
  echo
  echo "---"
  echo
  printf '%s\n' "$body"
}
