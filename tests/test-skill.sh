#!/bin/bash
# test-skill.sh — skill/SKILL.md must install exactly the script this repository ships.
#
# Why: the skill does not bundle the 3,500-line script, it installs it as a pinned prerequisite
# (review of majiayu000/claude-skill-registry-core#364). A pin is only honest while it points at
# the script on main: when the script changes and the pin does not, the skill installs an old
# version and its checksum line still "verifies". This test fails the day that happens.
#
# Usage: bash tests/test-skill.sh   (from the repository root; needs git and shasum or sha256sum)
set -u
cd "$(dirname "$0")/.." || exit 2
S=skill/SKILL.md
fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
ko()  { printf 'FAIL  %s\n' "$1"; fail=1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

rev=$(grep -oE 'raw\.githubusercontent\.com/elfovo/agent-chain-doctor/[0-9a-f]{40}/agent-chain-doctor' "$S" | head -1 | cut -d/ -f4)
[ -n "$rev" ] && ok "SKILL.md pins a full commit ($rev)" || ko "SKILL.md downloads the script from a full 40-hex commit, not a branch"
grep -qE 'raw\.githubusercontent\.com/elfovo/agent-chain-doctor/main/' "$S" && ko "SKILL.md still downloads from main (moving target)" || ok "no download from main"

want=$(grep -oE '[0-9a-f]{64}' "$S" | head -1)
[ -n "$want" ] && ok "SKILL.md states a SHA-256" || ko "SKILL.md states the SHA-256 to check"

if [ -n "$rev" ] && [ -n "$want" ]; then
  pinned=$(git show "$rev:agent-chain-doctor" 2>/dev/null | sha) || pinned=
  [ "$pinned" = "$want" ] && ok "stated SHA-256 matches the pinned revision" || ko "stated SHA-256 ($want) != script at $rev (${pinned:-revision not found})"
  head=$(sha < agent-chain-doctor)
  [ "$head" = "$want" ] && ok "pinned script is the script in this tree" || ko "the script changed since $rev: bump the pin and the SHA-256 in $S"
fi

grep -qi 'hosted' "$S" && grep -qi 'Routines' "$S" && ok "scope limit (hosted schedulers) is in SKILL.md" || ko "SKILL.md says it cannot inspect hosted schedulers (Routines, Desktop tasks)"
grep -qiE 'after setup' "$S" && ok "'no network, no writes' is scoped to diagnosis after setup" || ko "SKILL.md scopes 'no network, no writes' to diagnosis after setup"
grep -qE '~/\.local/bin/agent-chain-doctor' "$S" && ok "install location is named" || ko "SKILL.md names where setup writes the script"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
