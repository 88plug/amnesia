# amnesia tests

## What's here

| File | What it tests |
|---|---|
| `smoke.sh` | Bash-level unit tests for `lib/common.sh` helpers, all hook syntax, JSON validity, and the redact-secrets regex. |
| `test-mcp-server.py` | Protocol-level smoke test: launches `server.py`, drives `initialize` → `tools/list` over JSON-RPC, asserts response shape. |
| `fixtures/sample-transcript.jsonl` | Synthetic Claude Code transcript (~50 lines) used by smoke tests. No real secrets or real project content. |

## How to run

**All tests:**

```bash
bash tests/smoke.sh
python3 tests/test-mcp-server.py
```

**Dependencies** (usually pre-installed on Linux):

```bash
apt-get install -y jq python3   # Debian/Ubuntu
```

No pip packages needed — the MCP server uses Python stdlib only.

## What the smoke test checks

1. `bash -n` syntax check on `lib/common.sh`.
2. `amnesia::log_jsonl`, `lock/unlock`, `git_state`, `rotate_jsonl` — called with synthetic input, output verified.
3. `amnesia::redact_secrets` — four secret patterns (Bearer token, `--token=`, `ghp_`, `AKIA`).
4. `bash -n` on every `.sh` hook in `hooks/`.
5. `ast.parse` syntax check on `mcp/server.py`.
6. `jq empty` validity check on every `.json` in `./`.
7. Fixture JSONL: every line parses as valid JSON.
