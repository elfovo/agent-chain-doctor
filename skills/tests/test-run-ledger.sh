#!/bin/bash
# Tests for the run-ledger skill: front-matter, START/END writing, wrap, report and check on fixtures.
set -u
. "$(dirname "$0")/lib.sh"
S="$ROOT/run-ledger"
check_skill "$S"
L="$S/scripts/ledger.sh"

# check on fixtures. --now pins the clock.
out=$(bash "$L" check -f "$FIX/ledgers/clean.tsv" -e 3600 -m 1800 --now 2026-10-12T02:30:00Z 2>&1); rc=$?
expect_eq "check: clean ledger exits 0" 0 "$rc"
expect_match "check: clean ledger says OK" '^OK' "$out"
out=$(bash "$L" check -f "$FIX/ledgers/open-run.tsv" -e 3600 -m 1800 --now 2026-10-12T02:30:00Z 2>&1); rc=$?
expect_eq "check: START without END exits 1" 1 "$rc"
expect_match "check: START without END names the run" '^OPEN r2 ' "$out"
expect_nomatch "check: finished runs are not OPEN" '^OPEN r(1|3) ' "$out"
out=$(bash "$L" check -f "$FIX/ledgers/open-run.tsv" -e 3600 -m 1800 --now 2026-10-12T01:10:00Z 2>&1)
expect_nomatch "check: a run younger than -m is not OPEN yet" '^OPEN r2 ' "$out"
out=$(bash "$L" check -f "$FIX/ledgers/gap.tsv" -e 3600 -m 1800 --now 2026-10-12T02:30:00Z 2>&1); rc=$?
expect_eq "check: gap exits 1" 1 "$rc"
expect_match "check: gap between starts reported with missed slots" '^GAP 2026-10-11T22:00:02Z -> 2026-10-12T02:00:01Z .*3 slot' "$out"
out=$(bash "$L" check -f "$FIX/ledgers/clean.tsv" -e 3600 -m 1800 --now 2026-10-12T05:00:00Z 2>&1); rc=$?
expect_eq "check: no start for too long exits 1" 1 "$rc"
expect_match "check: LATE reported" '^LATE ' "$out"
out=$(bash "$L" check -f "$FIX/ledgers/failed.tsv" -e 3600 -m 1800 --now 2026-10-12T02:30:00Z 2>&1); rc=$?
expect_eq "check: failed END exits 1" 1 "$rc"
expect_match "check: FAILED names run and status" '^FAILED r1 exit-1' "$out"
out=$(bash "$L" check -f "$FIX/ledgers/malformed.tsv" -e 3600 -m 1800 --now 2026-10-12T02:30:00Z 2>&1); rc=$?
expect_eq "check: malformed line exits 1" 1 "$rc"
expect_match "check: malformed line reported with its number" '^BAD-LINE 2' "$out"
bash "$L" check -f "$TMPD/none.tsv" -e 3600 >/dev/null 2>&1; expect_eq "check: missing ledger exits 2" 2 "$?"

# report
out=$(bash "$L" report -f "$FIX/ledgers/open-run.tsv" --now 2026-10-12T02:30:00Z 2>&1)
expect_match "report: finished run with duration" 'r1 .*2026-10-12T00:00:02Z .*248s .*ok' "$out"
expect_match "report: open run marked" 'r2 .*OPEN' "$out"

# writing: start / end / wrap
LF="$TMPD/repo/.heartbeat/beats.tsv"
id=$(bash "$L" start -f "$LF"); rc=$?
expect_eq "start: exits 0 and creates the directory" 0 "$rc"
[ -n "$id" ] && ok "start: prints a run id ($id)" || bad "start: prints a run id"
expect_match "start: writes a START line" "^START	$id	[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\$" "$(tail -1 "$LF")"
bash "$L" end -f "$LF" "$id" ok
expect_match "end: writes an END line" "^END	$id	[0-9T:Z-]+	ok\$" "$(tail -1 "$LF")"
bash "$L" end -f "$LF" "$id" "bad status with spaces" >/dev/null 2>&1; expect_eq "end: rejects a status with spaces" 64 "$?"
bash "$L" wrap -f "$LF" -- true; expect_eq "wrap: true exits 0" 0 "$?"
expect_match "wrap: END ok after success" '	ok$' "$(tail -1 "$LF")"
bash "$L" wrap -f "$LF" -- sh -c 'exit 3'; expect_eq "wrap: propagates the exit code" 3 "$?"
expect_match "wrap: END exit-3 after failure" '	exit-3$' "$(tail -1 "$LF")"
starts=$(grep -c '^START' "$LF"); ends=$(grep -c '^END' "$LF")
expect_eq "wrap: every START has an END" "$starts" "$ends"
out=$(bash "$L" check -f "$LF" -e 3600 -m 1800 2>&1)
expect_match "check: sees the wrapped failure" '^FAILED .* exit-3' "$out"
summary run-ledger
