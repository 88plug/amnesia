# amnesia MCP server

A read-only stdio MCP server that gives Claude Code direct search and retrieval
access to amnesia's handoff files and archived working-state logs.

**No external dependencies** — pure Python 3 stdlib, no `pip install` needed.

---

## Tools

### `recall`

Search amnesia's handoffs and archived JSONL working-state for a specific past
detail — a file path you examined, an exact error message, a decision you made.

| Arg | Type | Default | Description |
|---|---|---|---|
| `query` | string | required | Case-insensitive substring to search for |
| `max_results` | int | 10 | Maximum results returned |
| `scope` | enum | `current_project` | `current_project` or `all_projects` |

Returns: list of `{path, line_number, snippet, project_slug, mtime}` ordered by recency.
Total response capped at 32 KB; each snippet capped at 4 KB.

### `handoff_get`

Fetch the full markdown of a saved handoff. Returns the current active handoff
by default, or a specific archived one by session_id.

| Arg | Type | Default | Description |
|---|---|---|---|
| `session_id` | string | optional | Session ID or short prefix; omit for active handoff |
| `project` | string | optional | Project slug override; defaults to `CLAUDE_PROJECT_DIR` |

Returns: `{path, content, mtime, project_slug}` — full markdown, capped at 64 KB.

---

## Installation

No install step required. The server uses only Python 3 standard library modules
(`json`, `gzip`, `os`, `re`, `sys`, `pathlib`).

Python 3.6+ is required (already a dependency of Claude Code hooks).

---

## Verifying the server is loaded

After installing the amnesia plugin, start Claude Code and run:

```
/mcp
```

You should see `amnesia` listed with 2 tools (`recall`, `handoff_get`).

---

## Example tool calls

**Search for a specific error across the current project:**
```
Use the recall tool with query="ECONNREFUSED" to find when that error appeared.
```

**Search for a decision across all projects:**
```
Use recall with query="decided to use postgres" and scope="all_projects"
```

**Get the current handoff:**
```
Use handoff_get to fetch the current project's handoff.
```

**Get a specific past session:**
```
Use handoff_get with session_id="a3f8b2c1" to retrieve that archived handoff.
```

---

## Notes

- **Read-only**: the server never writes, modifies, or deletes any amnesia state.
- All output goes to stdout as JSON-RPC; all logging goes to stderr.
- The server resolves state from `~/.claude/plugins/data/amnesia*/projects/`.
- `CLAUDE_PROJECT_DIR` is set automatically by Claude Code in the server's environment.
