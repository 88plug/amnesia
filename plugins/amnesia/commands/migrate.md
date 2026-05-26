---
description: Consolidate amnesia state from orphaned data roots into the active one.
allowed-tools: Bash(ls:*), Bash(find:*), Bash(mv:*), Bash(rmdir:*), Bash(wc:*), Bash(printf:*), Bash(stat:*), Bash(mkdir:*), Bash(source:*), Bash(dirname:*), Bash(basename:*)
argument-hint: "[--dry-run | --execute]"
---

# amnesia migrate

The user has invoked `/amnesia:migrate $ARGUMENTS`. Consolidate amnesia state
from orphaned data roots (left over from reinstalls or marketplace switches)
into the single active root.

Default is `--dry-run`. Pass `--execute` to actually move files.

## Gather and migrate

`!`
# Prefer the harness-injected root, else find any installed amnesia plugin.
LIB="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/common.sh"
[ -f "$LIB" ] || LIB="$(ls -t "$HOME"/.claude/plugins/cache/*/amnesia/*/hooks/lib/common.sh 2>/dev/null | head -1)"
[ -f "$LIB" ] && source "$LIB"

ARGS="${ARGUMENTS:-}"
EXECUTE=false
for arg in $ARGS; do
  [ "$arg" = "--execute" ] && EXECUTE=true
done

STATE="$(amnesia::state_dir 2>/dev/null || printf '%s' "$HOME/.claude/plugins/data/amnesia/projects/unknown")"
ACTIVE_ROOT="$(dirname "$(dirname "$STATE")")"

echo "=== amnesia migrate ==="
printf 'active root: %s\n\n' "$ACTIVE_ROOT"

if [ "$EXECUTE" = "true" ]; then
  printf '!!! WARNING: This will move files. Ctrl-C to abort — but this is a slash command\n'
  printf '!!! so Ctrl-C only works before the bash block finishes. Proceeding in 0s...\n\n'
fi

ORPHAN_COUNT=0
MOVE_COUNT=0
SKIP_COUNT=0

while IFS= read -r root; do
  [ "$root" = "$ACTIVE_ROOT" ] && continue
  [ -d "$root/projects" ] || continue

  for src_proj in "$root/projects"/*/; do
    [ -d "$src_proj" ] || continue
    slug="$(basename "$src_proj")"

    ws_lines="$(wc -l < "$src_proj/working-state.jsonl" 2>/dev/null || echo 0)"
    arch_count="$(find "$src_proj/handoff/archive" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l || echo 0)"

    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    printf 'orphan: %s/projects/%s\n' "$root" "$slug"
    printf '  working-state lines: %s  archive files: %s\n' "$ws_lines" "$arch_count"

    dest="$ACTIVE_ROOT/projects/$slug"
    if [ -d "$dest" ]; then
      printf '  SKIP — conflict: %s already exists in active root\n' "$slug"
      SKIP_COUNT=$((SKIP_COUNT + 1))
    else
      printf '  PLAN: mv %s %s\n' "$src_proj" "$dest"
      if [ "$EXECUTE" = "true" ]; then
        mkdir -p "$ACTIVE_ROOT/projects"
        if mv "$src_proj" "$dest" 2>/dev/null; then
          printf '  DONE: moved.\n'
          MOVE_COUNT=$((MOVE_COUNT + 1))
          # Remove orphan root if now empty
          if [ -d "$root/projects" ] && [ -z "$(ls -A "$root/projects" 2>/dev/null)" ]; then
            rmdir "$root/projects" 2>/dev/null && printf '  RMDIR: %s/projects (now empty)\n' "$root"
            rmdir "$root" 2>/dev/null && printf '  RMDIR: %s (now empty)\n' "$root"
          fi
        else
          printf '  ERROR: mv failed.\n'
          SKIP_COUNT=$((SKIP_COUNT + 1))
        fi
      fi
    fi
    echo
  done
done < <(amnesia::all_data_roots 2>/dev/null)

echo "=== summary ==="
printf 'orphan project dirs found: %s\n' "$ORPHAN_COUNT"
if [ "$EXECUTE" = "true" ]; then
  printf 'moved: %s  skipped (conflict): %s\n' "$MOVE_COUNT" "$SKIP_COUNT"
else
  printf 'dry-run — pass --execute to apply the planned moves.\n'
fi
``

## Your output

Summarize the planned or completed migration:

- How many orphan projects were found and in which roots?
- Were any conflicts detected (slug already exists in active root)?
- If `--dry-run`: tell the user to re-run with `--execute` to apply.
- If `--execute`: confirm what was moved and whether any orphan roots were cleaned up.
- If no orphans: tell the user amnesia has a single clean data root.

User-provided arguments: $ARGUMENTS
