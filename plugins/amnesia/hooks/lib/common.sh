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
export AMNESIA_ROOT

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
amnesia::has_flock() { command -v flock >/dev/null 2>&1; }

# --- Python resolution (never bare `python3` in hooks) ---------------------
# Claude's hook/MCP spawn PATH is thin. All Python work goes through
# scripts/run-python.sh (env override → venv → PATH → abs Homebrew/system).
amnesia::_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
  else
    # common.sh lives at $PLUGIN_ROOT/hooks/lib/common.sh
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd
  fi
}

amnesia::_run_python_sh() {
  local root runner
  root="$(amnesia::_plugin_root)"
  runner="${root}/scripts/run-python.sh"
  if [ -f "$runner" ]; then
    printf '%s' "$runner"
    return 0
  fi
  return 1
}

# True if a usable Python ≥3.10 can be resolved (including Homebrew abs paths).
amnesia::has_py() {
  local runner
  runner="$(amnesia::_run_python_sh)" || return 1
  bash "$runner" -c 'import sys' >/dev/null 2>&1
}

# Run Python with the resolved interpreter. Usage: amnesia::py script.py args...
# or amnesia::py -c 'code'. Returns the interpreter's exit status.
amnesia::py() {
  local runner
  runner="$(amnesia::_run_python_sh)" || {
    amnesia::log warn "run-python.sh missing; cannot invoke Python"
    return 1
  }
  bash "$runner" "$@"
}

# === v0.3.0 helpers ===

# Structured JSONL logger. Writes one event per line to logs/events.jsonl,
# alongside the legacy plaintext amnesia.log. Caller passes a hook name and
# JSON-encoded key/value pairs (each pair as one arg, "k=v" or "k=\"v\"" form).
# Numeric and boolean values pass through; strings are quoted automatically.
amnesia::log_jsonl() {
  local d; d="$(amnesia::ensure_state)"
  local hook="${1:-unknown}"; shift || true
  local event="${1:-event}"; shift || true
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  local body=""
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # If v is a number or true/false/null, emit raw; else string-quote.
    # Split the literal cases out of the regex: an unquoted '|' alternation inside
    # [[ =~ ]] is a parse error under zsh, which breaks `source common.sh` when a
    # slash command sources this lib in the user's shell (hooks run it under bash).
    if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ || "$v" == true || "$v" == false || "$v" == null ]]; then
      body+=",\"$k\":$v"
    else
      v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//$'\n'/\\n}"
      body+=",\"$k\":\"$v\""
    fi
  done
  printf '{"ts":"%s","hook":"%s","event":"%s"%s}\n' "$ts" "$hook" "$event" "$body" \
    >> "$d/logs/events.jsonl"
}

# Acquire an exclusive lock on a named resource for the active project. Used
# to serialize writers to active.md so concurrent compactions / sessions
# don't race. Falls back to a no-op if flock isn't installed.
#
# Usage:
#   amnesia::lock active 30 || { amnesia::log warn "lock failed"; exit 0; }
#   ... critical section ...
#   amnesia::unlock active
#
# $1 = lock name (e.g. "active", "archive")
# $2 = timeout in seconds (default 30)
amnesia::lock() {
  local name="${1:-default}"
  local timeout="${2:-30}"
  amnesia::has_flock || return 0
  local d; d="$(amnesia::ensure_state)"
  local lockfile="$d/.lock-$name"
  # File descriptor 9 reserved for amnesia locks within a single shell.
  local fd_var="AMNESIA_LOCK_FD_${name//[^A-Za-z0-9]/_}"
  exec 9>"$lockfile"
  if ! flock -w "$timeout" 9; then
    return 1
  fi
  eval "export $fd_var=9"
  return 0
}

amnesia::unlock() {
  local name="${1:-default}"
  local fd_var="AMNESIA_LOCK_FD_${name//[^A-Za-z0-9]/_}"
  if [ -n "${!fd_var:-}" ]; then
    exec 9>&- 2>/dev/null || true
    unset "$fd_var"
  fi
}

# Enumerate every existing amnesia data root on this machine. Used by the
# status command to surface orphaned data dirs the active resolver no longer
# points at (e.g. you reinstalled from a different marketplace).
amnesia::all_data_roots() {
  local d
  for d in "$HOME"/.claude/plugins/data/amnesia "$HOME"/.claude/plugins/data/amnesia-*; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done | awk '!seen[$0]++'
}

