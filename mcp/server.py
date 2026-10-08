#!/usr/bin/env python3
"""agent-chain-doctor as an MCP server (stdio, stdlib only, read-only).

Exposes one tool, diagnose_scheduled_agent, which runs the agent-chain-doctor script
next to this folder and returns its report. Same guarantees as the script: it writes
nothing, sends nothing, needs no privilege. Run it on the machine whose chain you
want diagnosed — inside a container it can only see the container.
"""
import json
import os
import subprocess
import sys

VERSION = "1.0.0"
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("AGENT_CHAIN_DOCTOR",
                        os.path.join(os.path.dirname(HERE), "agent-chain-doctor"))

TOOL = {
    "name": "diagnose_scheduled_agent",
    "description": (
        "Diagnose why a scheduled AI agent (Claude Code routine, cron, launchd, systemd) "
        "stops or skips runs silently. Runs 30 read-only checks on this machine and returns "
        "EXPOSED / GUARDED / UNDECIDABLE per check with evidence. Exit 0 = nothing exposed "
        "(not 'your chain is fine'), 1 = something exposed, 2 = no diagnosis happened."),
    "inputSchema": {
        "type": "object",
        "properties": {
            "args": {
                "type": "array", "items": {"type": "string"},
                "description": "CLI arguments, e.g. [\"/path/to/session.sh\"], "
                               "[\"--plist\", \"FILE\"], [\"--verbose\"]. Empty = auto-discovery."}
        },
        "additionalProperties": False,
    },
    "annotations": {"readOnlyHint": True, "openWorldHint": False},
}


def run_doctor(args):
    if not all(isinstance(a, str) for a in args):
        return "args must be a list of strings", True
    try:
        p = subprocess.run(["bash", SCRIPT] + args, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return "could not run agent-chain-doctor: %s" % e, True
    text = (p.stdout + ("\n" + p.stderr if p.stderr else "")).strip()
    return "%s\n\n[exit code %d]" % (text, p.returncode), p.returncode == 2


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:  # notification: never answered
        return None
    if method == "initialize":
        proto = (msg.get("params") or {}).get("protocolVersion", "2025-06-18")
        result = {"protocolVersion": proto, "capabilities": {"tools": {}},
                  "serverInfo": {"name": "agent-chain-doctor", "version": VERSION}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": [TOOL]}
    elif method == "tools/call":
        params = msg.get("params") or {}
        if params.get("name") != TOOL["name"]:
            return {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32602, "message": "unknown tool"}}
        text, is_err = run_doctor((params.get("arguments") or {}).get("args", []))
        result = {"content": [{"type": "text", "text": text}], "isError": is_err}
    else:
        return {"jsonrpc": "2.0", "id": mid,
                "error": {"code": -32601, "message": "method not found: %s" % method}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            reply = handle(json.loads(line))
        except (ValueError, AttributeError):
            reply = {"jsonrpc": "2.0", "id": None,
                     "error": {"code": -32700, "message": "parse error"}}
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
