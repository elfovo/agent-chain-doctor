#!/bin/bash
# test_release.sh — mcp/release.sh prepare bumps both version fields, re-pins the bundle and
# leaves mcp/test_mcpb.sh green; it refuses bad, equal or lower versions without touching a file;
# publish refuses a dirty tree before any network call. Runs on a throwaway copy, offline.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(dirname "$here")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
copy() {  # fresh git copy of the files release.sh and the bundle tests need
  rm -rf "$tmp/r"; mkdir -p "$tmp/r/mcp"
  cp "$root/LICENSE" "$root/agent-chain-doctor" "$root/server.json" "$tmp/r/"
  cp "$here"/*.py "$here"/*.sh "$here/manifest.json" "$tmp/r/mcp/"
  (cd "$tmp/r" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init)
}
ver() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$1"; }
[ -x "$here/release.sh" ] || { echo "FAIL: mcp/release.sh missing or not executable"; exit 1; }

copy
# Start the copy from a fixed 1.0.0, so the bumps below do not depend on the released version
# (the 1.4.0 release turned this test red in publish-mcp.yml: "1.0.1 is not above 1.4.0").
python3 - "$tmp/r" <<'EOF'
import json,sys
for p in ("server.json","mcp/manifest.json"):
    f=f"{sys.argv[1]}/{p}"; d=json.load(open(f)); d["version"]="1.0.0"; json.dump(d,open(f,"w"),indent=2)
EOF
# The case this exists for: the diagnostic changed, the pin is now stale, the bundle test is red.
echo '# touched' >> "$tmp/r/agent-chain-doctor"
bash "$tmp/r/mcp/test_mcpb.sh" >/dev/null 2>&1 && { echo "FAIL: setup, a modified script should break the pin"; fail=1; }
bash "$tmp/r/mcp/release.sh" prepare 1.0.1 >"$tmp/out" 2>&1 || { echo "FAIL: prepare 1.0.1 exited non-zero"; cat "$tmp/out"; fail=1; }
[ "$(ver "$tmp/r/server.json")" = 1.0.1 ] || { echo "FAIL: server.json version not 1.0.1"; fail=1; }
[ "$(ver "$tmp/r/mcp/manifest.json")" = 1.0.1 ] || { echo "FAIL: manifest.json version not 1.0.1"; fail=1; }
grep -q '/releases/download/v1.0.1-mcp/agent-chain-doctor-mcp.mcpb"' "$tmp/r/server.json" \
  || { echo "FAIL: identifier does not point at the v1.0.1-mcp release"; fail=1; }
bash "$tmp/r/mcp/test_mcpb.sh" >/dev/null 2>&1 || { echo "FAIL: test_mcpb.sh still red after prepare"; fail=1; }
grep -q 'release.sh publish' "$tmp/out" || { echo "FAIL: prepare does not name the next step"; fail=1; }

# Refusals: nothing may be written.
for bad in 1.0.1 1.0.0 0.9.9 1.0 v1.0.2 1.0.2-rc1 ""; do
  before=$(cat "$tmp/r/server.json" "$tmp/r/mcp/manifest.json" | shasum)
  bash "$tmp/r/mcp/release.sh" prepare $bad >/dev/null 2>&1 && { echo "FAIL: prepare '$bad' accepted"; fail=1; }
  [ "$before" = "$(cat "$tmp/r/server.json" "$tmp/r/mcp/manifest.json" | shasum)" ] \
    || { echo "FAIL: prepare '$bad' modified files"; fail=1; }
done
# 1.0.10 > 1.0.9 numerically, not as text.
python3 - "$tmp/r" <<'EOF'
import json,sys
for p in ("server.json","mcp/manifest.json"):
    f=f"{sys.argv[1]}/{p}"; d=json.load(open(f)); d["version"]="1.0.9"; json.dump(d,open(f,"w"),indent=2)
EOF
bash "$tmp/r/mcp/release.sh" prepare 1.0.10 >/dev/null 2>&1 || { echo "FAIL: 1.0.10 refused after 1.0.9"; fail=1; }

# publish on a dirty tree stops before gh is ever called.
out=$(cd "$tmp/r" && PATH="$tmp/nogh:$PATH" bash mcp/release.sh publish 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qi 'commit' || { echo "FAIL: publish accepted a dirty tree (rc $rc)"; fail=1; }
bash "$tmp/r/mcp/release.sh" bogus >/dev/null 2>&1 && { echo "FAIL: unknown command accepted"; fail=1; }

[ $fail = 0 ] && echo "PASS release procedure"; exit $fail
