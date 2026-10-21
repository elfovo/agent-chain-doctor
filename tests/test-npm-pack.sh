#!/bin/bash
# The npm package must ship the script and its legal files, nothing else, and `npx` must run it.
# Seen red before package.json existed (S491, 2026-10-21).
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0; ok() { echo "ok   $1"; }; ko() { echo "FAIL $1"; fail=1; }
[ -f package.json ] && ok "package.json present" || { ko "package.json present"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tgz="$(npm pack --silent --pack-destination "$tmp" 2>/dev/null | tail -1)"
[ -s "$tmp/$tgz" ] && ok "npm pack builds $tgz" || { ko "npm pack builds"; exit 1; }
files="$(tar -tzf "$tmp/$tgz" | sed 's#^package/##' | sort | tr '\n' ' ')"
for f in agent-chain-doctor LICENSE NOTICE README.md package.json; do
  case " $files" in *" $f "*) ok "ships $f" ;; *) ko "ships $f" ;; esac
done
extra="$(printf '%s\n' $files | grep -vxE 'agent-chain-doctor|LICENSE|NOTICE|README.md|package.json' || true)"
[ -z "$extra" ] && ok "ships nothing else" || ko "ships nothing else: $extra"
pv="$(node -p "require('./package.json').version")"; sv="$(sed -n 's/^VERSION="\(.*\)"/\1/p' agent-chain-doctor)"
case "$pv" in "$sv".*|"$sv") ok "package version $pv matches script $sv" ;; *) ko "package version $pv vs script $sv" ;; esac
out="$(cd "$tmp" && npm exec --yes --package "./$tgz" -- agent-chain-doctor --version 2>&1)"
case "$out" in *"agent-chain-doctor $sv"*) ok "npx runs the bin: $out" ;; *) ko "npx runs the bin: $out" ;; esac
exit $fail
