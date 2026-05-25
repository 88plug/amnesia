#!/usr/bin/env bash
# Shared helpers for amnesia hooks.
# Source this from the start of every hook script.

set -euo pipefail

# Plugin-data root. CLAUDE_PLUGIN_DATA is set only when the plugin is invoked
# by the harness; fall back to a local path for ad-hoc testing.
AMNESIA_ROOT="${CLAUDE_PLUGIN_DATA:-${HOME}/.claude/plugins/data/amnesia}"

# Derive a project slug that mirrors Claude Code's own (~/.claude/projects/<slug>):
# replace every non-alphanumeric with `-`. The user's amnesia project shows
# up as `-home-andrew-amnesia` under projects/, so the same shape is used here.
amnesia::slug() {
  local cwd="${CLAUDE_PROJECT_DIR:-${PWD:-/unknown}}"
  printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g'
}

# Per-project state dirs.
amnesia::state_dir() {
  local slug; slug="$(amnesia::slug)"
  printf '%s/projects/%s' "$AMNESIA_ROOT" "$slug"
}

amnesia::ensure_state() {
  local d; d="$(amnesia::state_dir)"
  mkdir -p "$d/handoff/archive" "$d/markers" "$d/logs"
  printf '%s' "$d"
}

amnesia::log() {
  local d; d="$(amnesia::ensure_state)"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s [%s] %s\n' "$ts" "${1:-info}" "${2:-}" >> "$d/logs/amnesia.log"
}

# Atomic write: write to a tmp sibling, then rename. Caller passes content on stdin.
amnesia::atomic_write() {
  local dest="$1"
  local tmp; tmp="${dest}.tmp.$$"
  mkdir -p "$(dirname "$dest")"
  cat > "$tmp"
  mv "$tmp" "$dest"
}

# Read JSON from stdin once, expose as $AMNESIA_HOOK_INPUT. Survives `set -u`.
amnesia::read_input() {
  if [ -t 0 ]; then
    AMNESIA_HOOK_INPUT=""
  else
    AMNESIA_HOOK_INPUT="$(cat)"
  fi
  export AMNESIA_HOOK_INPUT
}

# Pull a field from the hook input JSON without crashing if jq misses.
amnesia::field() {
  local key="$1"
  printf '%s' "${AMNESIA_HOOK_INPUT:-}" \
    | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true
}

amnesia::has_jq() { command -v jq >/dev/null 2>&1; }
amnesia::has_py() { command -v python3 >/dev/null 2>&1; }
