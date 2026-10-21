#!/bin/bash
# test_pypi.sh — the PyPI wheel installs into a clean venv and gives two working commands:
#   agent-chain-doctor-mcp  (the MCP server over stdio, for `uvx agent-chain-doctor-mcp`)
#   agent-chain-doctor      (the CLI itself, the bundled script)
# Seen red before build.sh existed (S491, 2026-10-21).
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
# license = "MIT" (SPDX string) is refused by setuptools < 77; isolation hides it by fetching a newer one (QA S491).
grep -q '^license = "' "$here/pyproject.toml" && ! grep -qE '"setuptools>=(7[7-9]|[89][0-9])' "$here/pyproject.toml" \
  && { echo "FAIL pyproject: SPDX license needs setuptools>=77"; exit 1; }
[ -x "$here/build.sh" ] || { echo "FAIL build.sh missing"; exit 1; }
"$here/build.sh" "$tmp/dist" >/dev/null 2>&1 || { echo "FAIL build"; exit 1; }
whl=$(ls "$tmp"/dist/*.whl 2>/dev/null | head -1)
[ -n "$whl" ] || { echo "FAIL no wheel"; exit 1; }
python3 -m venv "$tmp/venv" && "$tmp/venv/bin/pip" install -q --no-deps "$whl" || { echo "FAIL install"; exit 1; }
sv=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$here/../../agent-chain-doctor")
out=$("$tmp/venv/bin/agent-chain-doctor" --version 2>&1)
[ "$out" = "agent-chain-doctor $sv" ] || { echo "FAIL cli: $out"; fail=1; }
out=$(printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"diagnose_scheduled_agent","arguments":{"args":["--version"]}}}' \
 | (cd "$tmp" && "$tmp/venv/bin/agent-chain-doctor-mcp" 2>/dev/null))
echo "$out" | grep -q '"id": 1.*"serverInfo"' || { echo "FAIL mcp initialize"; fail=1; }
echo "$out" | grep -q '"id": 2.*diagnose_scheduled_agent' || { echo "FAIL mcp tools/list"; fail=1; }
echo "$out" | grep -q "\"id\": 3.*agent-chain-doctor $sv" || { echo "FAIL mcp tools/call uses the bundled script"; fail=1; }
unzip -l "$whl" | grep -q 'agent_chain_doctor_mcp/NOTICE' || { echo "FAIL wheel ships NOTICE"; fail=1; }
# The MCP registry verifies a PyPI package by finding "mcp-name: <server.json name>" in its description.
name=$(python3 -c "import json;print(json.load(open('$here/../../server.json'))['name'])")
unzip -p "$whl" '*.dist-info/METADATA' | grep -q "mcp-name: $name" || { echo "FAIL METADATA lacks mcp-name: $name"; fail=1; }
[ $fail = 0 ] && echo "PASS pypi wheel ($(basename "$whl"))"; exit $fail
