#!/bin/bash
# Tests for missed-run-check. Red-green: CHECK=/path/to/neutered ./test-missed-run-check.sh
# must fail the detection tests; the real one must pass all of them.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CK="${CHECK:-$HERE/missed-run-check}"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1 — $2"; }
expect() { # name, wanted rc, wanted text (or ''), command...
  local name=$1 want=$2 txt=$3; shift 3
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" != "$want" ]; then bad "$name" "rc $rc, wanted $want: $out"; return; fi
  if [ -n "$txt" ] && ! printf '%s' "$out" | grep -q -- "$txt"; then bad "$name" "no '$txt' in: $out"; return; fi
  ok "$name"
}
T0=1790000000   # fixed clock: 2026-09-21T13:33:20Z
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
F=$WORK/beats.tsv

# 1. Healthy hourly routine: last run started 40 min ago and ended ok.
printf 'START\tr1\t%s\nEND\tr1\t%s\tok\nSTART\tr2\t%s\nEND\tr2\t%s\tok\n' \
  "$(iso $((T0-6000)))" "$(iso $((T0-5700)))" "$(iso $((T0-2400)))" "$(iso $((T0-2100)))" > "$F"
expect "healthy routine -> exit 0" 0 "OK" "$CK" -f "$F" -e 3600 --now $T0

# 2. Missed fires: last start 3 h ago on an hourly schedule.
printf 'START\tr1\t%s\nEND\tr1\t%s\tok\n' "$(iso $((T0-10800)))" "$(iso $((T0-10500)))" > "$F"
expect "missed fires -> exit 1, MISSED" 1 "MISSED" "$CK" -f "$F" -e 3600 --now $T0

# 3. Grace: 70 min late with a 15 min grace is still fine.
printf 'START\tr1\t%s\nEND\tr1\t%s\tok\n' "$(iso $((T0-4200)))" "$(iso $((T0-4000)))" > "$F"
expect "within grace -> exit 0" 0 "" "$CK" -f "$F" -e 3600 -g 900 --now $T0

# 4. Started but never ended (died or hung on a permission prompt), past max run time.
printf 'START\tr1\t%s\n' "$(iso $((T0-3000)))" > "$F"
expect "start without end past max -> exit 1, NO END" 1 "NO END" "$CK" -f "$F" -e 3600 -m 1800 --now $T0

# 5. Still running inside max run time is not an alarm.
printf 'START\tr1\t%s\n' "$(iso $((T0-600)))" > "$F"
expect "running within max -> exit 0" 0 "" "$CK" -f "$F" -e 3600 -m 1800 --now $T0

# 6. A run that ended with a non-ok status is reported.
printf 'START\tr1\t%s\nEND\tr1\t%s\tfailed\n' "$(iso $((T0-1200)))" "$(iso $((T0-900)))" > "$F"
expect "ended not ok -> exit 1, FAILED" 1 "FAILED" "$CK" -f "$F" -e 3600 --now $T0

# 7. No heartbeat at all is not "all clear".
: > "$F"
expect "empty file -> exit 2" 2 "" "$CK" -f "$F" -e 3600 --now $T0
expect "missing file -> exit 2" 2 "" "$CK" -f "$WORK/nope.tsv" -e 3600 --now $T0

# 8. An old orphan START outside the window does not alarm forever.
printf 'START\told\t%s\nSTART\tr2\t%s\nEND\tr2\t%s\tok\n' "$(iso $((T0-400000)))" "$(iso $((T0-1200)))" "$(iso $((T0-900)))" > "$F"
expect "old orphan outside window -> exit 0" 0 "" "$CK" -f "$F" -e 3600 --now $T0

# 9. --record appends lines the checker reads back.
: > "$F"
"$CK" --record start r9 -f "$F" >/dev/null 2>&1
"$CK" --record end r9 -f "$F" >/dev/null 2>&1
n=$(grep -c . "$F" 2>/dev/null); [ "${n:-0}" = 2 ] && ok "--record writes START and END" || bad "--record writes START and END" "lines=${n:-0}"
expect "recorded fresh run -> exit 0" 0 "OK" "$CK" -f "$F" -e 3600

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
