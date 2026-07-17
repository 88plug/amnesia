#!/usr/bin/env python3
"""Shared transcript reader for amnesia hooks and commands.

The Claude Code session transcript at ~/.claude/projects/<slug>/<sessionId>.jsonl is
append-only and contains every message and tool call ever sent in the session,
including everything before each compaction event. Compactions add a
`compact_boundary` system line and a follow-up `isCompactSummary: true` user line;
nothing earlier is rewritten. This module is the canonical way amnesia reaches into
that file to recover detail the compacted model lost.

Compatible with Python 3.6+ (no PEP-604 unions, no PEP-563 future annotations).
"""

import argparse
import json
import os
import sys
from collections import deque
from typing import Dict, Iterator, List, Optional  # noqa: F401  # used in type comments


def iter_lines(path):
    # type: (str) -> Iterator[dict]
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                yield json.loads(raw)
            except json.JSONDecodeError:
                continue


def last_compact_boundary_offset(path):
    # type: (str) -> Optional[int]
    """Return line index (0-based) of the most recent compact_boundary, or None."""
    last = None
    for i, obj in enumerate(iter_lines(path)):
        if obj.get("type") == "system" and obj.get("subtype") == "compact_boundary":
            last = i
    return last


def messages_after(path, start_line=0):
    # type: (str, int) -> Iterator[dict]
    """Yield JSONL entries from start_line onward (0-based)."""
    for i, obj in enumerate(iter_lines(path)):
        if i >= start_line:
            yield obj


