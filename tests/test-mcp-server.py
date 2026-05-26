#!/usr/bin/env python3
"""
Smoke test for the amnesia MCP server.

Launches plugins/amnesia/mcp/server.py as a subprocess, sends a minimal
JSON-RPC sequence over stdin, and asserts the response shape.

Does NOT test recall/handoff_get behavior (that needs real state).
Tests only the protocol layer: initialize → tools/list.

Usage: python3 tests/test-mcp-server.py
Exit 0 on pass, 1 on any failure.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SERVER = REPO_ROOT / "plugins" / "amnesia" / "mcp" / "server.py"

PASS = 0
FAIL = 0


def ok(label):
    global PASS
    print(f"  [PASS] {label}")
    PASS += 1


def fail(label, detail=""):
    global FAIL
    msg = f"  [FAIL] {label}"
    if detail:
        msg += f" — {detail}"
    print(msg)
    FAIL += 1


def send(proc, msg):
    line = json.dumps(msg) + "\n"
    proc.stdin.write(line.encode())
    proc.stdin.flush()


def recv(proc):
    line = proc.stdout.readline()
    if not line:
        return None
    return json.loads(line.decode())


def main():
    print("\n=== MCP server protocol smoke test ===\n")

    if not SERVER.exists():
        fail("server.py exists", f"not found at {SERVER}")
        sys.exit(1)
    ok(f"server.py found at {SERVER.relative_to(REPO_ROOT)}")

    env = os.environ.copy()
    env["CLAUDE_PROJECT_DIR"] = "/tmp/amnesia-mcp-test"

    proc = subprocess.Popen(
        [sys.executable, str(SERVER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    try:
        # --- initialize ---
        send(proc, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "smoke-test", "version": "0.0.1"},
            },
        })
        resp = recv(proc)

        if resp is None:
            fail("initialize: got response")
            sys.exit(1)
        ok("initialize: got response")

        assert_key(resp, "result",                     "initialize: result key present")
        assert_key(resp.get("result", {}), "serverInfo", "initialize: serverInfo present")
        si = resp.get("result", {}).get("serverInfo", {})
        if si.get("name") == "amnesia":
            ok("initialize: serverInfo.name == 'amnesia'")
        else:
            fail("initialize: serverInfo.name", f"got {si.get('name')!r}")

        # --- notifications/initialized ---
        send(proc, {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        })

        # --- tools/list ---
        send(proc, {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {},
        })
        resp2 = recv(proc)

        if resp2 is None:
            fail("tools/list: got response")
            sys.exit(1)
        ok("tools/list: got response")

        assert_key(resp2, "result", "tools/list: result key present")
        tools = resp2.get("result", {}).get("tools", [])
        if isinstance(tools, list):
            ok(f"tools/list: tools is a list ({len(tools)} items)")
        else:
            fail("tools/list: tools is a list", f"got {type(tools)}")

        tool_names = {t.get("name") for t in tools if isinstance(t, dict)}
        if "recall" in tool_names:
            ok("tools/list: 'recall' tool present")
        else:
            fail("tools/list: 'recall' tool present", f"got {tool_names}")

        if "handoff_get" in tool_names:
            ok("tools/list: 'handoff_get' tool present")
        else:
            fail("tools/list: 'handoff_get' tool present", f"got {tool_names}")

        # Validate each tool has inputSchema
        for tool in tools:
            if isinstance(tool, dict) and "name" in tool:
                if "inputSchema" in tool:
                    ok(f"tool '{tool['name']}': inputSchema present")
                else:
                    fail(f"tool '{tool['name']}': inputSchema present")

    finally:
        proc.stdin.close()
        proc.wait(timeout=5)

    print(f"\n=== Results: {PASS} passed, {FAIL} failed ===")
    sys.exit(0 if FAIL == 0 else 1)


def assert_key(obj, key, label):
    if key in obj:
        ok(label)
    else:
        fail(label, f"key '{key}' missing from {list(obj.keys())}")


if __name__ == "__main__":
    main()
