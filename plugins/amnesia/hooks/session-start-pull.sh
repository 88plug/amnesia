#!/usr/bin/env bash
# SessionStart hook — optional git-sync pull.
#
# If AMNESIA_SYNC_REMOTE is unset, exits silently (no-op). When set, pulls
# the amnesia data root from the configured remote so that state is consistent
# across machines. Failures are logged but never block session start.
#
# Designed to run before session-start-restore.sh so the pulled state is
# available for context injection.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
amnesia::read_input

# No remote configured → skip entirely.
if [ -z "${AMNESIA_SYNC_REMOTE:-}" ]; then
  exit 0
fi

REMOTE="$AMNESIA_SYNC_REMOTE"

# Resolve the data root: the directory that contains projects/.
STATE_DIR="$(amnesia::ensure_state)"
DATA_ROOT="$(dirname "$(dirname "$STATE_DIR")")"   # .../data/amnesia[-<id>]

if [ ! -d "$DATA_ROOT" ]; then
  amnesia::log_jsonl "SessionStartPull" "skipped" "reason=data_root_missing" "remote=$REMOTE"
  exit 0
fi

cd "$DATA_ROOT" || { amnesia::log_jsonl "SessionStartPull" "failed" "reason=cd_failed" "remote=$REMOTE"; exit 0; }

# Init git repo if not already one.
if ! git -C "$DATA_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git init "$DATA_ROOT" >/dev/null 2>&1 || {
    amnesia::log_jsonl "SessionStartPull" "failed" "reason=git_init_failed" "remote=$REMOTE"
    exit 0
  }
fi

# Set or update the origin remote idempotently.
if git -C "$DATA_ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$DATA_ROOT" remote set-url origin "$REMOTE" >/dev/null 2>&1 || true
else
  git -C "$DATA_ROOT" remote add origin "$REMOTE" >/dev/null 2>&1 || true
fi

# Pull with a 10-second timeout. Failure is non-fatal.
if timeout 10 git -C "$DATA_ROOT" pull --rebase origin main >/dev/null 2>&1; then
  amnesia::log_jsonl "SessionStartPull" "pulled" "remote=$REMOTE"
else
  amnesia::log_jsonl "SessionStartPull" "failed" "reason=pull_failed" "remote=$REMOTE"
fi

exit 0
