#!/bin/bash
# Tests for startup-watchdog. Red-green: WATCHDOG=/path/to/neutered ./test-startup-watchdog.sh
# must fail the kill tests; the real one must pass all of them.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WD="${WATCHDOG:-$HERE/startup-watchdog}"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1 — $2"; }

# 1. A command that never writes a byte is killed at the deadline, with exit 124.
s=$(date +%s)
"$WD" -t 2 -l "$WORK/mute.log" -- sleep 30 2>"$WORK/mute.err"; rc=$?
e=$(( $(date +%s) - s ))
[ "$rc" = 124 ] && ok "mute start -> exit 124" || bad "mute start -> exit 124" "got $rc"
[ "$e" -le 10 ] && ok "mute start killed near the deadline (${e}s)" || bad "mute start killed near the deadline" "took ${e}s"

# 2. The whole process group dies, not only the direct child.
"$WD" -t 2 -l "$WORK/grp.log" -- bash -c 'sleep 60 & echo $! > '"$WORK"'/grandchild; exec sleep 40' 2>/dev/null
sleep 1
gc=$(cat "$WORK/grandchild" 2>/dev/null)
if [ -n "$gc" ] && ! kill -0 "$gc" 2>/dev/null; then ok "grandchild killed with the group"
else bad "grandchild killed with the group" "pid ${gc:-?} still alive"; kill "$gc" 2>/dev/null; fi

# 3. A command that speaks early is left alone, runs past the deadline, and its status is kept.
"$WD" -t 2 -l "$WORK/talk.log" -- bash -c 'echo started; sleep 4; exit 7' 2>/dev/null; rc=$?
[ "$rc" = 7 ] && ok "talking command survives past deadline, status kept" || bad "talking command survives" "got $rc"
grep -q started "$WORK/talk.log" && ok "output lands in the log" || bad "output lands in the log" "log empty"

# 4. A fast successful command exits 0.
"$WD" -t 5 -l "$WORK/fast.log" -- true; rc=$?
[ "$rc" = 0 ] && ok "fast command exit 0" || bad "fast command exit 0" "got $rc"

# 5. Bad usage is refused, not run.
"$WD" -t abc -l "$WORK/x.log" -- true 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "non-numeric timeout refused (exit 2)" || bad "non-numeric timeout refused" "got $rc"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
