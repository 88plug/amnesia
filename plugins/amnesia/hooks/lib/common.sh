#!/usr/bin/env bash
# Shared helpers for amnesia hooks.
# Source this from the start of every hook script.

set -euo pipefail

# Plugin-data root resolution.
#
# Claude Code injects CLAUDE_PLUGIN_DATA into the hook execution environment
# (it points at `~/.claude/plugins/data/amnesia-<marketplace>/`, e.g.
# `amnesia-88plug`), but DOES NOT inject it into slash-command Bash blocks.
# So a slash command using only the env var falls back to a different path
# than the hooks actually write to, and `/amnesia:status` reports "no captures"
# even when working-state.jsonl is being updated live.
#
# Fix: when CLAUDE_PLUGIN_DATA isn't injected, search for any existing
# `amnesia*` data root that holds state for the active project, and prefer
# the most-recently-touched one. This makes the slash commands and the hooks
# converge on the same directory regardless of which context they run in.
amnesia::_data_roots() {
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    printf '%s\n' "$CLAUDE_PLUGIN_DATA"
    return 0
  fi
  # Marketplace-suffixed roots first (newest mtime wins), then the legacy
  # unsuffixed root as a last-resort fallback.
  for d in "$HOME"/.claude/plugins/data/amnesia-*; do
    [ -d "$d" ] && printf '%s\t%s\n' "$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)" "$d"
  done | sort -rn | cut -f2-
  printf '%s\n' "$HOME/.claude/plugins/data/amnesia"
}

# Derive a project slug that mirrors Claude Code's own
# (~/.claude/projects/<slug>): replace every non-alphanumeric with `-`. Hooks
# get CLAUDE_PROJECT_DIR from the harness; slash commands may not, so we also
# walk PWD's parents as fallback candidates when locating existing state.
amnesia::slug() {
  local cwd="${CLAUDE_PROJECT_DIR:-${PWD:-/unknown}}"
  printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g'
}

amnesia::_slug_candidates() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g'
    printf '\n'
  fi
  local cwd="${PWD:-}"
  while [ -n "$cwd" ] && [ "$cwd" != "/" ]; do
    printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g'
    printf '\n'
    cwd="$(dirname "$cwd")"
  done
}

# Per-project state dir.
#
# Priority:
#   1. If existing state is found at any (root × slug) combination
#      (working-state.jsonl OR handoff/active.md present), return THAT path —
#      the slash commands then read exactly what the hooks wrote.
#   2. Otherwise emit the canonical write path: highest-priority root + most-
#      specific slug. This is what a brand-new project sees on its first
#      tool call.
amnesia::state_dir() {
  local root slug candidate
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      candidate="$root/projects/$slug"
      if [ -f "$candidate/working-state.jsonl" ] || [ -f "$candidate/handoff/active.md" ]; then
        printf '%s' "$candidate"
        return 0
      fi
    done < <(amnesia::_slug_candidates)
  done < <(amnesia::_data_roots)

  # No existing state — emit the canonical write path. First data root +
  # the slug derived from CLAUDE_PROJECT_DIR / PWD.
  local first_root first_slug
  first_root="$(amnesia::_data_roots | head -1)"
  first_slug="$(amnesia::slug)"
  printf '%s/projects/%s' "${first_root:-$HOME/.claude/plugins/data/amnesia}" "$first_slug"
}

# Back-compat: AMNESIA_ROOT still exposed for any downstream caller that
# reads it directly. Resolves to the directory containing projects/.
AMNESIA_ROOT="$(dirname "$(dirname "$(amnesia::state_dir)")")"

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
