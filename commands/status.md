---
description: Show amnesia's current state for this project — last handoff, working-state size, recent compaction events, hook health.
allowed-tools: Bash(ls:*), Bash(stat:*), Bash(wc:*), Bash(tail:*), Bash(head:*), Bash(grep:*), Bash(jq:*), Bash(printf:*), Bash(date:*), Bash(bash:*), Bash(dirname:*), Bash(source:*), Bash(awk:*), Bash(find:*)
---

# amnesia status

The user has invoked `/amnesia:status`. Report what amnesia has captured for
this project. Be concise — this is a diagnostic, not a narrative.

## Gather the data

Run this command and synthesize a short status report:

`!`
# Prefer the harness-injected root, else find any installed amnesia plugin.
LIB="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh"
[ -f "$LIB" ] || LIB="$(ls -t "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh 2>/dev/null | head -1)"
[ -f "$LIB" ] && source "$LIB"

STATE="$(amnesia::state_dir 2>/dev/null || printf '%s' "$HOME/.claude/plugins/data/amnesia/projects/unknown")"
SLUG="$(amnesia::slug 2>/dev/null || printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[^A-Za-z0-9]/-/g')"
ACTIVE_ROOT="$(dirname "$(dirname "$STATE")")"

echo "=== project ==="
echo "slug:       $SLUG"
echo "state dir:  $STATE"
echo "active root: $ACTIVE_ROOT"
echo

echo "=== data roots ==="
while IFS= read -r root; do
  if [ "$root" = "$ACTIVE_ROOT" ]; then
    printf '  [ACTIVE] %s\n' "$root"
  else
    printf '  [orphan] %s\n' "$root"
  fi
done < <(amnesia::all_data_roots 2>/dev/null || printf '%s\n' "$ACTIVE_ROOT")
echo

if [ ! -d "$STATE" ]; then
  echo "(amnesia has not yet captured anything for this project)"
  exit 0
fi

echo "=== events.jsonl summary ==="
EVENTS="$STATE/logs/events.jsonl"
if [ -f "$EVENTS" ]; then
  TAIL50="$(tail -50 "$EVENTS" 2>/dev/null)"

  # Last L2 success
  LAST_L2="$(printf '%s\n' "$TAIL50" | grep '"hook":"L2"' | grep '"event":"finished"' | grep '"exit":0' | tail -1 || true)"
  if [ -n "$LAST_L2" ]; then
    L2_TS="$(printf '%s\n' "$LAST_L2" | jq -r '.ts // empty' 2>/dev/null || true)"
    if [ -n "$L2_TS" ]; then
      NOW_S="$(date -u +%s)"
      L2_S="$(date -u -d "$L2_TS" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$L2_TS" +%s 2>/dev/null || echo 0)"
      L2_AGO_MIN=$(( (NOW_S - L2_S) / 60 ))
      printf '  Last L2 success: %s (%s min ago)\n' "$L2_TS" "$L2_AGO_MIN"
    fi
  else
    echo "  Last L2 success: (none in last 50 events)"
  fi

  # L2 success rate over last 10 attempts
  L2_ATTEMPTS="$(printf '%s\n' "$TAIL50" | grep '"hook":"L2"' | grep '"event":"finished"' | tail -10)"
  L2_TOTAL="$(printf '%s\n' "$L2_ATTEMPTS" | grep -c '"hook":"L2"' || echo 0)"
  L2_OK="$(printf '%s\n' "$L2_ATTEMPTS" | grep -c '"exit":0' || echo 0)"
  printf '  L2 success rate (last 10): %s/%s\n' "$L2_OK" "$L2_TOTAL"

  # L3 success rate over last 10 attempts
  L3_ATTEMPTS="$(tail -50 "$EVENTS" | grep '"hook":"L3"' | grep '"event":"finished"' | tail -10)"
  L3_TOTAL="$(printf '%s\n' "$L3_ATTEMPTS" | grep -c '"hook":"L3"' || echo 0)"
  L3_OK="$(printf '%s\n' "$L3_ATTEMPTS" | grep -c '"exit":0' || echo 0)"
  printf '  L3 success rate (last 10): %s/%s\n' "$L3_OK" "$L3_TOTAL"
  if [ "${L2_TOTAL:-0}" = "0" ] && [ "${L3_TOTAL:-0}" = "0" ]; then
    echo "  NOTE: L2/L3 0/0 = no compaction has happened yet (idle/normal), NOT broken hooks."
    echo "        Continuous capture (L1) health is the working-state.jsonl / events.jsonl growth below."
  fi

  # L2 in-flight
  INFLIGHT="$STATE/markers/l2-in-flight"
  if [ -f "$INFLIGHT" ]; then
    AGE_S=$(( $(date -u +%s) - $(stat -c %Y "$INFLIGHT" 2>/dev/null || stat -f %m "$INFLIGHT" 2>/dev/null || echo 0) ))
    if [ "$AGE_S" -lt 90 ]; then
      printf '  L2 in flight: YES (%ss old)\n' "$AGE_S"
    else
      printf '  L2 in flight: stale marker (%ss old)\n' "$AGE_S"
    fi
  else
    echo "  L2 in flight: no"
  fi

  # L3 marker armed
  if [ -f "$STATE/markers/need-l3-enrichment" ]; then
    echo "  L3 marker armed: YES"
  else
    echo "  L3 marker armed: no"
  fi
