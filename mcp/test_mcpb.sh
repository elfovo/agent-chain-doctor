#!/bin/bash
# test_mcpb.sh — the .mcpb bundle builds byte-for-byte reproducibly, its SHA-256 is the one
# server.json declares to the MCP registry, and the server runs from the unpacked bundle.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(dirname "$here")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
python3 "$here/build_mcpb.py" "$tmp/a.mcpb" >/dev/null 2>&1 || { echo "FAIL build"; exit 1; }
sleep 1; python3 "$here/build_mcpb.py" "$tmp/b.mcpb" >/dev/null 2>&1
cmp -s "$tmp/a.mcpb" "$tmp/b.mcpb" || { echo "FAIL: build not reproducible"; fail=1; }
sha=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/a.mcpb")
declared=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["packages"][0].get("fileSha256",""))' "$root/server.json")
[ "$sha" = "$declared" ] || { echo "FAIL: server.json fileSha256 $declared != built $sha"; fail=1; }
mkdir "$tmp/x" && (cd "$tmp/x" && python3 -m zipfile -e "$tmp/a.mcpb" .) || { echo "FAIL unzip"; exit 1; }
python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));assert m["server"]["entry_point"]=="mcp/server.py";assert m["version"]==json.load(open(sys.argv[2]))["version"]' \
  "$tmp/x/manifest.json" "$root/server.json" || { echo "FAIL manifest"; fail=1; }
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"diagnose_scheduled_agent","arguments":{"args":["--version"]}}}' \
  | python3 "$tmp/x/mcp/server.py" 2>/dev/null)
echo "$out" | grep -q '"id": 3.*agent-chain-doctor' || { echo "FAIL: server does not run from the bundle"; fail=1; }
[ $fail = 0 ] && echo "PASS mcpb bundle"; exit $fail
