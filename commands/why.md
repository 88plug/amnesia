---
description: Trace a claim in the current handoff back to the JSONL transcript line that produced it.
allowed-tools: Bash(ls:*), Bash(grep:*), Bash(head:*), Bash(tail:*), Bash(printf:*), Bash(sed:*), Bash(jq:*), Bash(python3:*), Bash(find:*), Bash(source:*), Bash(dirname:*), Bash(awk:*), Read
argument-hint: "<claim text to trace>"
---

# amnesia why

The user has invoked `/amnesia:why $ARGUMENTS`. Trace the claim back to the
JSONL transcript line that originated it.

## Procedure

`!`
# Prefer the harness-injected root, else find any installed amnesia plugin.
LIB="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh"
[ -f "$LIB" ] || LIB="$(ls -t "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh 2>/dev/null | head -1)"
[ -f "$LIB" ] && source "$LIB"

CLAIM="${ARGUMENTS:-}"
if [ -z "$CLAIM" ]; then
  echo "ERROR: provide a claim to trace, e.g. /amnesia:why 'the migration is idempotent'"
  exit 1
fi

STATE="$(amnesia::state_dir 2>/dev/null || printf '%s' "$HOME/.claude/plugins/data/amnesia/projects/unknown")"
ACTIVE="$STATE/handoff/active.md"
SLUG="$(amnesia::slug 2>/dev/null || printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[^A-Za-z0-9]/-/g')"

# Find the most recent JSONL transcript
TRANSCRIPT="$(ls -t "$HOME/.claude/projects/$SLUG/"*.jsonl 2>/dev/null | head -1 || true)"

echo "=== claim ==="
printf '"%s"\n\n' "$CLAIM"

echo "=== step 1: grep active.md for claim ==="
if [ -f "$ACTIVE" ]; then
  MATCHES="$(grep -n "$CLAIM" "$ACTIVE" 2>/dev/null || true)"
  if [ -n "$MATCHES" ]; then
    printf 'Found in active.md:\n%s\n\n' "$MATCHES"

    # For each matched line, look for a nearby [L:N-M] citation within ±5 lines
    while IFS=: read -r lineno rest; do
      lineno="${lineno// /}"
      START=$((lineno - 5)); [ "$START" -lt 1 ] && START=1
      END=$((lineno + 5))
      CITATION="$(awk "NR>=$START && NR<=$END" "$ACTIVE" | grep -oE '\[L:[0-9]+-[0-9]+\]' | head -1 || true)"
      if [ -n "$CITATION" ]; then
        RANGE="${CITATION#\[L:}"; RANGE="${RANGE%\]}"
        L_START="${RANGE%-*}"; L_END="${RANGE#*-}"
        printf 'Citation near line %s: %s → transcript lines %s-%s\n' "$lineno" "$CITATION" "$L_START" "$L_END"
        echo "=== step 2: transcript lines $L_START-$L_END ==="
        if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
          awk "NR>=$L_START && NR<=$L_END" "$TRANSCRIPT" \
            | jq -r '(.role // .type // "?") + ": " + (
                (.content // .text // .message // "") | if type == "array" then map(.text // .content // "") | join(" ") else . end
              )' 2>/dev/null \
            || awk "NR>=$L_START && NR<=$L_END" "$TRANSCRIPT"
        else
          echo "(no transcript found at expected path)"
        fi
        echo
      fi
    done <<< "$MATCHES"
  else
    printf '(claim not found verbatim in active.md)\n\n'
  fi
else
  echo "(no active.md)"
fi

echo "=== step 3: fallback — grep JSONL transcript directly ==="
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  printf 'transcript: %s\n' "$TRANSCRIPT"
  JSONL_HITS="$(grep -n "$CLAIM" "$TRANSCRIPT" 2>/dev/null | head -5 || true)"
  if [ -n "$JSONL_HITS" ]; then
    printf 'Matching lines:\n'
    while IFS=: read -r lineno rest; do
      lineno="${lineno// /}"
      printf '\n--- line %s ---\n' "$lineno"
      awk "NR==$lineno" "$TRANSCRIPT" \
        | jq -r '(.role // .type // "?") + " [" + (.ts // .timestamp // "no-ts") + "]: " + (
            (.content // .text // .message // "") | if type == "array" then map(.text // .content // "") | join(" ") else . end
          )' 2>/dev/null \
        || awk "NR==$lineno" "$TRANSCRIPT" | head -c 500
    done <<< "$JSONL_HITS"
  else
    echo "(claim not found in transcript either)"
  fi
else
  echo "(no transcript found for slug: $SLUG)"
  printf 'Expected: %s/.claude/projects/%s/*.jsonl\n' "$HOME" "$SLUG"
fi
``

## Your output

Present the source clearly:

- If a `[L:N-M]` citation was found: quote the transcript lines and explain
  what they show (the user message that introduced the claim, the tool call
  that confirmed it, etc.).
- If no citation but a direct transcript match: quote the relevant JSON,
  extract the readable text, and cite the line number and timestamp.
- If nothing found: say so plainly and suggest the user try a shorter
  or more literal phrasing of the claim.

User-provided arguments: $ARGUMENTS
