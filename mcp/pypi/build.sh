#!/bin/bash
# build.sh OUT_DIR — stage the package from the repo's single sources, then build the wheel (no sdist).
set -eu
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
out=$(mkdir -p "${1:-$here/dist}" && cd "${1:-$here/dist}" && pwd)
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
pkg="$stage/agent_chain_doctor_mcp"; mkdir -p "$pkg"
cp "$here/pyproject.toml" "$here/README.md" "$stage/"
cp "$here/__init__.py.in" "$pkg/__init__.py"
cp "$root/mcp/server.py" "$root/agent-chain-doctor" "$root/NOTICE" "$root/LICENSE" "$pkg/"
cp "$root/LICENSE" "$stage/"
python3 -m pip wheel -q --no-deps -w "$out" "$stage"
