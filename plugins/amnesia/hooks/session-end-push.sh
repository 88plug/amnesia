#!/usr/bin/env bash
# SessionEnd hook — optional git-sync push.
#
# If AMNESIA_SYNC_REMOTE is unset, exits silently (no-op). When set, commits
# any changes to the amnesia data root and pushes to the configured remote so
# that state is preserved across machines.
#
# Safety rules:
#   - Runs AFTER session-end-archive.sh (ordering in hooks.json).
#   - On any failure: log and exit 0. NEVER block or break session end.
#   - Timeout: 10s per git operation.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

# No remote configured → skip entirely.
if [ -z "${AMNESIA_SYNC_REMOTE:-}" ]; then
  exit 0
fi

REMOTE="$AMNESIA_SYNC_REMOTE"

SID="$(amnesia::field session_id)"
[ -n "$SID" ] || SID="session-$(date -u +%Y%m%dT%H%M%SZ)-$$"

# Resolve the data root: the directory that contains projects/.
STATE_DIR="$(amnesia::ensure_state)"
DATA_ROOT="$(dirname "$(dirname "$STATE_DIR")")"   # .../data/amnesia[-<id>]

if [ ! -d "$DATA_ROOT" ]; then
  amnesia::log_jsonl "SessionEndPush" "failed" "reason=data_root_missing" "remote=$REMOTE"
  exit 0
fi

cd "$DATA_ROOT" || { amnesia::log_jsonl "SessionEndPush" "failed" "reason=cd_failed" "remote=$REMOTE"; exit 0; }

# Must be a git repo (session-start-pull.sh inits it; if the user never ran
# a pull, we init here too).
if ! git -C "$DATA_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  amnesia::log_jsonl "SessionEndPush" "skipped" "reason=not_a_git_repo" "remote=$REMOTE"
  exit 0
fi

# Check if there is anything to commit.
CHANGED="$(git -C "$DATA_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
if [ "${CHANGED:-0}" -eq 0 ]; then
  amnesia::log_jsonl "SessionEndPush" "nothing" "remote=$REMOTE"
  exit 0
fi

# Stage all changes. Timeout 10s each.
if ! timeout 10 git -C "$DATA_ROOT" add -A >/dev/null 2>&1; then
  amnesia::log_jsonl "SessionEndPush" "failed" "reason=add_failed" "remote=$REMOTE"
  exit 0
fi

if ! timeout 10 git -C "$DATA_ROOT" commit -m "amnesia: $SID snapshot" >/dev/null 2>&1; then
  amnesia::log_jsonl "SessionEndPush" "failed" "reason=commit_failed" "remote=$REMOTE"
  exit 0
fi

if ! timeout 10 git -C "$DATA_ROOT" push origin main >/dev/null 2>&1; then
  amnesia::log_jsonl "SessionEndPush" "failed" "reason=push_failed" "remote=$REMOTE"
  exit 0
fi

amnesia::log_jsonl "SessionEndPush" "pushed" "remote=$REMOTE"
exit 0
