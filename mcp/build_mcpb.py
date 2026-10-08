#!/usr/bin/env python3
"""Build agent-chain-doctor-mcp.mcpb, the bundle the MCP registry and Claude Desktop install.

Reproducible on purpose: the registry pins the bundle by SHA-256 (server.json fileSha256), so
the same sources must give the same bytes on any machine. Hence fixed timestamps, fixed
permissions, sorted entries and no compression (zlib output varies between builds).
Usage: build_mcpb.py [OUTPUT]   (default: dist/agent-chain-doctor-mcp.mcpb). Prints the SHA-256.
"""
import hashlib
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = [  # (path in bundle, path in repo, unix mode)
    ("LICENSE", "LICENSE", 0o644),
    ("agent-chain-doctor", "agent-chain-doctor", 0o755),
    ("manifest.json", "mcp/manifest.json", 0o644),
    ("mcp/server.py", "mcp/server.py", 0o755),
]


def build(out):
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        for arc, src, mode in sorted(FILES):
            info = zipfile.ZipInfo(arc, date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = (0o100000 | mode) << 16
            info.create_system = 3
            with open(os.path.join(ROOT, src), "rb") as f:
                z.writestr(info, f.read())
    with open(out, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


if __name__ == "__main__":
    print(build(sys.argv[1] if len(sys.argv) > 1 else
                os.path.join(ROOT, "dist", "agent-chain-doctor-mcp.mcpb")))