# Rotate a JSONL file when it crosses a line threshold. Keeps the last N
# lines in place and moves the rest into archive/<basename>-<ts>.jsonl.gz
# (or .jsonl if gzip isn't available). Lossless — no entries are dropped.
#
# $1 = path to the .jsonl file
# $2 = keep-tail line count (default $AMNESIA_WS_MAX_LINES or 5000)
amnesia::rotate_jsonl() {
  local file="$1"
  local keep="${2:-${AMNESIA_WS_MAX_LINES:-5000}}"
  [ -f "$file" ] || return 0
  local lines; lines="$(wc -l < "$file" 2>/dev/null || echo 0)"
  [ "$lines" -gt "$keep" ] || return 0

  local d; d="$(amnesia::ensure_state)"
  local archive="$d/logs/archive"
  mkdir -p "$archive"
  local base; base="$(basename "$file" .jsonl)"
  local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local archived="$archive/${base}-${ts}.jsonl"

  local split=$((lines - keep))
  if head -n "$split" "$file" > "$archived" 2>/dev/null; then
    if command -v gzip >/dev/null 2>&1; then
      gzip "$archived" 2>/dev/null && archived="${archived}.gz"
    fi
    local tmp; tmp="${file}.rotate.$$"
    if tail -n "$keep" "$file" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$file"
      amnesia::log_jsonl "rotate" "rotated" "file=$(basename "$file")" "moved_lines=$split" "kept_lines=$keep" "archive=$(basename "$archived")"
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
}

# Prune the handoff archive to the N most recent entries.
#
# $1 = state dir (default: amnesia::ensure_state)
# $2 = keep count (default $AMNESIA_ARCHIVE_KEEP or 50)
amnesia::prune_archive() {
  local d="${1:-$(amnesia::ensure_state)}"
  local keep="${2:-${AMNESIA_ARCHIVE_KEEP:-50}}"
  local archive="$d/handoff/archive"
  [ -d "$archive" ] || return 0
  local total; total="$(find "$archive" -maxdepth 1 -name '*.md' | wc -l)"
  [ "$total" -gt "$keep" ] || return 0
  local rm_n=$((total - keep))
  find "$archive" -maxdepth 1 -name '*.md' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | head -n "$rm_n" | cut -d' ' -f2- \
    | while IFS= read -r f; do
        [ -f "$f" ] && rm -f "$f"
      done
  amnesia::log_jsonl "prune" "pruned_archive" "removed=$rm_n" "kept=$keep"
}

# Redact common secret patterns from a string before it touches the JSONL
# capture or the summarizer. Conservative — only the most obvious shapes.
#
# Reads from stdin, writes to stdout. Patterns:
#   Authorization: Bearer <token>
#   --token=<value>  --token <value>
#   --api-key=<value>  --api-key <value>
#   _KEY=value      _SECRET=value   _PASSWORD=value   _TOKEN=value
#   ghp_/gho_/ghs_/ghu_/github_pat_/sk-/xoxb-/xoxp-/AKIA prefix tokens
amnesia::redact_secrets() {
  sed -E \
    -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+/\1***REDACTED***/gI' \
    -e 's/(--?(token|api[-_]?key|password|secret)[= ])[^ "'"'"']+/\1***REDACTED***/gI' \
    -e 's/((PASSWORD|TOKEN|SECRET|API[_-]?KEY|PRIVATE[_-]?KEY)[A-Z_]*=)[^ "'"'"']+/\1***REDACTED***/g' \
    -e 's/\b(ghp|gho|ghs|ghu)_[A-Za-z0-9]{20,}/\1_***REDACTED***/g' \
    -e 's/\bgithub_pat_[A-Za-z0-9_]{20,}/github_pat_***REDACTED***/g' \
    -e 's/\bsk-[A-Za-z0-9_-]{20,}/sk-***REDACTED***/g' \
    -e 's/\bxox[bpas]-[A-Za-z0-9-]{10,}/xox-***REDACTED***/g' \
    -e 's/\bAKIA[A-Z0-9]{16}/AKIA***REDACTED***/g'
}

# Cheap git-state probe for the active project. Returns a JSON object on
# stdout. Empty {} if not in a git repo or git unavailable. Used by L1 to
# embed in the handoff and by SessionStart to detect drift across restore.
amnesia::git_state() {
  command -v git >/dev/null 2>&1 || { printf '{}\n'; return 0; }
  local cwd="${CLAUDE_PROJECT_DIR:-${PWD:-/unknown}}"
  [ -d "$cwd/.git" ] || (cd "$cwd" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1) \
    || { printf '{}\n'; return 0; }
  local branch sha dirty stash remote
  branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  sha="$(git -C "$cwd" rev-parse HEAD 2>/dev/null | cut -c1-12 || echo unknown)"
  dirty="$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  stash="$(git -C "$cwd" stash list 2>/dev/null | wc -l | tr -d ' ')"
  remote="$(git -C "$cwd" config --get remote.origin.url 2>/dev/null || echo '')"
  printf '{"branch":"%s","head":"%s","dirty_files":%s,"stash":%s,"remote":"%s"}\n' \
    "$branch" "$sha" "${dirty:-0}" "${stash:-0}" "$remote"
}
