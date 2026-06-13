#!/usr/bin/env python3
"""
amnesia MCP server — read-only access to amnesia handoffs and working-state archives.

Hand-rolled stdio JSON-RPC (no external deps). Handles:
  initialize, notifications/initialized, tools/list, tools/call

Tools:
  recall        — search handoffs/archives for a past detail
  handoff_get   — fetch the full markdown of a saved handoff
"""

import gzip
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "amnesia"
SERVER_VERSION = "0.3.2"

MAX_SNIPPET_CHARS = 4096
MAX_RECALL_RESPONSE_CHARS = 32768
MAX_HANDOFF_CHARS = 65536
SNIPPET_CONTEXT_CHARS = 500


# ---------------------------------------------------------------------------
# Path resolution helpers
# ---------------------------------------------------------------------------

def _data_roots() -> List[Path]:
    """Return all amnesia plugin data roots that exist."""
    base = Path.home() / ".claude" / "plugins" / "data"
    if not base.exists():
        return []
    # Match amnesia* directories (handles amnesia, amnesia@0.3.0, etc.)
    return [d for d in base.iterdir() if d.is_dir() and d.name.startswith("amnesia")]


def _project_slug(project_dir: Optional[str] = None) -> str:
    """Derive slug from CLAUDE_PROJECT_DIR (non-alphanumeric → '-')."""
    path = project_dir or os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not path:
        return ""
    return re.sub(r"[^a-zA-Z0-9]", "-", path).strip("-")


def _project_dirs(scope: str, project: Optional[str] = None) -> List[Path]:
    """Yield project state directories matching scope."""
    slug = project or _project_slug()
    roots = _data_roots()
    dirs = []
    for root in roots:
        projects_root = root / "projects"
        if not projects_root.exists():
            continue
        if scope == "current_project" and slug:
            candidate = projects_root / slug
            if candidate.exists():
                dirs.append(candidate)
        else:
            # all_projects — walk every child
            for child in projects_root.iterdir():
                if child.is_dir():
                    dirs.append(child)
    return dirs


# ---------------------------------------------------------------------------
# Search / grep helpers
# ---------------------------------------------------------------------------