def extract_text(content):
    """Anthropic message content is str OR list of blocks; flatten to str."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                parts.append(block.get("text", ""))
            elif btype == "tool_use":
                name = block.get("name", "?")
                parts.append("[tool_use:{}]".format(name))
            elif btype == "tool_result":
                inner = block.get("content", "")
                parts.append(
                    extract_text(inner) if not isinstance(inner, str) else inner
                )
            elif btype == "thinking":
                continue
        return "\n".join(p for p in parts if p)
    return ""


def classify_content(content):
    """Decide what KIND of turn this is, since Anthropic packs tool_result envelopes
    as role='user'. Returns one of: prose, tool_result, mixed, empty."""
    if isinstance(content, str):
        return "prose" if content.strip() else "empty"
    if not isinstance(content, list):
        return "empty"
    has_prose = False
    has_tr = False
    for block in content:
        if not isinstance(block, dict):
            continue
        bt = block.get("type")
        if bt == "text" and block.get("text", "").strip():
            has_prose = True
        elif bt == "tool_result":
            has_tr = True
        elif bt == "tool_use":
            has_prose = True  # an assistant turn with a tool_use counts as content
    if has_prose and has_tr:
        return "mixed"
    if has_prose:
        return "prose"
    if has_tr:
        return "tool_result"
    return "empty"


def to_turn(obj):
    """Return a dict {role, kind, text, timestamp, uuid, promptId, tool_name, tool_input} or None."""
    t = obj.get("type")
    if t not in ("user", "assistant"):
        return None
    msg = obj.get("message") or {}
    role = msg.get("role") or t
    content = msg.get("content", "")
    text = extract_text(content)
    if obj.get("isCompactSummary"):
        return None
    kind = classify_content(content)
    tool_name = None
    tool_input = None
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool_name = block.get("name")
                tool_input = block.get("input")
                break
    return {
        "role": role,
        "kind": kind,
        "text": text,
        "timestamp": obj.get("timestamp", ""),
        "uuid": obj.get("uuid", ""),
        "promptId": obj.get("promptId"),
        "tool_name": tool_name,
        "tool_input": tool_input,
    }


def last_n_turns(path, n, role=None, after_line=0, kinds=None):
    # type: (str, int, Optional[str], int, Optional[set]) -> List[dict]
    """Return the most recent n turns matching the filters."""
    buf = deque(maxlen=n)  # type: deque
    for obj in messages_after(path, after_line):
        turn = to_turn(obj)
        if turn is None:
            continue
        if role and turn["role"] != role:
            continue
        if kinds is not None and turn["kind"] not in kinds:
            continue
        buf.append(turn)
    return list(buf)


def files_touched(path, after_line=0):
    # type: (str, int) -> Dict[str, dict]
    """Map of file path -> {ops: sorted list of tool names, last_ts}."""
    out = {}  # type: Dict[str, dict]
    for obj in messages_after(path, after_line):
        if obj.get("type") != "assistant":
            continue
        msg = obj.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        ts = obj.get("timestamp", "")
        for block in content:
            if not (isinstance(block, dict) and block.get("type") == "tool_use"):
                continue
            inp = block.get("input") or {}
            fp = inp.get("file_path") or inp.get("path")
            if not fp:
                continue
            entry = out.setdefault(fp, {"ops": set(), "last_ts": ""})
            entry["ops"].add(block.get("name", "?"))
            if ts > entry["last_ts"]:
                entry["last_ts"] = ts
    for v in out.values():
        v["ops"] = sorted(v["ops"])
    return out


def cmd_tail(args):
    """Print the last N turns after the most-recent compact boundary."""
    start = 0
    if args.after_compact:
        b = last_compact_boundary_offset(args.path)
        if b is not None:
            start = b + 1
    # Default behavior: when filtering --role user, only real prose — not the
    # tool_result envelopes that the API encodes as user messages.
    kinds = None
    if args.kinds:
        kinds = set(args.kinds.split(","))
    elif args.role == "user":
        kinds = {"prose"}
    turns = last_n_turns(
        args.path, args.n, role=args.role, after_line=start, kinds=kinds
    )
    out = [
        {
            "role": t["role"],
            "kind": t["kind"],
            "ts": t["timestamp"],
            "text": (t["text"] or "")[: args.max_chars],
            "tool_name": t["tool_name"],
        }
        for t in turns
    ]
    json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_files(args):
    start = 0
    if args.after_compact:
        b = last_compact_boundary_offset(args.path)
        if b is not None:
            start = b + 1
    out = files_touched(args.path, after_line=start)
    json.dump(out, sys.stdout, indent=2, ensure_ascii=False, default=str)
    sys.stdout.write("\n")


def cmd_summary(args):
    """The most recent compact summary text, if any."""
    summary = None
    for obj in iter_lines(args.path):
        if obj.get("isCompactSummary"):
            summary = extract_text(obj.get("message", {}).get("content", ""))
    if summary:
        sys.stdout.write(summary)
    sys.exit(0 if summary else 1)


def main():
    p = argparse.ArgumentParser(description="amnesia transcript walker")
    sub = p.add_subparsers(dest="cmd")

    pt = sub.add_parser("tail", help="last N turns")
    pt.add_argument("path")
    pt.add_argument("-n", type=int, default=10)
    pt.add_argument("--role", choices=["user", "assistant"], default=None)
    pt.add_argument("--max-chars", type=int, default=2000)
    pt.add_argument(
        "--after-compact",
        action="store_true",
        help="only turns after most recent compact_boundary",
    )
    pt.add_argument(
        "--kinds",
        help="comma-separated kinds to keep: prose,tool_result,mixed,empty "
        "(default: prose only when --role user, else all)",
    )
    pt.set_defaults(func=cmd_tail)

    pf = sub.add_parser("files", help="files touched (from tool_use inputs)")
    pf.add_argument("path")
    pf.add_argument("--after-compact", action="store_true")
    pf.set_defaults(func=cmd_files)

    ps = sub.add_parser("summary", help="most recent compact_summary text, if any")
    ps.add_argument("path")
    ps.set_defaults(func=cmd_summary)

    args = p.parse_args()
    if not getattr(args, "cmd", None):
        p.print_help()
        sys.exit(2)
    if not os.path.exists(args.path):
        print("transcript not found: {}".format(args.path), file=sys.stderr)
        sys.exit(2)
    args.func(args)


if __name__ == "__main__":
    main()