else
  echo "  (no events.jsonl — hooks may not have fired yet)"
fi
echo

echo "=== working-state.jsonl ==="
WS="$STATE/working-state.jsonl"
if [ -f "$WS" ]; then
  WS_LINES="$(wc -l < "$WS")"
  WS_SIZE="$(stat -c %s "$WS" 2>/dev/null || stat -f %z "$WS" 2>/dev/null || echo '?')"
  printf '  lines: %s  size: %s bytes\n' "$WS_LINES" "$WS_SIZE"
else
  echo "  (no working-state.jsonl)"
fi
echo

echo "=== handoff/archive ==="
ARCHIVE="$STATE/handoff/archive"
if [ -d "$ARCHIVE" ]; then
  ARCH_COUNT="$(ls -1 "$ARCHIVE"/*.md 2>/dev/null | wc -l || echo 0)"
  printf '  count: %s\n' "$ARCH_COUNT"
  ls -1t "$ARCHIVE"/*.md 2>/dev/null | head -3 | while IFS= read -r f; do
    printf '  %s\n' "$(basename "$f")"
  done
else
  echo "  (no archive dir)"
fi
echo

echo "=== today's budget ==="
TODAY="$(date -u +%Y%m%d)"
BUDGET_FILE="$STATE/logs/budget-${TODAY}.txt"
if [ -f "$BUDGET_FILE" ]; then
  cat "$BUDGET_FILE"
else
  echo "  (no budget file for $TODAY)"
fi
echo

echo "=== handoff preview (head -20) ==="
if [ -f "$STATE/handoff/active.md" ]; then
  AGE_S=$(( $(date -u +%s) - $(stat -c %Y "$STATE/handoff/active.md" 2>/dev/null || stat -f %m "$STATE/handoff/active.md" 2>/dev/null || echo 0) ))
  SZ=$(wc -c < "$STATE/handoff/active.md")
  printf '  %s bytes, %ss old\n' "$SZ" "$AGE_S"
  echo "---"
  head -20 "$STATE/handoff/active.md"
else
  echo "  (no active handoff)"
fi
``

## Your output

Synthesize the above into 3-5 lines of diagnosis. Interpret the signals correctly — do
not mistake an idle install for a broken one:

- **Continuous capture (L1)** runs on every tool call via the PostToolUse hook. The proof
  it's working is `working-state.jsonl` / `events.jsonl` GROWING — recent entries mean
  capture is healthy. Only a total absence of `events.jsonl` *after real tool use this
  session* indicates capture isn't firing.
- **L2/L3 fire only on a compaction.** An L2/L3 rate of `0/0` means **no compaction has
  happened yet** (a fresh project, or no compaction this session). This is NORMAL — do NOT
  report "hooks not firing" or "auto-capture dead" from a `0/0` rate. Treat L2/L3 as a
  problem only if a compaction actually occurred (archive entries exist, or working-state
  is large) yet no handoff was produced, or if an explicit hook error is present.
- Cite the handoff age; flag L2 stuck in flight, a stale L3 marker, orphan roots (suggest
  `/amnesia:migrate`), or working-state >5000 lines.
- End with a one-line verdict:
  - **healthy** — capture active (working-state/events growing) and nothing stuck;
  - **idle** — installed and clean but nothing captured yet / no compaction yet (the
    expected state for a fresh or short session) — this is fine, not a warning;
  - **warning** (cite reason) — L2 stuck in flight, stale L3 marker, orphan roots, or a
    handoff that is stale *after* a compaction;
  - **broken** (cite reason) — only an actual failure: a hook error, or a compaction
    occurred but capture wrote nothing.
