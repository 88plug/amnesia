---
description: Show what changed between the previous and current handoff (or between two specific versions).
allowed-tools: Bash(ls:*), Bash(find:*), Bash(diff:*), Bash(head:*), Bash(printf:*), Bash(stat:*), Bash(source:*), Bash(dirname:*), Bash(basename:*)
argument-hint: "[--from <pattern>] [--to <pattern>]"
---

# amnesia diff

The user has invoked `/amnesia:diff $ARGUMENTS`. Show what materially changed
between two handoff versions so it is easy to see what amnesia learned (or
lost) across a compaction boundary.

Default behavior (no args): diff the two most-recent archive files, or if
only one archive file exists, diff it against the current `active.md`.

## Gather and diff

`!`
# Prefer the harness-injected root, else find any installed amnesia plugin.
LIB="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh"
[ -f "$LIB" ] || LIB="$(ls -t "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh 2>/dev/null | head -1)"
[ -f "$LIB" ] && source "$LIB"

ARGS="${ARGUMENTS:-}"
FROM_PAT=""
TO_PAT=""

# Parse --from / --to
_next=""
for arg in $ARGS; do
  if [ "$_next" = "from" ]; then FROM_PAT="$arg"; _next=""; continue; fi
  if [ "$_next" = "to" ];   then TO_PAT="$arg";   _next=""; continue; fi
  [ "$arg" = "--from" ] && _next="from"
  [ "$arg" = "--to" ]   && _next="to"
done

STATE="$(amnesia::state_dir 2>/dev/null || printf '%s' "$HOME/.claude/plugins/data/amnesia/projects/unknown")"
ARCHIVE="$STATE/handoff/archive"
ACTIVE="$STATE/handoff/active.md"

# Collect sorted archive list (newest first)
mapfile -t ARCHIVES < <(find "$ARCHIVE" -maxdepth 1 -name '*.md' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')

resolve_file() {
  local pat="$1"
  local match
  # Try exact match first, then glob in archive
  if [ -f "$pat" ]; then printf '%s' "$pat"; return; fi
  match="$(printf '%s\n' "${ARCHIVES[@]+"${ARCHIVES[@]}"}" | grep -m1 "$pat" 2>/dev/null || true)"
  if [ -n "$match" ]; then printf '%s' "$match"; return; fi
  printf ''
}

if [ -n "$FROM_PAT" ]; then
  FILE_A="$(resolve_file "$FROM_PAT")"
else
  FILE_A="${ARCHIVES[1]:-}"   # second-newest archive
  [ -z "$FILE_A" ] && FILE_A="${ARCHIVES[0]:-}"  # fall back to newest
fi

if [ -n "$TO_PAT" ]; then
  FILE_B="$(resolve_file "$TO_PAT")"
else
  # Default: most-recent archive, or active.md if archive is the FROM
  if [ "${ARCHIVES[0]:-}" != "$FILE_A" ] && [ -n "${ARCHIVES[0]:-}" ]; then
    FILE_B="${ARCHIVES[0]}"
  elif [ -f "$ACTIVE" ]; then
    FILE_B="$ACTIVE"
  fi
fi

if [ -z "$FILE_A" ] || [ ! -f "$FILE_A" ]; then
  echo "ERROR: could not resolve --from file (archive may be empty)."
  printf 'archive dir: %s\n' "$ARCHIVE"
  printf 'archive files:\n'
  printf '%s\n' "${ARCHIVES[@]+"${ARCHIVES[@]}"}" | head -5
  exit 1
fi
if [ -z "$FILE_B" ] || [ ! -f "$FILE_B" ]; then
  echo "ERROR: could not resolve --to file."
  exit 1
fi

printf 'FROM: %s\n' "$FILE_A"
printf 'TO:   %s\n' "$FILE_B"
echo "---"
diff -u "$FILE_A" "$FILE_B" 2>/dev/null | head -200 || true
``

## Your output

Synthesize what materially changed between the two handoff versions:

- What sections were added, removed, or substantially rewritten?
- Did the "Working theory" change (new goal)?
- Were new decisions locked in, or old ones rescinded?
- Were blockers resolved or added?
- Did the "Concrete next action" change?

Keep synthesis to 5-8 bullet points. Flag any regression (information present
in the older handoff that is absent from the newer one).

User-provided arguments: $ARGUMENTS
