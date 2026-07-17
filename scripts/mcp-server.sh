#!/usr/bin/env bash
# MCP stdio launcher for amnesia. Resolves Python via run-python.sh so Claude's
# thin spawn PATH (missing Homebrew/pyenv) does not silently fail the server.
set -euo pipefail

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  ROOT="$CLAUDE_PLUGIN_ROOT"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

SERVER="${ROOT}/mcp/server.py"
RUNNER="${ROOT}/scripts/run-python.sh"

if [ ! -f "$SERVER" ]; then
  echo "amnesia: MCP server missing at $SERVER" >&2
  exit 1
fi
if [ ! -x "$RUNNER" ] && [ -f "$RUNNER" ]; then
  chmod +x "$RUNNER" 2>/dev/null || true
fi
if [ ! -f "$RUNNER" ]; then
  echo "amnesia: run-python.sh missing at $RUNNER" >&2
  exit 1
fi

exec bash "$RUNNER" "$SERVER" "$@"
