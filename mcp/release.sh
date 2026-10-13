#!/bin/bash
# release.sh — release a new version of the MCP server without breaking the registry pin.
#
# server.json pins the .mcpb bundle by SHA-256, so ANY change to agent-chain-doctor or
# mcp/server.py makes mcp/test_mcpb.sh red until the version is bumped and the pin recomputed.
#
#   mcp/release.sh prepare X.Y.Z   bump manifest.json + server.json, re-pin, run the bundle tests.
#                                  Offline, writes nothing if the version is refused.
#   (review, commit, push to main)
#   mcp/release.sh publish         from a clean tree whose HEAD is on origin/main: create the
#                                  vX.Y.Z-mcp release with the bundle, check the uploaded bytes,
#                                  then trigger publish-mcp.yml (OIDC). The registry refuses
#                                  republishing a version, so this is the irreversible step.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(dirname "$here")
asset=agent-chain-doctor-mcp.mcpb
die() { echo "release.sh: $*" >&2; exit 1; }
current=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$root/server.json") \
  || die "cannot read version from server.json"

case "${1:-}" in
prepare)
  new=${2:-}
  [[ $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got '$new')"
  python3 -c 'import sys;a,b=(tuple(map(int,v.split("."))) for v in sys.argv[1:]);sys.exit(0 if b>a else 1)' \
    "$current" "$new" || die "$new is not above the current $current"
  # The bundle contains manifest.json, so bump it first and build after.
  python3 - "$root" "$new" <<'EOF' || die "could not write the version"
import json, sys
root, new = sys.argv[1:]
m = f"{root}/mcp/manifest.json"; d = json.load(open(m)); d["version"] = new
open(m, "w").write(json.dumps(d, indent=2) + "\n")
EOF
  sha=$(python3 "$here/build_mcpb.py" "$root/dist/$asset") || die "bundle build failed"
  python3 - "$root" "$new" "$sha" "$asset" <<'EOF' || die "could not write server.json"
import json, sys
root, new, sha, asset = sys.argv[1:]
s = f"{root}/server.json"; d = json.load(open(s)); d["version"] = new
p = d["packages"][0]
p["identifier"] = f"https://github.com/elfovo/agent-chain-doctor/releases/download/v{new}-mcp/{asset}"
p["fileSha256"] = sha
open(s, "w").write(json.dumps(d, indent=2) + "\n")
EOF
  bash "$here/test_mcpb.sh" && bash "$here/test_server.sh" || die "bundle tests red after the bump"
  echo "prepared $current -> $new (bundle sha256 $sha)"
  echo "next: commit + push to main, then: mcp/release.sh publish"
  ;;
publish)
  cd "$root" || exit 1
  [ -z "$(git status --porcelain)" ] || die "uncommitted changes: commit and push the prepare first"
  bash "$here/test_mcpb.sh" >/dev/null || die "test_mcpb.sh is red: run prepare first"
  git fetch -q origin main || die "cannot fetch origin"
  head=$(git rev-parse HEAD)
  [ "$head" = "$(git rev-parse origin/main)" ] || die "HEAD is not origin/main: push first"
  tag="v$current-mcp"
  gh release view "$tag" >/dev/null 2>&1 && die "$tag already exists: bump with prepare"
  want=$(python3 "$here/build_mcpb.py" "$root/dist/$asset")
  # --target needs the full SHA (a short one is refused by the API).
  gh release create "$tag" "$root/dist/$asset" --target "$head" --title "MCP server $current" \
    --notes "MCP bundle for the official registry (io.github.elfovo/agent-chain-doctor-mcp $current). SHA-256 $want." \
    || die "release creation failed"
  got=$(curl -fsSL "https://github.com/elfovo/agent-chain-doctor/releases/download/$tag/$asset" | shasum -a 256 | cut -d' ' -f1)
  [ "$got" = "$want" ] || die "uploaded asset $got != built $want: fix the release before publishing"
  gh workflow run publish-mcp.yml --ref main || die "could not trigger publish-mcp.yml"
  echo "released $tag; registry publication running: gh run list --workflow publish-mcp.yml"
  ;;
*) die "usage: release.sh prepare X.Y.Z | release.sh publish" ;;
esac