def _snippet(text: str, query: str, context: int = SNIPPET_CONTEXT_CHARS) -> str:
    """Return a context window around the first case-insensitive match."""
    idx = text.lower().find(query.lower())
    if idx == -1:
        return text[:context]
    start = max(0, idx - context // 2)
    end = min(len(text), idx + context // 2)
    return text[start:end]


def _grep_text(
    content: str,
    query: str,
    path: Path,
    project_slug: str,
    mtime: float,
) -> List[Dict[str, Any]]:
    """Grep lines of text content; return match records."""
    results = []
    q_lower = query.lower()
    for lineno, line in enumerate(content.splitlines(), 1):
        if q_lower in line.lower():
            # Build a snippet: the line itself, capped
            snip = line[:MAX_SNIPPET_CHARS]
            results.append({
                "path": str(path),
                "line_number": lineno,
                "snippet": snip,
                "project_slug": project_slug,
                "mtime": mtime,
            })
    return results


def _read_file(path: Path) -> Optional[str]:
    """Read a plain text file; return None on error."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception as exc:
        print(f"[amnesia-mcp] cannot read {path}: {exc}", file=sys.stderr)
        return None


def _read_gz(path: Path) -> Optional[str]:
    """Decompress and read a .gz file; return None on error."""
    try:
        with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception as exc:
        print(f"[amnesia-mcp] cannot decompress {path}: {exc}", file=sys.stderr)
        return None


def _mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except Exception:
        return 0.0


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def tool_recall(
    query: str,
    max_results: int = 10,
    scope: str = "current_project",
    project: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Search amnesia's handoffs and archived working-state for a past detail.
    """
    if not query:
        return {"error": "query is required", "results": []}

    project_dirs = _project_dirs(scope, project)
    if not project_dirs:
        return {"results": [], "searched": [], "note": "No amnesia data directories found."}

    all_hits: List[Dict[str, Any]] = []
    searched: List[str] = []

    for proj_dir in project_dirs:
        slug = proj_dir.name

        # 1. handoff/active.md
        active_md = proj_dir / "handoff" / "active.md"
        if active_md.exists():
            searched.append(str(active_md))
            content = _read_file(active_md)
            if content:
                hits = _grep_text(content, query, active_md, slug, _mtime(active_md))
                all_hits.extend(hits)

        # 2. handoff/archive/*.md
        archive_dir = proj_dir / "handoff" / "archive"
        if archive_dir.exists():
            for md_file in sorted(archive_dir.glob("*.md"), key=_mtime, reverse=True):
                searched.append(str(md_file))
                content = _read_file(md_file)
                if content:
                    hits = _grep_text(content, query, md_file, slug, _mtime(md_file))
                    all_hits.extend(hits)

        # 3. logs/archive/*.jsonl.gz
        logs_dir = proj_dir / "logs" / "archive"
        if logs_dir.exists():
            for gz_file in sorted(logs_dir.glob("*.jsonl.gz"), key=_mtime, reverse=True):
                searched.append(str(gz_file))
                content = _read_gz(gz_file)
                if content:
                    hits = _grep_text(content, query, gz_file, slug, _mtime(gz_file))
                    all_hits.extend(hits)

        # 4. sessions.json
        sessions_json = proj_dir / "sessions.json"
        if sessions_json.exists():
            searched.append(str(sessions_json))
            content = _read_file(sessions_json)
            if content:
                hits = _grep_text(content, query, sessions_json, slug, _mtime(sessions_json))
                all_hits.extend(hits)

    # Sort by recency descending, cap
    all_hits.sort(key=lambda h: h["mtime"], reverse=True)
    all_hits = all_hits[:max_results]

    # Enforce total response size
    total_chars = 0
    trimmed = []
    for hit in all_hits:
        snip = hit["snippet"]
        remaining = MAX_RECALL_RESPONSE_CHARS - total_chars
        if remaining <= 0:
            break
        if len(snip) > remaining:
            snip = snip[:remaining]
        trimmed.append({**hit, "snippet": snip})
        total_chars += len(snip)

    return {
        "results": trimmed,
        "total_hits": len(all_hits),
        "searched_files": len(searched),
    }


def tool_handoff_get(
    session_id: Optional[str] = None,
    project: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Fetch the full markdown of a saved handoff.
    """
    slug = project or _project_slug()
    project_dirs = _project_dirs("current_project" if slug else "all_projects", project)

    if not project_dirs:
        return {"error": "No amnesia data directories found.", "content": None}

    proj_dir = project_dirs[0]
    resolved_slug = proj_dir.name

    if session_id:
        # Search archive for a filename matching session_id (short prefix match)
        archive_dir = proj_dir / "handoff" / "archive"
        if archive_dir.exists():
            sid_short = session_id[:8]
            candidates = list(archive_dir.glob(f"*{sid_short}*.md"))
            if not candidates:
                # Try sessions.json lookup
                sessions_json = proj_dir / "sessions.json"
                if sessions_json.exists():
                    raw = _read_file(sessions_json)
                    if raw:
                        try:
                            sessions = json.loads(raw)
                            for entry in sessions if isinstance(sessions, list) else []:
                                if isinstance(entry, dict) and session_id in str(entry.get("session_id", "")):
                                    fname = entry.get("handoff_file", "")
                                    if fname:
                                        candidate = archive_dir / Path(fname).name
                                        if candidate.exists():
                                            candidates.append(candidate)
                        except json.JSONDecodeError:
                            pass
            if candidates:
                # Use most recent match
                target = sorted(candidates, key=_mtime, reverse=True)[0]
                content = _read_file(target)
                if content:
                    if len(content) > MAX_HANDOFF_CHARS:
                        content = content[:MAX_HANDOFF_CHARS] + "\n\n[truncated at 64KB]"
                    return {
                        "path": str(target),
                        "content": content,
                        "mtime": _mtime(target),
                        "project_slug": resolved_slug,
                    }
            return {
                "error": f"No handoff found for session_id={session_id!r}",
                "content": None,
            }
    else:
        # Return active handoff
        active_md = proj_dir / "handoff" / "active.md"
        if active_md.exists():
            content = _read_file(active_md)
            if content:
                if len(content) > MAX_HANDOFF_CHARS:
                    content = content[:MAX_HANDOFF_CHARS] + "\n\n[truncated at 64KB]"
                return {
                    "path": str(active_md),
                    "content": content,
                    "mtime": _mtime(active_md),
                    "project_slug": resolved_slug,
                }
        return {
            "error": "No active handoff found.",
            "content": None,
            "project_slug": resolved_slug,
        }


# ---------------------------------------------------------------------------
# MCP JSON-RPC protocol layer
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "name": "recall",
        "description": (
            "Search amnesia's stored handoffs and archived working-state for a specific past detail "
            "(file you read earlier, exact error message, decision made). Use when the user references "
            "prior work you don't have in context, OR when the current handoff doesn't cover something "
            "specific you need."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search term or phrase to look for (case-insensitive substring match).",
                },
                "max_results": {
                    "type": "integer",
                    "description": "Maximum number of results to return (default 10).",
                    "default": 10,
                },
                "scope": {
                    "type": "string",
                    "enum": ["current_project", "all_projects"],
                    "description": "Whether to search only the current project or all projects (default current_project).",
                    "default": "current_project",
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "handoff_get",
        "description": (
            "Fetch the full markdown of a saved handoff by session_id (or the current handoff if none given). "
            "Use when you need the FULL context (not just a search snippet) for a prior session."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "Session ID (or short prefix) to look up a specific archived handoff. Omit to get the current active handoff.",
                },
                "project": {
                    "type": "string",
                    "description": "Project slug override. Defaults to the current CLAUDE_PROJECT_DIR.",
                },
            },
        },
    },
]


def _make_result(content: Any) -> Dict[str, Any]:
    text = json.dumps(content, indent=2, default=str)
    return {
        "content": [{"type": "text", "text": text}],
        "isError": False,
    }


def _make_error(message: str) -> Dict[str, Any]:
    return {
        "content": [{"type": "text", "text": message}],
        "isError": True,
    }


def _dispatch_tool(name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
    if name == "recall":
        result = tool_recall(
            query=arguments.get("query", ""),
            max_results=int(arguments.get("max_results", 10)),
            scope=arguments.get("scope", "current_project"),
            project=arguments.get("project"),
        )
        return _make_result(result)
    elif name == "handoff_get":
        result = tool_handoff_get(
            session_id=arguments.get("session_id"),
            project=arguments.get("project"),
        )
        return _make_result(result)
    else:
        return _make_error(f"Unknown tool: {name!r}")


def _send(obj: Dict[str, Any]) -> None:
    line = json.dumps(obj, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _send_response(req_id: Any, result: Any) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "result": result})


def _send_error(req_id: Any, code: int, message: str) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def _handle(msg: Dict[str, Any]) -> None:
    method = msg.get("method", "")
    req_id = msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        _send_response(req_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })

    elif method == "notifications/initialized":
        # No response required for notifications
        pass

    elif method == "tools/list":
        _send_response(req_id, {"tools": TOOLS})

    elif method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments") or {}
        tool_result = _dispatch_tool(tool_name, arguments)
        _send_response(req_id, tool_result)

    elif method == "ping":
        _send_response(req_id, {})

    elif req_id is not None:
        # Unknown method with an id — send method-not-found
        _send_error(req_id, -32601, f"Method not found: {method!r}")
    # Unknown notifications (no id) are silently ignored per JSON-RPC spec


def main() -> None:
    print(f"[amnesia-mcp] started (pid={os.getpid()})", file=sys.stderr)
    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            msg = json.loads(raw_line)
        except json.JSONDecodeError as exc:
            _send_error(None, -32700, f"Parse error: {exc}")
            continue
        try:
            _handle(msg)
        except Exception as exc:
            req_id = msg.get("id")
            print(f"[amnesia-mcp] unhandled error: {exc}", file=sys.stderr)
            if req_id is not None:
                _send_error(req_id, -32603, f"Internal error: {exc}")


if __name__ == "__main__":
    main()
