---
description: Show amnesia's current state for this project — last handoff, working-state size, recent compaction events, hook health.
allowed-tools: Bash(ls:*), Bash(stat:*), Bash(wc:*), Bash(tail:*), Bash(head:*), Bash(grep:*), Bash(jq:*), Bash(printf:*), Bash(date:*), Bash(bash:*), Bash(dirname:*), Bash(source:*)
---

# amnesia status

The user has invoked `/amnesia:status`. Report what amnesia has captured for
this project. Be concise — this is a diagnostic, not a narrative.

## Gather the data

Run these commands in order and synthesize a short status report:

`!`
# Resolve state dir via the plugin's shared helper so slash commands and
# hooks agree on the path (CLAUDE_PLUGIN_DATA is set in hook context but
# NOT in slash-command Bash — common.sh's resolver handles both).
for c in "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh" "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh "$HOME/amnesia/plugins/amnesia/hooks/lib/common.sh"; do
  [ -f "$c" ] && { source "$c"; break; }
done
STATE="$(amnesia::state_dir 2>/dev/null || printf '%s' "$HOME/.claude/plugins/data/amnesia/projects/unknown")"
echo "=== amnesia state dir ==="
echo "$STATE"
echo
if [ -d "$STATE" ]; then
  echo "=== handoff/active.md ==="
  if [ -f "$STATE/handoff/active.md" ]; then
    AGE_S=$(( $(date -u +%s) - $(stat -c %Y "$STATE/handoff/active.md" 2>/dev/null || stat -f %m "$STATE/handoff/active.md" 2>/dev/null || echo 0) ))
    SZ=$(wc -c < "$STATE/handoff/active.md")
    echo "exists, ${SZ} bytes, ${AGE_S}s old"
    echo "--- header ---"
    head -8 "$STATE/handoff/active.md"
  else
    echo "(no active handoff)"
  fi
  echo
  echo "=== handoff/archive (last 5) ==="
  ls -1t "$STATE/handoff/archive/" 2>/dev/null | head -5 || echo "(empty)"
  echo
  echo "=== working-state.jsonl ==="
  if [ -f "$STATE/working-state.jsonl" ]; then
    echo "lines: $(wc -l < "$STATE/working-state.jsonl")"
    echo "--- last 3 entries ---"
    tail -3 "$STATE/working-state.jsonl"
  else
    echo "(no working state)"
  fi
  echo
  echo "=== markers ==="
  ls -la "$STATE/markers/" 2>/dev/null | tail -n +2 || echo "(none)"
  echo
  echo "=== logs (last 10 lines) ==="
  tail -10 "$STATE/logs/amnesia.log" 2>/dev/null || echo "(no log)"
else
  echo "(amnesia has not yet captured anything for this project)"
fi
`

## Your output

Synthesize the above into a 5-line status:

- Active handoff: <age, size, source layer>
- Working state: <line count, last activity>
- Archive: <N snapshots, oldest date>
- Pending L3 marker: <yes/no>
- Recent log: <last interesting line, if any>

Then a one-line health verdict: ✅ healthy / ⚠ degraded (cite reason) / ❌ broken (cite reason).
