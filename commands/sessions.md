---
description: List or search across archived handoffs for this project (and optionally all projects).
allowed-tools: Bash(ls:*), Bash(find:*), Bash(grep:*), Bash(head:*), Bash(stat:*), Bash(date:*), Bash(printf:*), Bash(awk:*), Bash(source:*), Bash(dirname:*)
argument-hint: "[query] [--all-projects]"
---

# amnesia sessions

The user has invoked `/amnesia:sessions $ARGUMENTS`. List or search archived
handoffs to help recover past working context.

## Gather the data

`!`
# Prefer the harness-injected root, else find any installed amnesia plugin.
LIB="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh"
[ -f "$LIB" ] || LIB="$(ls -t "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh 2>/dev/null | head -1)"
[ -f "$LIB" ] && source "$LIB"

ARGS="${ARGUMENTS:-}"
ALL_PROJECTS=false
QUERY=""
for arg in $ARGS; do
  if [ "$arg" = "--all-projects" ]; then
    ALL_PROJECTS=true
  else
    QUERY="${QUERY:+$QUERY }$arg"
  fi
done

STATE="$(amnesia::state_dir 2>/dev/null || printf '%s' "$HOME/.claude/plugins/data/amnesia/projects/unknown")"

list_archives() {
  local proj_dir="$1"
  local archive="$proj_dir/handoff/archive"
  [ -d "$archive" ] || return 0

  find "$archive" -maxdepth 1 -name '*.md' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn \
    | while IFS=' ' read -r mtime fpath; do
        local fname mdate first_theory snippet
        fname="$(basename "$fpath")"
        mdate="$(date -u -d "@${mtime%.*}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
                 || date -u -r "${mtime%.*}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
                 || printf '%s' "$mtime")"
        first_theory="$(grep -m1 -A1 '## Working theory' "$fpath" 2>/dev/null | tail -1 | cut -c1-80 || true)"
        if [ -n "$QUERY" ]; then
          snippet="$(grep -i -m2 "$QUERY" "$fpath" 2>/dev/null | head -2 | tr '\n' ' ' | cut -c1-120 || true)"
          [ -n "$snippet" ] || continue
          printf '  file: %s\n  mtime: %s\n  theory: %s\n  match: %s\n\n' \
            "$fname" "$mdate" "${first_theory:-(none)}" "$snippet"
        else
          printf '  file: %s\n  mtime: %s\n  theory: %s\n\n' \
            "$fname" "$mdate" "${first_theory:-(none)}"
        fi
      done
}

if [ "$ALL_PROJECTS" = "true" ]; then
  echo "=== all projects across all data roots ==="
  while IFS= read -r root; do
    [ -d "$root/projects" ] || continue
    for proj_dir in "$root/projects"/*/; do
      [ -d "$proj_dir" ] || continue
      proj_name="$(basename "$proj_dir")"
      archive_count="$(find "$proj_dir/handoff/archive" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l || echo 0)"
      [ "$archive_count" -gt 0 ] || continue
      printf '\n--- project: %s (%s archives) ---\n' "$proj_name" "$archive_count"
      list_archives "$proj_dir"
    done
  done < <(amnesia::all_data_roots 2>/dev/null)
else
  echo "=== archived handoffs for this project ==="
  printf 'state dir: %s\n\n' "$STATE"
  ARCH_COUNT="$(find "$STATE/handoff/archive" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l || echo 0)"
  printf 'total archives: %s\n\n' "$ARCH_COUNT"
  if [ "$ARCH_COUNT" -eq 0 ]; then
    echo "(no archives yet — handoffs accumulate after each compaction)"
  else
    list_archives "$STATE"
  fi
fi

if [ -n "$QUERY" ]; then
  printf '\n(filtered by query: "%s")\n' "$QUERY"
fi
``

## Your output

Synthesize the list above into a useful summary:

- How many archives exist, spanning what date range?
- If a query was given, which archives matched and what does the snippet reveal?
- If `--all-projects` was given, note which projects have the most history.
- Highlight any archive that looks relevant to the user's current task.
- If no archives exist yet, explain that they accumulate after each auto-compaction.

User-provided arguments: $ARGUMENTS
