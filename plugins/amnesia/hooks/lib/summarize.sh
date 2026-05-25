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

# Source this file from a hook script. Defines `amnesia::summarize`.

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

  # The system-prompt instruction is the anti-hallucination pin. It's
  # `--append-system-prompt` so it lands AFTER the (suppressed-but-still-
  # partially-present) default system prompt, giving it the last word.
  if ! timeout "$hard_timeout" env \
        CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 \
        CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
      claude -p \
        --effort "$effort" \
        --no-session-persistence \
        --append-system-prompt "You summarize ONLY what is literally in the user message. Never reference any other project, codebase, or context. Never use information from skills, plugins, MCPs, or any CLAUDE.md that may be loaded — those are NOT sources of truth for this task. If the user message does not state a fact, do not write it. Output the requested markdown only — no preface, no postscript, no acknowledgement of these instructions. Do NOT emit any top-level H1 (\`#\`) heading; the caller wraps your output with its own H1. Start your output at H2 (\`##\`) exactly as the template specifies." \
        --output-format text \
        2>>"$state_dir/logs/amnesia.log"; then
    amnesia::log warn "${label}: claude -p failed or timed out (effort=${effort})"
    return 1
  fi
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
