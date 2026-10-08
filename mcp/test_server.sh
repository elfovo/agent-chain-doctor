#!/bin/bash
# test_server.sh — the MCP server answers initialize, tools/list and tools/call over stdio.
set -u
here=$(cd "$(dirname "$0")" && pwd)
out=$(printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"diagnose_scheduled_agent","arguments":{"args":["--version"]}}}' \
 | python3 "$here/server.py" 2>/dev/null)
fail=0
echo "$out" | grep -q '"id": 1.*"serverInfo"' || { echo "FAIL initialize"; fail=1; }
echo "$out" | grep -q '"id": 2.*diagnose_scheduled_agent' || { echo "FAIL tools/list"; fail=1; }
echo "$out" | grep -q '"id": 3.*agent-chain-doctor' || { echo "FAIL tools/call"; fail=1; }
[ "$(echo "$out" | grep -c .)" = 3 ] || { echo "FAIL: notification must get no reply"; fail=1; }
[ $fail = 0 ] && echo "PASS mcp server"; exit $fail
