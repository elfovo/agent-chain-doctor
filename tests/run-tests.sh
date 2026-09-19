#!/bin/bash
# agent-chain-doctor — test suite.
#
# Two things are being proved here, and they are not the same thing:
#
#   1. every check goes RED on a chain built to trip it — one fixture per check;
#   2. NO check goes red on a correct chain — the single test that decides whether this tool
#      is worth running at all. A diagnostic that cries wolf on correct code teaches you to
#      ignore its reports, which is worse than having no report.
#
#   ./run-tests.sh            run the suite against the real tool — everything must be green
#   LEGACY=1 ./run-tests.sh   run it against a NEUTERED copy of the tool, in which every check
#                             returns immediately. Every detection test must go RED. That is
#                             the red-green protocol: a test never seen red proves nothing.
#
# The fixtures are original launchers written for this suite. They deliberately use variable
# names this tool has never seen (BOT_STATE, GATE, DUE_FILE, RUNLOG…), because a tool that
# only recognises the chain it grew up with is a tool that recognises a name, not a defect.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DOCTOR_SRC="$HERE/../agent-chain-doctor"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

PASS=0; FAIL=0; RED_LIST=""
DOCTOR="$DOCTOR_SRC"

if [ -n "${DOCTOR_BIN:-}" ]; then
  # An externally supplied build — used by prove-red.sh, which feeds this suite one mutant of
  # the tool at a time to find out which tests are actually watching which check.
  DOCTOR="$DOCTOR_BIN"
  echo "DOCTOR_BIN set — running against $DOCTOR_BIN"
elif [ "${LEGACY:-0}" = "1" ]; then
  # The neutered build: every check function returns before doing anything. Same file
  # otherwise, so discovery, reporting and the read-only guard keep working.
  awk '{ print } /^check_[LS][0-9]+_[a-z_0-9]+\(\) \{$/ { print "  return 0" }' "$DOCTOR_SRC" > "$WORK/degraded.sh"
  chmod +x "$WORK/degraded.sh"
  DOCTOR="$WORK/degraded.sh"
  echo "LEGACY=1 — running against a neutered copy; every detection test MUST go red."
fi

# THE ONE PRECONDITION THIS SUITE CANNOT ASSERT FROM INSIDE. Two cases (T185, T189) build a
# file the tool must find UNREADABLE, and `[ ! -r "$f" ]` is FALSE for root: run as root they
# land on a different branch of the same check, stay GREEN, and certify a branch they never
# reached. Nothing in a test file can detect that from its own result — the result is a pass
# either way. So it is refused up front rather than measured wrong, which is the same rule the
# tool under test applies to itself: a thing that could not be measured is not reported as
# measured. Overridable, because a CI that runs everything in a root container is entitled to
# see the other 213 — but only by saying so out loud.
not_root() {  # $1 uid → 0 = safe to run, 1 = the unreadable-file cases cannot mean anything
  case "${1:-}" in 0) return 1 ;; *) return 0 ;; esac
}
if ! not_root "$(id -u 2>/dev/null)" && [ "${ALLOW_ROOT:-0}" != "1" ]; then
  echo "run-tests.sh: running as root would make T185 and T189 green without reaching their" >&2
  echo "branch ([ ! -r ] is false for root). Run as an ordinary user, or ALLOW_ROOT=1 to run" >&2
  echo "anyway and read those two as unproven." >&2
  exit 2
fi

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); RED_LIST="$RED_LIST
    $1"; printf '  RED  %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

OUT=""; RC=0
# A GLOBAL invariant, checked on every single run rather than on the four fixtures that happen
# to ask for it. Measured in S54 by fine mutation: dropping a `return` after a finding makes a
# check emit TWICE, the report then breaks its own "every id, exactly once" promise — and this
# suite stayed 151/151 green for eight such mutants, because expect_full_catalogue is called on
# four chains and the duplicates happen on the others. A rule asserted on four fixtures out of
# a hundred is a rule asserted nowhere in particular.
DUP_TRAIL=""; DUP_RUNS=0
note_duplicates() {  # $1 what was run, for the trail
  local dups
  dups=$(printf '%s\n' "$OUT" | grep -oE '^  (EXPOSED|GUARDED|UNKNOWN)[[:space:]]+[LS][0-9]+[[:space:]]' \
         | awk '{print $2}' | sort | uniq -d | tr '\n' ' ')
  DUP_RUNS=$((DUP_RUNS + 1))
  [ -z "$dups" ] || DUP_TRAIL="$DUP_TRAIL
      $1 → $dups"
}
run_doctor() { OUT=$(bash "$DOCTOR" --verbose "$@" 2>&1); RC=$?; note_duplicates "$*"; }

has_verdict() {  # $1 verdict  $2 id
  printf '%s\n' "$OUT" | grep -qE "^  $1[[:space:]]+$2[[:space:]]"
}
expect() {  # $1 name  $2 verdict  $3 id
  if has_verdict "$2" "$3"; then ok "$1"
  else bad "$1" "expected $2 $3; got: $(printf '%s\n' "$OUT" | grep -E "^  [A-Z]+[[:space:]]+$3[[:space:]]" | head -n 1 | sed 's/^ *//')"
  fi
}
# Same, but the branch is pinned by WHAT THE TOOL SAID, not only by its verdict. L3 has three
# UNKNOWN branches and L1 two: `expect UNKNOWN L3` is green on any of them, so a fixture that
# lands on the wrong one certifies a branch it never reached. That is not hypothetical — S54
# measured sixteen `UNKNOWN → GUARDED` mutants surviving a suite of 152 tests, on nine checks
# whose UNKNOWN half no test had ever asserted. Every assertion added by S55 uses this one.
expect_because() {  # $1 name  $2 verdict  $3 id  $4 a literal fragment of the summary
  if printf '%s\n' "$OUT" | grep -E "^  $2[[:space:]]+$3[[:space:]]" | grep -qF "$4"; then ok "$1"
  else bad "$1" "expected $2 $3 saying '$4'; got: $(printf '%s\n' "$OUT" | grep -E "^  [A-Z]+[[:space:]]+$3[[:space:]]" | head -n 1 | sed 's/^ *//')"
  fi
}
# …and the same for an EVIDENCE line under a finding, which is where a check puts the value it
# actually measured. A verdict can be right while the evidence beside it is empty.
expect_evidence() {  # $1 name  $2 verdict  $3 id  $4 a literal fragment of the evidence
  if printf '%s\n' "$OUT" | grep -A4 -E "^  $2[[:space:]]+$3[[:space:]]" | grep -qF "$4"; then ok "$1"
  else bad "$1" "expected the $2 $3 evidence to carry '$4'; got: $(printf '%s\n' "$OUT" | grep -A4 -E "^  $2[[:space:]]+$3[[:space:]]" | tail -n 3 | tr '\n' ' ')"
  fi
}
# Exactly once, on THIS chain, for THIS id — the named counterpart of the global duplicate
# sweep. T152 already asks "did any run print an id twice", and it is right to; but S67 measured
# what it costs to let it ask ALONE. All eleven `return`-dropped mutants of this tool died by
# T152 and by nothing else, and the share of the mutation matrix that one test carries by itself
# went from 12 % to 16 % — pushed up not by anyone weakening the suite but by thirty-five
# assertions written for an unrelated reason, whose extra runs widened its sweep. A property
# held by a single generic test gets FATTER every time the suite grows anywhere, and nothing
# named would notice it going mute. Each call below names one chain that actually walks one of
# those returns, so the return has a test saying which check, on which chain, must speak once.
expect_once() {  # $1 name  $2 id
  local n; n=$(printf '%s\n' "$OUT" | grep -cE "^  (EXPOSED|GUARDED|UNKNOWN)[[:space:]]+$2[[:space:]]")
  if [ "$n" -eq 1 ]; then ok "$1"
  else bad "$1" "$2 spoke $n times on this chain, not once: $(printf '%s\n' "$OUT" | grep -E "^  [A-Z]+[[:space:]]+$2[[:space:]]" | sed 's/^ *//' | tr '\n' ' ' | cut -c1-160)"
  fi
}
# The catalogue, spelled out. The report must carry every one of these exactly once, whatever
# the chain looks like. Three checks used to return WITHOUT emitting anything when their
# subject was absent (no wakeup file, no lock) and one could emit twice, so a real report
# carried 24, 25, 26 or 27 lines while the tool's own header promised "three verdicts and no
# fourth". Silence was the fourth verdict, and no test saw it: the suite only ever asked
# "is THIS id present with THIS verdict", never "are they all there, once each".
ALL_IDS="L1 L2 L3 L4 L5 L6 L7 L8 L9 L10 L11 L12 L13 S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14 S15 S16"
expect_full_catalogue() {  # $1 name
  local ids trouble="" id n total
  ids=$(printf '%s\n' "$OUT" | grep -oE '^  (EXPOSED|GUARDED|UNKNOWN)[[:space:]]+[LS][0-9]+[[:space:]]' | awk '{print $2}')
  for id in $ALL_IDS; do
    n=$(printf '%s\n' "$ids" | grep -cx "$id")
    [ "$n" -eq 1 ] || trouble="$trouble $id×$n"
  done
  total=$(printf '%s\n' "$ids" | grep -c '[LS]')
  if [ -z "$trouble" ] && [ "$total" -eq 29 ]; then ok "$1"
  else bad "$1" "total=$total${trouble:+ ; not exactly once:$trouble}"; fi
}

expect_no_exposed() {  # $1 name
  local n; n=$(printf '%s\n' "$OUT" | grep -cE '^  EXPOSED')
  if [ "$n" -eq 0 ]; then ok "$1"
  else bad "$1" "$n EXPOSED on a chain that has none: $(printf '%s\n' "$OUT" | grep -E '^  EXPOSED' | head -n 2 | tr '\n' ' ')"
  fi
}

# =========================================================================================
# Fixture builder. Creates a complete, CORRECT chain under $WORK/$1, then the caller breaks
# exactly one thing. Everything the tool reads is inside the sandbox: no test depends on the
# machine it runs on.
# =========================================================================================

ROOT=""; LAUNCHER=""; PLIST=""; LCTL=""; PMSET=""; STATE=""

make_chain() {  # $1 = fixture name
  [ -n "${1:-}" ] || { echo "make_chain needs a fixture name" >&2; exit 2; }
  # Start from nothing. make_chain used to only OVERWRITE the files it writes, so a fixture
  # reusing an earlier fixture's name inherited whatever that one had left on disk — a lock
  # directory, a pid file, a deleted error file. Found in S55 by two names colliding across
  # two eras of this suite; the visible symptom was a red test, but the same leak silently
  # makes a test GREEN whenever the leftover happens to be what the test wanted to build.
  rm -rf "$WORK/$1"
  ROOT="$WORK/$1"
  STATE="$ROOT/state"
  LAUNCHER="$ROOT/bot/nightly-run.sh"
  PLIST="$ROOT/com.test.bot.plist"
  LCTL="$ROOT/launchctl.txt"
  PMSET="$ROOT/pmset.txt"
  mkdir -p "$ROOT/bot" "$STATE" "$ROOT/bin"

  sed "s|@ROOT@|$ROOT|g" > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/bin/bash
# nightly-run.sh — a small scheduled-agent launcher (test fixture, not the tool under test).
# It is deliberately CORRECT on every defect this tool knows how to look for: it is the
# negative witness, and the static tests below break exactly one thing in a copy of it.
set -uo pipefail
: "${BOT_HOME:=@ROOT@/bot}"
: "${BOT_STATE:=@ROOT@/state}"
: "${BOT_CLI:=fakeagent}"
: "${BOT_ARGS=--quiet}"
: "${BOT_BRIEF:=$BOT_HOME/session-prompt.txt}"
: "${TIMEOUT:=14400}"
: "${DEADMAN:=10800}"
: "${LOCK_MAX_AGE:=14400}"
: "${MAX_AHEAD:=2592000}"
: "${IDLE_MIN:=900}"
: "${MIN_SPACING:=900}"
: "${WEEKDAY_CLOSED_START:=7}"
: "${WEEKDAY_CLOSED_END:=17}"
: "${PROBE_ERR:=$BOT_STATE/probe.err}"
RUNLOG="$BOT_STATE/run.log"
GATE="$BOT_STATE/run.lock"
DUE_FILE="$BOT_STATE/run.next"
STAMP="$BOT_STATE/run.last"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOW=$(date +%s)
HOUR=$((10#$(date +%H)))
if [ "$HOUR" -ge "$WEEKDAY_CLOSED_START" ] && [ "$HOUR" -lt "$WEEKDAY_CLOSED_END" ]; then
  WINDOW_LEFT=$(( WEEKDAY_CLOSED_END - HOUR ))
else
  WINDOW_LEFT=0
fi
DUE=$(cat "$DUE_FILE" 2>/dev/null)
case "$DUE" in ''|*[!0-9]*) DUE="$NOW" ;; esac
if [ "$DUE" -gt $((NOW + MAX_AHEAD)) ]; then DUE="$NOW"; fi
[ "$NOW" -lt "$DUE" ] && exit 0
if [ -d "$GATE" ]; then
  GATE_MTIME=$(stat -f %m "$GATE" 2>/dev/null)
  case "$GATE_MTIME" in ''|*[!0-9]*) GATE_AGE="" ;; *) GATE_AGE=$(( NOW - GATE_MTIME )) ;; esac
  if [ -n "$GATE_AGE" ] && [ "$GATE_AGE" -lt "$LOCK_MAX_AGE" ]; then exit 0; fi
fi
if ! mkdir "$GATE" 2>/dev/null; then
  [ -d "$GATE" ] || echo "cannot create the lock ($GATE)" >> "$RUNLOG"
  exit 0
fi
echo $$ > "$GATE/pid"
release() { if [ "$(cat "$GATE/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$GATE"; fi; }
trap 'release' EXIT
trap 'release; exit 143' TERM INT HUP
IDLE_RAW=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF; exit}')
case "$IDLE_RAW" in ''|*[!0-9]*) IDLE="" ;; *) IDLE=$(( IDLE_RAW / 1000000000 )) ;; esac
if [ -n "$IDLE" ] && [ "$IDLE" -lt "$IDLE_MIN" ]; then exit 0; fi
LAST_RUN=$(cat "$STAMP" 2>/dev/null)
case "$LAST_RUN" in ''|*[!0-9]*) LAST_RUN="" ;; esac
if [ -n "$LAST_RUN" ] && [ $(( NOW - LAST_RUN )) -lt "$MIN_SPACING" ]; then exit 0; fi
"$SCRIPT_DIR/nap-guard.sh"; NAP_RC=$?
echo "$NOW" > "$STAMP"
printf '%s\n' "$((NOW + DEADMAN))" > "$DUE_FILE.tmp" && mv "$DUE_FILE.tmp" "$DUE_FILE"
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -i "$BOT_CLI" -p "$(cat "$BOT_BRIEF")" $BOT_ARGS >> "$RUNLOG" 2>&1 &
else
  "$BOT_CLI" -p "$(cat "$BOT_BRIEF")" $BOT_ARGS >> "$RUNLOG" 2>&1 &
fi
AGENT_PID=$!
( sleep "$TIMEOUT"
  kill -0 "$AGENT_PID" 2>/dev/null || exit 0
  kill -TERM "$AGENT_PID" 2>/dev/null ) &
WATCHDOG_PID=$!
wait "$AGENT_PID"
BOT_RC=$?
kill "$WATCHDOG_PID" 2>/dev/null
SHOWN_EPOCH=$(cat "$DUE_FILE" 2>/dev/null)
case "$SHOWN_EPOCH" in ''|0|*[!0-9]*) SHOWN_EPOCH="" ;; esac
SHOWN_TIME=$(date -r "$SHOWN_EPOCH" '+%a %H:%M' 2>/dev/null || echo "epoch $SHOWN_EPOCH")
echo "=== End — exit $BOT_RC — next wakeup: $SHOWN_TIME ===" >> "$RUNLOG"
if [ "$BOT_RC" -ne 0 ]; then echo "the agent did not finish cleanly" >> "$RUNLOG"; fi
SESSION_END=$(date +%s)
case "$SESSION_END" in ''|*[!0-9]*) SESSION_END="" ;; esac
if [ -n "$SESSION_END" ] && [ "$SESSION_END" -gt "$NOW" ]; then echo "$SESSION_END" > "$STAMP"; fi
LAUNCHER_EOF

  printf '#!/bin/bash\nexit 0\n' > "$ROOT/bot/nap-guard.sh"
  chmod +x "$ROOT/bot/nap-guard.sh"
  printf 'Work on the roadmap. Write a journal entry. Schedule your next wakeup.\n' > "$ROOT/bot/session-prompt.txt"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/bin/fakeagent"
  chmod +x "$ROOT/bin/fakeagent"

  printf '=== Session: last night ===\n' > "$STATE/run.log"
  : > "$STATE/probe.err"
  printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$STATE/run.next"

  sed -e "s|@ROOT@|$ROOT|g" > "$PLIST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.bot</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>@ROOT@/bot/nightly-run.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>@ROOT@/bin:/usr/bin:/bin</string></dict>
  <key>StandardErrorPath</key><string>@ROOT@/state/probe.err</string>
</dict>
</plist>
PLIST_EOF

  printf -- '-\t0\tcom.test.bot\n' > "$LCTL"
  # A sleep history with no transition inside the chain's 17:00→07:00 window.
  {
    printf '%s 12:04:11 +0400 Sleep               \tEntering Sleep state\n' "$(date '+%Y-%m-%d')"
    printf '%s 12:44:02 +0400 Wake                \tWake from Sleep\n' "$(date '+%Y-%m-%d')"
    printf '%s 09:10:00 +0400 Assertions          \tPID 42 noise\n' "$(date '+%Y-%m-%d')"
  } > "$PMSET"
}

# EXPORTED, and that one word matters: the hooks have to reach a CHILD bash. Set without
# export they stay in this shell, the tool falls back to the real launchctl and the real
# pmset, and half the suite silently measures the machine it runs on instead of its fixture.
doctor() {
  export ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET"
  run_doctor --plist "$PLIST" "$LAUNCHER"
}

# mutate SED-EXPR… — rewrite the fixture's launcher in place, breaking exactly one thing.
mutate() {
  local tmp="$LAUNCHER.m"
  cp "$LAUNCHER" "$tmp"
  local e
  for e in "$@"; do sed -e "$e" "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"; done
  mv "$tmp" "$LAUNCHER"
}

echo
echo "agent-chain-doctor — test suite"
echo

# =========================================================================================
# The one that matters most: a correct chain must produce no EXPOSED at all.
# =========================================================================================
echo "-- no false positives on a correct chain"
make_chain clean
doctor
expect_no_exposed "T01  correct chain → zero EXPOSED"
if [ "$RC" -eq 0 ]; then ok "T02  exit code 0 when nothing is exposed"; else bad "T02  exit code 0 when nothing is exposed" "got $RC"; fi
# 4/5 and not 5/5, deliberately: the fixture's agent binary is called `fakeagent`, a name
# the tool has never heard of. It still recognises the chain — on the defect markers, not on
# the CLI. A tool that needs to know your agent's name is a tool that knows one chain.
if printf '%s\n' "$OUT" | grep -q 'matched 4/5 markers'; then ok "T03  discovery scores an unknown agent CLI at 4/5"
else bad "T03  discovery scores an unknown agent CLI at 4/5" "$(printf '%s\n' "$OUT" | grep -i marker | head -n 1)"; fi
if printf '%s\n' "$OUT" | grep -q "state dir *$STATE\$"; then ok "T04  state dir deduced from foreign variable names"
else bad "T04  state dir deduced from foreign variable names" "$(printf '%s\n' "$OUT" | grep 'state dir')"; fi
if printf '%s\n' "$OUT" | grep -q 'UNKNOWN means'; then ok "T05  report never ends on a reassuring line"
else bad "T05  report never ends on a reassuring line"; fi

echo
echo "-- one fixture per check"

# L1 — the probe's last exit code, read from the scheduler registry.
make_chain l1; printf -- '-\t127\tcom.test.bot\n' > "$LCTL"; doctor
expect "T06  L1  probe exited 127" EXPOSED L1
make_chain l1b; doctor
expect "T07  L1  probe exited 0" GUARDED L1

# L2 — registered and silent. Silence alone is NOT a finding.
# The wakeup is pushed into the past on purpose: a log that has never been created while the
# chain was already DUE is the failure. The same absence with the wakeup still ahead is a chain
# waiting for its first session, and T78 below holds that line.
make_chain l2; rm -f "$STATE/run.log"
printf '%s\n' "$(( $(date +%s) - 3600 ))" > "$STATE/run.next"
doctor
expect "T08  L2  main log never created, and the chain was already due" EXPOSED L2
make_chain l2b
touch -t "$(date -v-9d '+%Y%m%d%H%M' 2>/dev/null || date -d '9 days ago' '+%Y%m%d%H%M')" "$STATE/run.log"
doctor
expect "T09  L2  old log + healthy probe → UNKNOWN, not EXPOSED" UNKNOWN L2
make_chain l2c
touch -t "$(date -v-9d '+%Y%m%d%H%M' 2>/dev/null || date -d '9 days ago' '+%Y%m%d%H%M')" "$STATE/run.log"
printf -- '-\t2\tcom.test.bot\n' > "$LCTL"
doctor
expect "T10  L2  old log + failing probe → EXPOSED" EXPOSED L2

# L3 — the probe's error file, and whether anything drains it.
make_chain l3
printf 'nightly-run.sh: line 22: unexpected EOF\n' > "$STATE/probe.err"
touch -t "$(date -v-2d '+%Y%m%d%H%M' 2>/dev/null || date -d '2 days ago' '+%Y%m%d%H%M')" "$STATE/probe.err"
doctor
expect "T11  L3  errors written before the last session, still there" EXPOSED L3
make_chain l3b; doctor
expect "T12  L3  empty error file" GUARDED L3

# L4 — wakeup file present but unreadable. Absent is NOT the same as broken.
make_chain l4; : > "$STATE/run.next"; doctor
expect "T13  L4  wakeup file present and empty" EXPOSED L4
make_chain l4b; printf 'tomorrow\n' > "$STATE/run.next"; doctor
expect "T14  L4  wakeup file is not a number" EXPOSED L4
make_chain l4c; rm -f "$STATE/run.next"; doctor
expect "T15  L4  wakeup file absent → UNKNOWN, not EXPOSED" UNKNOWN L4

# L5 — shape passed, range did not.
make_chain l5; printf '%s\n' "$(( $(date +%s) * 1000 ))" > "$STATE/run.next"; doctor
expect "T16  L5  epoch in milliseconds (13 digits)" EXPOSED L5
make_chain l5b
printf '%s\n' "$(( $(date +%s) - 400000 ))" > "$STATE/run.next"
doctor
expect "T17  L5  long overdue + healthy probe → UNKNOWN" UNKNOWN L5

# L6 — the lock has the wrong shape for the launcher that creates it.
make_chain l6; printf 'debris\n' > "$STATE/run.lock"; doctor
expect "T18  L6  plain file where mkdir expects a directory" EXPOSED L6

# L7 — a lock held by a dead owner.
make_chain l7
mkdir -p "$STATE/run.lock"
( exit 0 ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
printf '%s\n' "$DEADPID" > "$STATE/run.lock/pid"
doctor
expect "T19  L7  lock held by a dead pid" EXPOSED L7
make_chain l7b
mkdir -p "$STATE/run.lock"; printf '%s\n' "$$" > "$STATE/run.lock/pid"
doctor
expect "T20  L7  lock held by a live pid" GUARDED L7

# L8 — a session running past its own budget. The two cases that used to live here (T21, T22)
# wrote `$$` into the lock, so L8 was reading the elapsed time of the TEST SUITE: the `sleep 2`
# was decorative, and T22 was green only because the suite had been running less than the
# four-hour default budget. Replaced by T112-T114 at the end of this file, which own a child
# process, control its age, and decide the verdict on the budget alone.

# L9 — a script invoked by path without its +x bit.
make_chain l9; chmod -x "$ROOT/bot/nap-guard.sh"; doctor
expect "T23  L9  helper script lost its +x bit" EXPOSED L9
make_chain l9b; doctor
expect "T24  L9  helper script is executable" GUARDED L9

# L10 — the machine sleeps inside the work window.
make_chain l10
{
  printf '%s 02:04:11 +0400 Sleep               \tEntering Sleep state\n' "$(date '+%Y-%m-%d')"
  printf '%s 02:22:11 +0400 Sleep               \tEntering Sleep state\n' "$(date '+%Y-%m-%d')"
  printf '%s 03:41:02 +0400 Sleep               \tEntering Sleep state\n' "$(date '+%Y-%m-%d')"
} > "$PMSET"
mutate '/^if command -v caffeinate/,/^fi$/d' \
       's|^AGENT_PID=\$!|"$BOT_CLI" -p "$(cat "$BOT_BRIEF")" >> "$RUNLOG" 2>\&1 \&\nAGENT_PID=$!|'
doctor
expect "T25  L10 sleeps in the window, nothing keeps the machine awake" EXPOSED L10
make_chain l10b; doctor
expect "T26  L10 no sleep inside the window" GUARDED L10

# L11 — the prompt file, which is the whole session contract.
make_chain l11; : > "$ROOT/bot/session-prompt.txt"; doctor
expect "T27  L11 prompt file empty" EXPOSED L11
make_chain l11b; rm -f "$ROOT/bot/session-prompt.txt"; doctor
expect "T28  L11 prompt file missing" EXPOSED L11
make_chain l11c; doctor
expect "T29  L11 prompt file present and filled" GUARDED L11

# L12 — the SCHEDULER's PATH, not yours, is what resolves the agent binary.
make_chain l12
sed -i.bak "s|<string>$ROOT/bin:/usr/bin:/bin</string>|<string>/usr/bin:/bin</string>|" "$PLIST" && rm -f "$PLIST.bak"
doctor
expect "T30  L12 agent binary unresolvable under the scheduler PATH" EXPOSED L12
make_chain l12b; doctor
expect "T31  L12 agent binary resolves under the scheduler PATH" GUARDED L12

# L13 — the scheduler writes errors to one file, the launcher drains another.
make_chain l13
sed -i.bak "s|<string>$ROOT/state/probe.err</string>|<string>$ROOT/state/elsewhere.err</string>|" "$PLIST" && rm -f "$PLIST.bak"
doctor
expect "T32  L13 scheduler and launcher name different error files" EXPOSED L13
make_chain l13b; doctor
expect "T33  L13 both name the same error file" GUARDED L13

# The negative match. A launcher whose lock is NOT created with mkdir cannot be judged on the
# shape of that lock, and the honest answer is UNKNOWN. This is the test that caught src_line
# reporting a match for every pattern it was ever given.
make_chain l6b
mutate '/^if ! mkdir/,+3d' 's|^echo \$\$ > "\$GATE/pid"|if [ -e "$GATE" ]; then exit 0; fi\necho $$ > "$GATE/pid"|' 
printf 'debris\n' > "$STATE/run.lock"
doctor
expect "T48  L6  no mkdir in the launcher → UNKNOWN, not EXPOSED" UNKNOWN L6

echo
echo "-- the scheduler's environment wins over the launcher's defaults"
# `: "${VAR:=default}"` only fires when the variable is unset, so a value declared in the
# scheduler entry is the one the chain actually runs with. Resolving paths without that merge
# reads the wrong files and reports on a directory nobody uses.
make_chain envwin
mkdir -p "$ROOT/real-state"
printf 'live\n' > "$ROOT/real-state/run.log"
sed -i.bak "s|<key>PATH</key><string>|<key>BOT_STATE</key><string>$ROOT/real-state</string><key>PATH</key><string>|" "$PLIST" && rm -f "$PLIST.bak"
doctor
if printf '%s\n' "$OUT" | grep -q "state dir *$ROOT/real-state\$"; then ok "T34  scheduler-declared BOT_STATE overrides the launcher default"
else bad "T34  scheduler-declared BOT_STATE overrides the launcher default" "$(printf '%s\n' "$OUT" | grep 'state dir')"; fi

# A launcher of realistic size must not take minutes. Variable resolution is recursive, so a
# single fork inside its inner loop turns a 400-line launcher into seventeen seconds — which,
# on the first real run of this tool, was indistinguishable from a hang. The bound is loose on
# purpose: it is there to catch that class of regression, not to police milliseconds.
make_chain big
{ echo; for i in $(seq 1 400); do echo "SPARE_$i=\"\$BOT_STATE/spare-$i.dat\""; done; } >> "$LAUNCHER"
t0=$(date +%s); doctor; t1=$(date +%s)
if [ $((t1 - t0)) -lt 20 ] && printf '%s\n' "$OUT" | grep -q '^FINDINGS'; then ok "T51  a 400-line launcher is diagnosed in seconds, not minutes"
else bad "T51  a 400-line launcher is diagnosed in seconds, not minutes" "took $((t1 - t0))s"; fi

echo
echo "-- it cannot break anything, and that is checked, not intended"

# The read-only guard. Any write operator or network binary in the tool's source fails the
# suite unless the line carries a `# rw-ok:` annotation — and an annotation on a line with no
# write operator fails too, so the exception list cannot rot into a rubber stamp.
guard_src=$(grep -vE '^[[:space:]]*#' "$DOCTOR_SRC" \
  | sed -e 's|2>&1||g; s|>&2||g; s|>&1||g; s|[0-9]*>>*[[:space:]]*/dev/null||g')
# The three patterns below are the tool's proof of innocuity — the thing a stranger is asked
# to trust before running it on their own chain. They had named holes: `2> file` and `&> file`
# could not match T35 (the leading class excluded digits and `&`, to skip `2>&1`, which the
# sed above has already removed anyway), and `if rm x; then` / `find … -exec rm` could not
# match T36. A guard with holes is worse than no guard: it is a promise.
WRITE_REDIR_RE='(^|[^A-Za-z_>=-])[0-9&]?>>?[[:space:]]*["'"'"'$/A-Za-z]'
WRITE_CMD_RE='((^|[;&|(]|&&|\|\|)[[:space:]]*|[[:space:]]*(then|do|else|if|while|until|elif)[[:space:]]+|-exec[[:space:]]+)(rm|mv|cp|touch|chmod|chown|mkdir|tee|dd|ln|truncate|install)[[:space:]]'

w=$(printf '%s\n' "$guard_src" | grep -nE "$WRITE_REDIR_RE" | grep -v 'rw-ok:')
if [ -z "$w" ]; then ok "T35  no write redirection in the tool's source"
else bad "T35  no write redirection in the tool's source" "$(printf '%s' "$w" | head -n 2 | tr '\n' ' ')"; fi

w=$(printf '%s\n' "$guard_src" | grep -nE "$WRITE_CMD_RE" | grep -v 'rw-ok:')
if [ -z "$w" ]; then ok "T36  no writing command in the tool's source"
else bad "T36  no writing command in the tool's source" "$(printf '%s' "$w" | head -n 2 | tr '\n' ' ')"; fi

# A guard that has never been seen firing is a guard nobody has measured. These feed the two
# patterns above the write forms they claim to cover — every one of which used to slip past —
# and fail the suite if a pattern stays silent. This is the red-green protocol applied to the
# innocuity proof itself, which is the one claim of this repo that has to be exact.
guard_fires() {  # $1 label  $2 regex  $3.. lines that MUST match
  local label="$1" re="$2"; shift 2
  local line missed=""
  for line in "$@"; do
    printf '%s\n' "$line" | grep -qE "$re" || missed="$missed | $line"
  done
  if [ -z "$missed" ]; then ok "$label"
  else bad "$label" "not matched:$missed"; fi
}
guard_fires "T35b the write-redirection pattern fires on every form it claims" "$WRITE_REDIR_RE" \
  'printf x > "$f"' 'printf x >> "$f"' 'cmd 2> /tmp/log' 'cmd &> /tmp/log' 'cmd >/tmp/log' \
  'cat foo > bar' 'echo hi >"$OUT"'
guard_fires "T36b the writing-command pattern fires on every form it claims" "$WRITE_CMD_RE" \
  'rm -f "$f"' '  mv a b' 'cmd && rm -rf x' 'if rm x; then :; fi' 'while touch f; do :; done' \
  'find . -exec rm {} +' 'a; mkdir b' 'x | tee f' 'else chmod 700 d'


w=$(printf '%s\n' "$guard_src" | grep -nE '(^|[^A-Za-z_-])(curl|wget|nc|ncat|ssh|scp|sftp|telnet|openssl)[[:space:]]')
if [ -z "$w" ]; then ok "T37  no network binary in the tool's source"
else bad "T37  no network binary in the tool's source" "$(printf '%s' "$w" | head -n 2 | tr '\n' ' ')"; fi

ORPHAN_RE='(>|rm |mv |cp |touch |chmod |mkdir |tee )'
w=$(grep -n 'rw-ok:' "$DOCTOR_SRC" | grep -vE "$ORPHAN_RE")
if [ -z "$w" ]; then ok "T38  no orphan rw-ok: annotation"
else bad "T38  no orphan rw-ok: annotation" "$(printf '%s' "$w" | head -n 1)"; fi
# T38 PASSES ON AN EMPTY SET: there is not one `rw-ok:` in the source, so it has never once
# been asked a question. Its whole job is to stop the exception clause from rotting into a
# rubber stamp — and an exception clause that has never been exercised is exactly that. So
# the predicate is made to answer on a line built for it, both ways.
if printf '%s\n' '  x=1  # rw-ok: nothing is written here' | grep 'rw-ok:' | grep -qvE "$ORPHAN_RE" \
   && ! printf '%s\n' '  printf x > "$f"  # rw-ok: deliberate' | grep 'rw-ok:' | grep -qvE "$ORPHAN_RE"; then
  ok "T38b the orphan-annotation predicate answers on both sides, so T38 is not vacuous"
else bad "T38b the orphan-annotation predicate answers on both sides, so T38 is not vacuous"; fi

# And an observed run: nothing under the sandbox changed while the tool inspected it.
make_chain readonly
before=$(find "$ROOT" -type f -exec stat -f '%N %m %z' {} + 2>/dev/null \
         || find "$ROOT" -type f -exec stat -c '%n %Y %s' {} + 2>/dev/null)
doctor
after=$(find "$ROOT" -type f -exec stat -f '%N %m %z' {} + 2>/dev/null \
        || find "$ROOT" -type f -exec stat -c '%n %Y %s' {} + 2>/dev/null)
if [ "$before" = "$after" ]; then ok "T39  an observed run modified nothing in the chain"
else bad "T39  an observed run modified nothing in the chain" "$(diff <(printf '%s' "$before") <(printf '%s' "$after") | head -n 3 | tr '\n' ' ')"; fi

echo
echo "-- the static checks: GUARDED on the correct launcher"
# The negative witness. Sixteen heuristics reading shell they did not write, on a launcher
# that is correct on all sixteen counts — this block is the one that decides whether they are
# worth printing at all. Each also has to prove a POSITIVE pattern: "no dangerous shape found"
# is UNKNOWN, never GUARDED, so a check that cannot recognise protection can never land here.
make_chain sclean; doctor
for sid in S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14 S15 S16; do
  expect "T51/$sid  $sid guarded on the correct launcher" GUARDED "$sid"
done

echo
echo "-- the static checks: one broken copy per check"
# S1 — the truncating write is the defect this whole tool grew out of: `date … > trigger`
# empties the trigger before date runs, and an empty trigger stops the chain in silence.
make_chain s1
printf 'date +%%s > "$DUE_FILE"\n' >> "$LAUNCHER"
doctor
expect "T52  S1  truncating write onto the wakeup file" EXPOSED S1

# S2 — traps that cover EXIT only. Read one trap at a time this is invisible; the check has to
# take the union, because the correct launcher installs four separate traps.
make_chain s2; mutate "/trap 'release; exit 143'/d"; doctor
expect "T53  S2  every trap covers EXIT only" EXPOSED S2

# S3 — a kill handler that releases the lock and lets the script run on: two agents.
make_chain s3; mutate "s/trap 'release; exit 143'/trap 'release'/"; doctor
expect "T54  S3  signal handler that does not terminate" EXPOSED S3

# S4 — a failed mkdir conflated with a lost race.
make_chain s4
mutate '/if ! mkdir/,+3d' 's|^echo \$\$ > "\$GATE/pid"|mkdir "$GATE" 2>/dev/null \|\| exit 0\necho $$ > "$GATE/pid"|'
doctor
expect "T55  S4  mkdir failure treated as a lost race" EXPOSED S4

# S5 — the defensive fallback pointing the wrong way: unreadable mtime → age of 56 years.
make_chain s5; mutate 's|stat -f %m "\$GATE" 2>/dev/null|stat -f %m "$GATE" 2>/dev/null \|\| echo 0|'; doctor
expect "T56  S5  unreadable timestamp falls back to zero" EXPOSED S5

# S6 — dividing inside the awk that reads the idle probe, before validating anything.
make_chain s6
mutate "s|{print \\\$NF; exit}|{print int(\\\$NF/1000000000); exit}|"
doctor
expect "T57  S6  idle probe divided inside awk" EXPOSED S6

# S7 — an unconditional keep-awake wrapper whose binary the scheduler's PATH cannot resolve.
# The failure is total and counter-intuitive: the wrapper meant to protect the session is what
# stops it from ever starting.
make_chain s7
mutate '/if command -v caffeinate/d' '/^else$/,+1d' '/^fi$/d'
sed -e "s|<string>$ROOT/bin:/usr/bin:/bin</string>|<string>$ROOT/bin</string>|" "$PLIST" > "$PLIST.2" && mv "$PLIST.2" "$PLIST"
doctor
expect "T58  S7  unconditional wrapper the scheduler's PATH cannot resolve" EXPOSED S7

# S8 — nothing bounds the agent's run. A hang holds the lock with a LIVE pid: the chain is
# dead forever and every guard designed for a crash sails straight past it.
make_chain s8; mutate '/^( sleep "\$TIMEOUT"/,+2d' '/WATCHDOG_PID/d' '/^wait "\$AGENT_PID"/d'; doctor
expect "T59  S8  no watchdog around the agent call" EXPOSED S8

# S9 — `08` is invalid octal to bash: the arithmetic dies, and under set -u so does the shell,
# before it can log why. One hour a day, for good.
make_chain s9; mutate 's|\$((10#\$(date +%H)))|$(date +%H)|'; doctor
expect "T60  S9  zero-padded hour used without 10#" EXPOSED S9

# S10 — the trigger's contents used as a number without being checked.
make_chain s10; mutate "/case \"\\\$DUE\" in/d"; doctor
expect "T61  S10  wakeup value used unvalidated" EXPOSED S10

# S11 — nothing caps how far ahead a wakeup may be: one millisecond epoch parks the chain for
# centuries, with no error anywhere and a scheduler that reports everything as fine.
make_chain s11; mutate '/MAX_AHEAD/d'; doctor
expect "T62  S11  no upper bound on the wakeup value" EXPOSED S11

# S12 — the invariant between two settings, which no single-value check can see.
make_chain s12; mutate 's|LOCK_MAX_AGE:=14400|LOCK_MAX_AGE:=3600|'; doctor
expect "T63  S12  stale-lock cutoff at or below the fallback delay" EXPOSED S12

# S13 — `:=` where `=` was meant: the operator who exports an empty value to disarm a
# permission bypass gets the bypass anyway, and is never told.
make_chain s13; mutate 's|BOT_ARGS=--quiet|BOT_ARGS:=--dangerously-skip-permissions|'; doctor
expect "T64  S13  security-relevant default armed with :=" EXPOSED S13

# S14, S15, S16 — the three whose reds are ABSENCES. Each gets two: one where the reading
# that gives the construction meaning is deleted (EXPOSED), and one where the CONSTRUCTION
# ITSELF is deleted (UNKNOWN). The second is the one that matters, and it exists because of a
# measured failure: on 2026-08-30 this tool returned a report identical line by line on a
# launcher carrying these three defects and on the same launcher repaired. A check that
# answers GUARDED — or says nothing — when it never found the thing it judges is the same
# lie in a different costume, and only the UNKNOWN tests can catch it.

# S14 — shape one: read and formatted in one expression, so there is no line on which the
# value could have been checked. `date -r 0` prints "Thu 01:00" instead of failing, which is
# how a dead chain writes a perfectly ordinary end-of-session line.
make_chain s14a
mutate '/^SHOWN_EPOCH=/d' '/^case "\$SHOWN_EPOCH"/d' \
       's|^SHOWN_TIME=.*|SHOWN_TIME=$(date -r "$(cat "$DUE_FILE" 2>/dev/null \|\| echo 0)" "+%a %H:%M" 2>/dev/null \|\| echo "?")|'
doctor
expect "T115 S14  the wakeup formatted straight out of the file" EXPOSED S14
# …shape two: the value goes through a variable, and nothing checks it on the way.
make_chain s14b; mutate '/^case "\$SHOWN_EPOCH"/d'; doctor
expect "T116 S14  the wakeup formatted from an unchecked variable" EXPOSED S14
# …and the absence: a launcher that never prints a wakeup as a time cannot be printing it
# wrong. UNKNOWN, never GUARDED — this is the check refusing to be green by default.
make_chain s14c; mutate '/^SHOWN_EPOCH=/d' '/^case "\$SHOWN_EPOCH"/d' '/^SHOWN_TIME=/d'; doctor
expect "T117 S14  a launcher that never formats an epoch → UNKNOWN, not GUARDED" UNKNOWN S14

# S15 — the exit code captured and never acted on. The fixture still LOGS it, deliberately:
# the log line is the defect, not the reading that excuses it.
make_chain s15a; mutate '/^if \[ "\$BOT_RC" -ne 0 \]/d'; doctor
expect "T118 S15  the agent's exit code logged and never used" EXPOSED S15
# The regression this one was written for: a word-boundary match on `exit` read
# `echo "… — exit $BOT_RC — …"` as a use of the value and answered GUARDED on the very
# launcher the whole measurement was built from. The address has to be the capture.
if printf '%s\n' "$OUT" | grep -A2 -E '^  EXPOSED +S15 ' | grep -q 'BOT_RC=\$?'; then
  ok "T119 S15  …and a log line SAYING 'exit' is not a use of the code"
else bad "T119 S15  …and a log line SAYING 'exit' is not a use of the code" \
  "$(printf '%s\n' "$OUT" | grep -A2 -E '^  EXPOSED +S15 ' | tail -n 1 | sed 's/^ *//')"; fi
# The absence: no capture at all is not a defect. A launcher that branches on the call itself
# (`if ! agent; then`) needs no variable, and this check cannot follow what was never stored.
make_chain s15b; mutate '/^if \[ "\$BOT_RC" -ne 0 \]/d' '/^BOT_RC=\$?$/d'; doctor
expect "T120 S15  no exit code captured at all → UNKNOWN, not GUARDED" UNKNOWN S15

# S16 — the spacing marker stamped only at the start. The fix is an ADDED write, never a moved
# one: a session that dies mid-run never reaches the end, and a missing marker is what loops
# the chain at every probe. So the red deletes the END write and leaves the startup one.
make_chain s16a; mutate '/^if \[ -n "\$SESSION_END" \]/d'; doctor
expect "T121 S16  the spacing marker only ever dates the start of the session" EXPOSED S16
# The absence, twice over: a marker nobody writes, and a marker nobody reads. Neither is a
# defect — a chain that does not pace itself has no pacing to break.
make_chain s16b; mutate '/^if \[ -n "\$SESSION_END" \]/d' '/^echo "\$NOW" > "\$STAMP"$/d'; doctor
expect "T122 S16  a marker nothing writes → UNKNOWN, not GUARDED" UNKNOWN S16
make_chain s16c; mutate '/^LAST_RUN=\$(cat "\$STAMP"/d' '/^if \[ -n "\$LAST_RUN" \]/d'; doctor
expect "T123 S16  a marker nothing paces on → UNKNOWN, not GUARDED" UNKNOWN S16
# …and the false positive this check shipped with for about an hour, found by pointing it at a
# launcher written in nobody's idiom: the end-of-session write lives in a helper DEFINED at the
# top of the file and CALLED at the end. Read literally, that write is on line 11 and the check
# said "only ever dates the start". Verified differentially, not by LEGACY: on the version
# before the fix this same fixture returned EXPOSED.
make_chain s16d
mutate 's|^: "\${MIN_SPACING:=900}"|: "${MIN_SPACING:=900}"\nfinish_session() { local e; e=$(date +%s); case "$e" in ""\|*[!0-9]*) e="" ;; esac; if [ -n "$e" ] \&\& [ "$e" -gt "$NOW" ]; then echo "$e" > "$STAMP"; fi; }|' \
       's|^if \[ -n "\$SESSION_END" \].*|finish_session|'
doctor
expect "T125 S16  a write inside a helper called at the end is not 'only at the start'" GUARDED S16
# And the positive side, the trap S5 fell into once (T111): a GUARDED whose evidence points at
# the value rather than at its protection cannot be falsified by reading — delete the guard and
# the report still cites a line that is still there.
make_chain s14g; doctor
if printf '%s\n' "$OUT" | grep -A2 -E '^  GUARDED +S14 ' | grep -q 'case "\$SHOWN_EPOCH"'; then
  ok "T124 S14  the GUARDED evidence is the address of the guard, not of the formatting"
else bad "T124 S14  the GUARDED evidence is the address of the guard, not of the formatting" \
  "$(printf '%s\n' "$OUT" | grep -A2 -E '^  GUARDED +S14 ' | tail -n 1 | sed 's/^ *//')"; fi

# =========================================================================================
# The audit of the day S14/S15/S16 were written. Nine verdicts were measured FALSE on chains
# written in nobody's idiom — five of them GUARDED with no protection at all, which is the
# worst thing this tool can print. Every one of them gets its fixture here, and every fixture
# is a LAUNCHER, not a mutation of mine: the defects were invisible to the suite precisely
# because the suite's fixtures and the checks have the same author.
# =========================================================================================

# foreign FILE-BODY — replace the fixture's launcher with a chain written in another idiom,
# keeping the sandbox's paths so nothing reads the machine running the tests.
foreign() {
  {
    printf '#!/bin/bash\nset -u\n'
    printf 'STATE="%s"\n' "$STATE"
    printf 'LOGFILE="$STATE/run.log"\nLOCKDIR="$STATE/run.lock"\n'
    printf 'NEXT_FILE="$STATE/run.next"\nLAST_FILE="$STATE/run.last"\nBRIEF="%s"\n' "$ROOT/bot/session-prompt.txt"
    printf 'NOW=$(date +%%s)\n'
    cat
  } > "$LAUNCHER"
}

echo
echo "-- the audit of S14/S15/S16: nine false verdicts, one fixture each"

# A1 — a `wait` BEFORE the agent (a backgrounded `git pull`, the commonest pre-flight there is)
# was taken as the divider between start and end of session, so the STARTUP stamp landed in the
# "after" bucket. GUARDED on a chain with no end-of-session write at all.
make_chain a1; foreign <<'EOF'
git -C /tmp status --short >> "$LOGFILE" 2>&1 &
wait
date +%s > "$LAST_FILE"
PREV=$(cat "$LAST_FILE" 2>/dev/null)
case "$PREV" in ''|*[!0-9]*) PREV="" ;; esac
[ -n "$PREV" ] && [ $(( NOW - PREV )) -lt 900 ] && exit 0
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
EOF
doctor
expect "T126 S16  a pre-flight 'wait' is not where the agent returns" EXPOSED S16

# A2 — with no `wait` at all the divider falls back to the agent invocation, and the loose
# variable pattern landed on `mkdir -p "$AGENT_HOME/state"` at the top of the file. Same false
# GUARDED, one fallback further down.
make_chain a2; foreign <<'EOF'
AGENT_HOME="$STATE/agent"
mkdir -p "$AGENT_HOME/state"
date +%s > "$LAST_FILE"
PREV=$(cat "$LAST_FILE" 2>/dev/null)
case "$PREV" in ''|*[!0-9]*) PREV="" ;; esac
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
EOF
doctor
expect "T127 S16  'mkdir \$AGENT_HOME' is not the agent invocation" EXPOSED S16

# A3 — the opposite error, and the more expensive one: a stamp written by an EXIT trap runs at
# the end BY DEFINITION, and is the most careful spelling of the fix (it survives a session
# killed mid-run). It was being reported as "only ever dates the START".
make_chain a3; foreign <<'EOF'
finish() { date +%s > "$LAST_FILE"; }
trap finish EXIT
PREV=$(cat "$LAST_FILE" 2>/dev/null)
case "$PREV" in ''|*[!0-9]*) PREV="" ;; esac
[ -n "$PREV" ] && [ $(( NOW - PREV )) -lt 900 ] && exit 0
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
EOF
doctor
expect "T128 S16  a stamp written by an EXIT trap is an end-of-session write" GUARDED S16

# A4 — `RC` reused: tested for the lock at the top, reassigned from the agent at the bottom.
# The use search started at line 1, so the lock's test excused the agent's unread code.
make_chain a4; foreign <<'EOF'
mkdir "$LOCKDIR" 2>/dev/null
RC=$?
if [ "$RC" -ne 0 ]; then exit 0; fi
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
RC=$?
echo "session over rc=$RC" >> "$LOGFILE"
EOF
doctor
expect "T129 S15  a use of the same name BEFORE the capture is not a use" EXPOSED S15

# A5 — the same lesson as T119, on the branch that had not received it: a bracket inside a log
# message. T119's fixture has no bracket, so the regression sailed under it.
make_chain a5; foreign <<'EOF'
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
BOT_RC=$?
echo "=== End [rc $BOT_RC] — next ===" >> "$LOGFILE"
EOF
doctor
expect "T130 S15  a bracket inside a log message is not a test" EXPOSED S15

# A6 — the only place one of these checks printed evidence that was literally false: EXPOSED
# with "no numeric-shape test on that value", on a launcher whose guard was spelled `[[ =~ ]]`
# — a form the guard finder did not search for. An instrument may not assert an absence it
# never looked for.
make_chain a6; foreign <<'EOF'
DUE=$(cat "$NEXT_FILE" 2>/dev/null)
if ! [[ "$DUE" =~ ^[0-9]+$ ]]; then DUE=$NOW; fi
SHOWN=$(date -r "$DUE" '+%a %H:%M')
echo "next $SHOWN" >> "$LOGFILE"
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
EOF
doctor
expect "T131 S14  a shape test spelled [[ =~ ]] is a shape test" GUARDED S14

# A7 — S37's lesson, rediscovered one window wider: the guard finder only required the variable
# to appear SOMEWHERE in a three-line window ending at the shape test. A launcher naming $DUE on
# one line and shape-testing $IDLE_RAW on the next earned GUARDED for $DUE.
make_chain a7; foreign <<'EOF'
IDLE_RAW=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF; exit}')
DUE=$(cat "$NEXT_FILE" 2>/dev/null)
[ -n "$DUE" ] || DUE=$NOW
case "$IDLE_RAW" in ''|*[!0-9]*) IDLE=0 ;; esac
SHOWN=$(date -r "$DUE" '+%a %H:%M')
echo "next $SHOWN" >> "$LOGFILE"
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
EOF
doctor
expect "T132 S14  a shape test on another variable does not validate this wakeup" EXPOSED S14

# A8 — two defects in one fixture. The wrapper detector read a fixed eight-line window from each
# function's DEFINITION, so a `log_it` helper sitting above a `date -r` helper was itself
# declared a time formatter — and then every `log_it …` line became a formatting site, including
# the one printing the raw epoch. And `hhmm ()`, with the space POSIX allows, matched no
# function pattern at all, so the real formatter was invisible.
make_chain a8; foreign <<'EOF'
log_it() {
  printf '%s\n' "$*" >> "$LOGFILE"
}

hhmm () {
  date -r "$1" '+%a %H:%M' 2>/dev/null || echo "?"
}
DUE=$(cat "$NEXT_FILE" 2>/dev/null)
case "$DUE" in ''|*[!0-9]*) DUE="$NOW" ;; esac
log_it "next raw: $(cat "$NEXT_FILE")"
log_it "next $(hhmm "$DUE")"
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
EOF
doctor
expect "T133 S14  a helper above a formatter is not a formatter, and 'name ()' is a function" GUARDED S14

# A9 — the report may not print bash's own error messages under itself. With no `NAME=$?`
# anywhere — the case S15 exists to answer UNKNOWN on — an empty here-doc ran the loop once on
# an empty line and `[ "" -ge N ]` complained on stderr.
make_chain a9; foreign <<'EOF'
DUE=$(cat "$NEXT_FILE" 2>/dev/null)
case "$DUE" in ''|*[!0-9]*) DUE="$NOW" ;; esac
timeout 3600 claude -p "$(cat "$BRIEF")" >> "$LOGFILE" 2>&1
EOF
export ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET"
a9err=$(bash "$DOCTOR" --verbose --plist "$PLIST" "$LAUNCHER" 2>&1 >/dev/null)
if [ -z "$a9err" ]; then ok "T134 S15  nothing is written to stderr when no exit code is captured"
else bad "T134 S15  nothing is written to stderr when no exit code is captured" "$(printf '%s' "$a9err" | head -n 1)"; fi

# The rule that makes the comment-stripping worth its lines: a launcher that quotes its own
# former bug in a comment beside the fix must NOT be reported for it. This is not theoretical —
# it is how the reference launcher is written, and four checks matched those comments before
# the code cache existed.
echo
echo "-- comments are not code"
make_chain scomment
{
  printf '# the old lock code was: mkdir "$GATE" || exit 0\n'
  printf '# and the age used to read: $(stat -f %%m "$GATE" || echo 0)\n'
  printf '# the trigger used to be written with: date +%%s > "$DUE_FILE"\n'
} >> "$LAUNCHER"
doctor
expect_no_exposed "T65  a launcher quoting its own former bugs in comments → still zero EXPOSED"

echo
echo "-- discovery leaves nothing of the entries it walked past"
# The regression that a first real run found and three readings had not. read_plist filled the
# scheduler globals for EVERY plist it opened while searching, and cleared only one of them
# when the candidate did not match. Pointed at a launcher whose plist is not in the search
# path, the tool printed "scheduler not identified" in its header and, three lines lower, two
# confident EXPOSED findings built on the error path and the PATH of an unrelated Mac updater
# it had walked past on its way. One missing reset, two false positives.
make_chain leak
FAKEAGENTS="$ROOT/LaunchAgents"; mkdir -p "$FAKEAGENTS"
sed -e "s|@ROOT@|$ROOT|g" > "$FAKEAGENTS/com.other.updater.plist" <<'OTHER_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.other.updater</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>@ROOT@/bot/nap-guard.sh</string></array>
  <key>StandardErrorPath</key><string>@ROOT@/UNRELATED-updater.log</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/nowhere</string></dict>
</dict>
</plist>
OTHER_EOF
export ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET" ACD_LAUNCHAGENTS_DIR="$FAKEAGENTS"
OUT=$(bash "$DOCTOR" --verbose "$LAUNCHER" 2>&1); RC=$?
unset ACD_LAUNCHAGENTS_DIR
if printf '%s\n' "$OUT" | grep -q 'UNRELATED-updater'; then
  bad "T66  an unmatched scheduler entry leaks nothing into the report" "$(printf '%s\n' "$OUT" | grep -n 'UNRELATED' | head -n 1)"
else ok "T66  an unmatched scheduler entry leaks nothing into the report"; fi
if printf '%s\n' "$OUT" | grep -qE '^  EXPOSED +L1[23]'; then
  bad "T67  no finding is built on an entry that was only walked past" "$(printf '%s\n' "$OUT" | grep -E '^  EXPOSED +L1[23]' | head -n 1)"
else ok "T67  no finding is built on an entry that was only walked past"; fi

echo
echo "-- the report's own rules"
make_chain rules; : > "$STATE/run.next"; doctor
if [ "$RC" -eq 1 ]; then ok "T40  exit code 1 when something is exposed"; else bad "T40  exit code 1 when something is exposed" "got $RC"; fi
# `grep -q` on a report of 29 findings answers "at least one", and the invariant in the title
# is "every". One finding carrying its [live]/[static] tag made the other twenty-five
# unmeasured — in the test that guards the report format. Counted both ways now.
n_head=$(printf '%s\n' "$OUT" | grep -cE '^  (EXPOSED|GUARDED|UNKNOWN) +[LS][0-9]+ ')
n_lvl=$(printf '%s\n' "$OUT" | grep -E '^  (EXPOSED|GUARDED|UNKNOWN) +[LS][0-9]+ ' | grep -cE ' \[(live|static)\]$')
if [ "$n_head" -eq 29 ] && [ "$n_lvl" -eq "$n_head" ]; then ok "T41  EVERY finding names its level of proof ($n_lvl/$n_head)"
else bad "T41  EVERY finding names its level of proof" "$n_lvl of $n_head verdict lines carry [live] or [static]"; fi
if ! printf '%s\n' "$OUT" | grep -qE '^  OK |[Aa]ll (is |looks )?(fine|good|well)|your chain is healthy'; then ok "T42  no fourth verdict, no reassuring summary"
else bad "T42  no fourth verdict, no reassuring summary"; fi
if printf '%s\n' "$OUT" | grep -q '\[ask\] five things'; then ok "T43  the questions no inspection can answer are printed"
else bad "T43  the questions no inspection can answer are printed"; fi

# Evidence is not optional: every EXPOSED must be followed by at least one indented line.
n_ev=$(printf '%s\n' "$OUT" | awk '/^  EXPOSED/ { e++; getline; if ($0 ~ /^ {18,}/) g++ } END { print (e > 0 && e == g) ? "ok" : "no" }')
if [ "$n_ev" = "ok" ]; then ok "T44  every EXPOSED carries its evidence"
else bad "T44  every EXPOSED carries its evidence"; fi

# A chain the tool cannot find must say so, not report an empty and reassuring page.
OUT=$(bash "$DOCTOR" "$WORK/does-not-exist.sh" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q 'is not a file'; then ok "T45  a missing launcher is an error, not an empty report"
else bad "T45  a missing launcher is an error, not an empty report" "rc=$RC"; fi

# The two refusals. A tool that answers confidently about something it has not identified is
# the failure this whole design is aimed at, and the first real run produced exactly that: a
# compiled Mac application scored 5/5 on the marker filter and got a finding written about it.
printf '\x7fELF-not-really-but-not-a-script\n' > "$WORK/binary.bin"
OUT=$(bash "$DOCTOR" "$WORK/binary.bin" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "not binaries"; then ok "T49  a file that is not a #! script is refused, not diagnosed"
else bad "T49  a file that is not a #! script is refused, not diagnosed" "rc=$RC"; fi

printf '#!/bin/bash\necho hello\nsleep 1\n' > "$WORK/plain.sh"
OUT=$(bash "$DOCTOR" "$WORK/plain.sh" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q 'not like an agent chain'; then ok "T50  a script with no control files is refused, not diagnosed"
else bad "T50  a script with no control files is refused, not diagnosed" "rc=$RC: $(printf '%s\n' "$OUT" | head -n 3 | tr '\n' ' ')"; fi

OUT=$(bash "$DOCTOR" --help 2>&1); RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'read-only'; then ok "T46  --help works and says the tool is read-only"
else bad "T46  --help works and says the tool is read-only" "rc=$RC"; fi

# Default output lists GUARDED and UNKNOWN without their evidence; --verbose adds it. Hiding
# what went well is also a way of lying about coverage, so they are never dropped.
make_chain verb; doctor; verbose_lines=$(printf '%s\n' "$OUT" | wc -l)
export ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET"
OUT=$(bash "$DOCTOR" --plist "$PLIST" "$LAUNCHER" 2>&1)
default_lines=$(printf '%s\n' "$OUT" | wc -l)
if [ "$default_lines" -lt "$verbose_lines" ] && printf '%s\n' "$OUT" | grep -qE '^  GUARDED'; then
  ok "T47  default lists GUARDED/UNKNOWN, --verbose adds their evidence"
else bad "T47  default lists GUARDED/UNKNOWN, --verbose adds their evidence" "default=$default_lines verbose=$verbose_lines"; fi

echo
echo "-- every check reports, whatever the chain looks like"
# Written after three cold readers, and after pointing the tool at a hand-built chain, all
# found the same hole from different angles. The three fixtures below are the three shapes
# that used to lose a check: a correct chain, a chain at rest (no lock at all), and a chain
# whose lock is held by a pid that no longer exists.
# These three labels used to name the count: "all 26 checks", "all 26", "all 29". The
# catalogue went from 26 to 29 and exactly one of the three was updated — the other two kept
# announcing 26 for five days, in the output of the suite that was asserting 29 four lines
# below. Which two rotted is not random: the surviving literal is the one in
# expect_full_catalogue, on the line above its own comparison. A count 900 lines from the
# assertion it describes is prose, and prose is what rots. So the number is gone from the
# labels — expect_full_catalogue holds it once, next to the test that uses it, and prints the
# real total when it fails.
make_chain clean; doctor
expect_full_catalogue "T68  a correct chain reports every check, once each"
make_chain sclean; doctor
expect_full_catalogue "T69  a chain at rest, with no lock on disk, still reports them all"
make_chain l7; doctor
expect_full_catalogue "T70  a chain whose lock owner is dead still reports them all"
# The counters printed at the foot of the report must agree with the lines above them.
n_e=$(printf '%s\n' "$OUT" | grep -cE '^  EXPOSED')
n_g=$(printf '%s\n' "$OUT" | grep -cE '^  GUARDED')
n_u=$(printf '%s\n' "$OUT" | grep -cE '^  UNKNOWN')
if printf '%s\n' "$OUT" | grep -qE "^  $n_e exposed · $n_g guarded · $n_u unknown\$" \
   && [ $((n_e + n_g + n_u)) -eq 29 ]; then ok "T71  the counters match the lines and add up to 29"
else bad "T71  the counters match the lines and add up to 29" \
  "counted $n_e/$n_g/$n_u, footer: $(printf '%s\n' "$OUT" | grep -E 'exposed ·' | head -n 1 | sed 's/^ *//')"; fi
# ---------------------------------------------------------------------------------------
# T71b — and the SENTENCE has to name the same number as the counters.
#
# T71 above proves the three counters agree with the lines they summarise. It says nothing
# about the closing paragraph, which is the last thing a user reads and the one line that
# tells them how much ground was covered: "these N checks found nothing". That N was a
# literal `26` in the source while 29 checks ran and the line directly above it printed
# 0+23+6. Two numbers, one report, one of them written by hand — and the hand-written one
# was the one making the claim.
#
# The rule this pins down: a count the product PRINTS is a count the suite must recompute.
# Comparing it to the catalogue read from the tool's own source (never to a literal here —
# that would only move the hand-kept number into the test) is what makes it un-stale-able.
n_cat=$(grep -cE '^check_[LS][0-9]+_[a-z_0-9]+\(\) \{$' "$DOCTOR")
n_said=$(printf '%s\n' "$OUT" | sed -nE 's/.*"these ([0-9]+) checks found nothing".*/\1/p' | head -n 1)
if [ -n "$n_said" ] && [ "$n_said" = "$n_cat" ]; then
  ok "T71b the closing sentence names the catalogue size, not a literal"
else bad "T71b the closing sentence names the catalogue size, not a literal" \
  "the report says ${n_said:-<no such sentence>}, the tool defines $n_cat checks"; fi
# T71c — the other published count in this tool, guarded before it drifts rather than after.
# Discovery prints a recognition score as "N/5", and the denominator is a literal sitting in
# the printf while the numerator comes from counting greps in the same function. That is the
# exact coupling that made T71b necessary: one number computed, one written by hand, in one
# sentence. It has not drifted yet — the sixth marker has not been added. When it is, this
# says so on the same run rather than five days later. Its red proof is a build whose
# denominator and grep count disagree; see the session note that introduced it.
#
# It reads EVERY "/N" in the function, not only the one in the printf: the signature comment
# carries the same denominator a line earlier, and two hand-written copies of one number are
# how the sentence T71b guards came to disagree with the counter above it. A THIRD copy sat in
# the CHAIN header's fallback, `${MARKER_SCORE:-?/5}`, nine hundred lines from here and outside
# any function this case can scope to — it was deleted rather than guarded, which is the honest
# answer when a published number informs no decision. Stated limit, on
# the kit's own rule: the prose above markers_of says "Five markers" in letters, and a total
# spelled out below ten stays legal — so this case does not read it. If markers ever reach
# ten, that word is a total in letters, and the kit's guard already refuses those.
mk_body=$(awk '/^markers_of\(\)/,/^\}$/' "$DOCTOR")
n_greps=$(printf '%s\n' "$mk_body" | grep -cE '^[[:space:]]+grep -q')
denoms=$(printf '%s\n' "$mk_body" | grep -oE '/[0-9]+' | tr -d '/' | sort -u | tr '\n' ' ')
if [ "$denoms" = "$n_greps " ]; then
  ok "T71c the marker score is printed out of the number of markers actually tested"
else bad "T71c the marker score is printed out of the number of markers actually tested" \
  "denominators found: ${denoms:-<none>}; markers_of runs $n_greps greps"; fi

echo
echo "-- evidence is folded, never cut mid-word"
# The tool's own consequence lines are longer than the old 100-character hard cut, so reports
# ended on "leaves an EMPTY " and "the launcher declares no". Found by reading the output of a
# real run, not the code. The check is on the tool's LONGEST sentence, whole and unbroken.
make_chain s1
printf 'date +%%s > "$DUE_FILE"\n' >> "$LAUNCHER"
doctor
if printf '%s\n' "$OUT" | tr '\n' ' ' | tr -s ' ' \
   | grep -q 'a command that fails leaves an EMPTY trigger'; then
  ok "T72  a long evidence sentence survives whole"
else bad "T72  a long evidence sentence survives whole" \
  "$(printf '%s\n' "$OUT" | grep -i 'truncates before' | head -n 1 | sed 's/^ *//')"; fi
# And no line may end in the middle of a word without saying so. An ellipsis is allowed —
# a silent stop is not.
if ! printf '%s\n' "$OUT" | grep -qE '^ {20}.{95,}[^…]$'; then
  ok "T73  no evidence line runs to the old hard cut without an ellipsis"
else bad "T73  no evidence line runs to the old hard cut without an ellipsis" \
  "$(printf '%s\n' "$OUT" | grep -E '^ {20}.{95,}[^…]$' | head -n 1)"; fi

echo
echo "-- a freshly installed chain is not accused of being dead"
# Found by installing the reference launcher for real, at rest, and watching the tool call a
# ten-minute-old correct install EXPOSED. No log + a wakeup still ahead + a healthy probe is a
# chain WAITING. The same absence with an overdue wakeup is the real failure, and stays red.
make_chain fresh; rm -f "$STATE/run.log"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$STATE/run.next"
doctor
expect "T78 L2  no log yet, next wakeup ahead, probe healthy → not EXPOSED" UNKNOWN L2
make_chain l2d; rm -f "$STATE/run.log"
printf '%s\n' "$(( $(date +%s) - 3600 ))" > "$STATE/run.next"
doctor
expect "T79 L2  no log and the wakeup already past → still EXPOSED" EXPOSED L2


# A chain whose files live under a directory called "nextcloud" must not have every one of its
# control files classified as the wakeup file. The classifier reads the variable name and the
# last two path segments, never the whole path. Found by naming a fixture "overdue".
make_chain nextcloud/agent 2>/dev/null || true
doctor
if printf '%s\n' "$OUT" | grep -qE "state dir +$STATE\$"; then
  ok "T80  an ancestor directory named 'next' does not hijack the classification"
else bad "T80  an ancestor directory named 'next' does not hijack the classification" \
  "$(printf '%s\n' "$OUT" | grep 'state dir' | sed 's/^ *//')"; fi

echo
echo "-- a mistyped command line is refused, not answered"
# Every one of these used to be accepted in silence and produce a confident report about a
# chain the user had not named. A diagnostic that answers the wrong question is worse than one
# that refuses to answer.
OUT=$(bash "$DOCTOR" --plist 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q 'needs a file path'; then
  ok "T74  --plist with no value is refused"
else bad "T74  --plist with no value is refused" "rc=$RC"; fi
make_chain clean
OUT=$(bash "$DOCTOR" "$LAUNCHER" "$LAUNCHER" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q 'two launchers given'; then
  ok "T75  two launchers on the command line are refused"
else bad "T75  two launchers on the command line are refused" "rc=$RC"; fi

# `--plist FILE` alone is the documented escape hatch when discovery misses the chain. It used
# to be dropped: discovery ran anyway and reported on whatever else it found, at exit 0. Here
# the agents directory is pointed at an EMPTY folder, so discovery cannot succeed — if the
# plist is honoured, the launcher it names is diagnosed; if it is ignored, there is no chain.
make_chain clean
mkdir -p "$WORK/no-agents"
OUT=$(ACD_LAUNCHAGENTS_DIR="$WORK/no-agents" ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET" \
      bash "$DOCTOR" --plist "$PLIST" 2>&1); RC=$?
if printf '%s\n' "$OUT" | grep -qF "launcher    $LAUNCHER"; then
  ok "T76  --plist alone diagnoses the launcher the plist names"
else bad "T76  --plist alone diagnoses the launcher the plist names" \
  "rc=$RC ; $(printf '%s\n' "$OUT" | grep -E 'launcher|No agent chain' | head -n 1 | sed 's/^ *//')"; fi
OUT=$(ACD_LAUNCHAGENTS_DIR="$WORK/no-agents" bash "$DOCTOR" --plist "$WORK/nope.plist" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q 'could not be read as a LaunchAgent plist'; then
  ok "T77  a --plist that cannot be read is refused, not silently ignored"
else bad "T77  a --plist that cannot be read is refused, not silently ignored" "rc=$RC"; fi

echo
echo "-- exp-008: the six defects that only foreign chains could show"
# Every case below was found by pointing this tool at agent chains written by four authors who
# had never seen its code, its name, or its list of checks (exp-008, 2026-08-29). None of them
# was visible on the 93 cases above, and those 93 passed before and after: their fixtures are
# written by the author of the checks, in the author's idiom, with the author's assignment
# conventions. A suite written by the author measures the author's consistency.

# F-A — `readonly NAME=…` is ordinary bash, and it made this tool refuse a whole chain: the
# name parsed as "readonly NAME", which contains a space, so every declaration was dropped and
# the tool answered "looks like a script, but not like an agent chain" at exit 2. Zero of the
# twenty-six checks ran. This is the idiom-dependence the experiment went looking for, and it
# was total, not partial.
make_chain fa
mutate 's|^RUNLOG=|readonly RUNLOG=|' \
       's|^GATE=|readonly GATE=|' \
       's|^DUE_FILE=|readonly DUE_FILE=|' \
       's|^: "..BOT_BRIEF:=\(.*\)}"$|readonly BOT_BRIEF="\1"|'
doctor
expect_full_catalogue "T81  control paths declared with 'readonly' are found, not refused"
expect "T82 L2  the log declared with 'readonly' is read, not missed" GUARDED L2

# F-B — an EMPTY positional argument fell through to discovery and produced a confident report
# about a DIFFERENT chain, at exit 0. Word for word the defect fixed for --plist in S32, whose
# comment still says "the user who mistyped the path got a confident diagnosis of a chain they
# had not named" — fixed for the option, never for the positional argument the README
# recommends. Found because a measurement loop expanded an unset variable into the command line.
OUT=$(bash "$DOCTOR" "" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q 'launcher path is empty'; then
  ok "T83  an empty launcher argument is refused, not answered with another chain"
else bad "T83  an empty launcher argument is refused, not answered with another chain" \
  "rc=$RC ; $(printf '%s\n' "$OUT" | grep -E 'launcher |No agent chain' | head -n 1 | sed 's/^ *//')"; fi

# F-C — S9 accused a `test` comparison of being octal arithmetic. `[ 08 -ge 3 ]` compares in
# DECIMAL: only $(( )), (( )), let, declare -i and [[ x -ge y ]] evaluate arithmetically. The
# printed evidence described an arithmetic that existed nowhere in the script. This false
# positive was NAMED IN ADVANCE in the sealed classification, and it happened.
make_chain s9t
mutate 's|\$((10#\$(date +%H)))|$(date +%H)|' 's|^ *WINDOW_LEFT=\$((.*|WINDOW_LEFT=1|'
doctor
expect "T84  S9  a zero-padded hour only ever compared with test(1) is not octal" GUARDED S9

# F-D(1) — `timeout "$SESSION_TIMEOUT" agent …` was not recognised as a bound, because the
# pattern demanded a digit or a $ straight after the space and got a double quote. S8 is the
# check you run when you suspect a hung agent: a false EXPOSED there is the worst possible.
make_chain s8q
mutate '/^( sleep "\$TIMEOUT"/,+2d' '/WATCHDOG_PID/d' '/^wait "\$AGENT_PID"/d' \
       's|"\$BOT_CLI" -p|timeout "$TIMEOUT" "$BOT_CLI" -p|g'
doctor
expect "T85  S8  timeout(1) with a quoted variable duration is a bound" GUARDED S8

# F-D(2) — when S8 does fire, its evidence pointed at the first line MENTIONING the agent,
# which on two of the four foreign chains was a `command -v agent` existence guard, and on this
# fixture is the declaration. An accusation carrying the wrong address is not an accusation.
make_chain s8ev
mutate '/^( sleep "\$TIMEOUT"/,+2d' '/WATCHDOG_PID/d' '/^wait "\$AGENT_PID"/d' \
       's|^IDLE_RAW=|command -v "$BOT_CLI" >/dev/null 2>\&1 \|\| exit 0\necho "no $BOT_CLI on PATH" >> "$RUNLOG"\nIDLE_RAW=|'
WANT=$(grep -n '^  *"\$BOT_CLI" -p\|^ *caffeinate -i "\$BOT_CLI"' "$LAUNCHER" | head -n 1 | cut -d: -f1)
doctor
if printf '%s\n' "$OUT" | grep -A2 '^  EXPOSED  S8' | grep -q ":${WANT}:"; then
  ok "T86  S8  the evidence is the line that RUNS the agent, not a guard or a declaration"
else bad "T86  S8  the evidence is the line that RUNS the agent, not a guard or a declaration" \
  "wanted line $WANT ; got: $(printf '%s\n' "$OUT" | grep -A2 '^  EXPOSED  S8' | sed -n 2p | sed 's/^ *//')"; fi

# I-033 — the variable holding the agent binary was only recognised SPELLED IN CAPITALS. The
# name pattern is `[A-Za-z_]*(CLI|CMD|BIN|AGENT)[A-Za-z_]*`, which reads as case-insensitive and
# is not: the alternation is uppercase-only. A launcher writing `claude_bin="$(command -v
# claude)"` then `"$claude_bin" -p …` — lowercase, the ordinary shell convention for a local —
# has no invocation found at all, so S8, S16 and everything else downstream of agent_invocation
# answer UNKNOWN. Found on `yvoolab/claude-code-cron`, a third-party chain of exactly the form
# this tool advertises: a runner.sh under cron. Its report was 29 UNKNOWN out of 29 — and its
# `claude -p` is genuinely unbounded, so the one verdict it had earned was the one it withheld.
# The existence guard `command -v claude` is correctly skipped, which is why nothing caught it.
make_chain s8lower
mutate '/^( sleep "\$TIMEOUT"/,+2d' '/WATCHDOG_PID/d' '/^wait "\$AGENT_PID"/d' \
       's|BOT_CLI|claude_bin|g'
doctor
expect "T215 S8  the agent variable is found when it is spelled in lower case" EXPOSED S8

# …and the exclusion list that keeps `$BOT_HOME` and `$AGENT_PID` from being read as binaries
# has to travel with it: made case-insensitive on the match side only, `$bot_home` would become
# "the line that runs the agent" and the accusation would carry an address at which nothing is
# launched — the exact defect F-D(2) fixed, reintroduced through the other door.
make_chain s8lowerdir
mutate '/^( sleep "\$TIMEOUT"/,+2d' '/WATCHDOG_PID/d' '/^wait "\$AGENT_PID"/d' \
       's|BOT_CLI|agent_exe|g' 's|BOT_HOME|bot_home|g'
WANT=$(grep -n '^ *"\$agent_exe" -p\|^ *caffeinate -i "\$agent_exe"' "$LAUNCHER" | head -n 1 | cut -d: -f1)
doctor
if printf '%s\n' "$OUT" | grep -A2 '^  EXPOSED  S8' | grep -q ":${WANT}:"; then
  ok "T216 S8  a lower-case \$bot_home is still not the line that runs the agent"
else bad "T216 S8  a lower-case \$bot_home is still not the line that runs the agent" \
  "wanted line $WANT ; got: $(printf '%s\n' "$OUT" | grep -A2 '^  EXPOSED  S8' | sed -n 2p | sed 's/^ *//')"; fi

# F-E — L5 printed "overdue by 28 h" as its evidence UNDER the label "next wakeup is within a
# sane range". A wakeup due 28 hours ago is the silent death this tool exists to name; verdict
# and proof contradicted each other inside the same finding.
make_chain l5c
printf '%s\n' "$(( $(date +%s) - 100800 ))" > "$STATE/run.next"
doctor
expect "T87  L5  a wakeup overdue by 28 h is not 'a sane range'" UNKNOWN L5
# …and the correction must not swing the other way: a scheduler that ticks every few minutes
# leaves a just-due wakeup on disk all the time, and that is a chain working, not a chain dead.
make_chain l5d
printf '%s\n' "$(( $(date +%s) - 300 ))" > "$STATE/run.next"
doctor
expect "T88  L5  a wakeup due five minutes ago is still healthy" GUARDED L5

# F-G — L4 called "not a bare integer" a defect, which is this tool's own convention taken for
# a law. A foreign chain wrote three `key=value` lines into its wakeup file — a documented
# format, re-triggered by its systemd timer, that the launcher never parses — and was told it
# "stops for good without a line". This false positive was NAMED IN ADVANCE in the sealed
# classification, and it only surfaced once F-A stopped refusing that chain outright.
make_chain l4kv
printf 'next_wakeup_epoch=%s\nnext_wakeup_human=tomorrow\n' "$(( $(date +%s) + 3600 ))" > "$STATE/run.next"
mutate '/^DUE=\$(cat "\$DUE_FILE"/d' '/^case "\$DUE" in/d' '/^if \[ "\$DUE" -gt/d' '/^\[ "\$NOW" -lt "\$DUE" \]/d' \
       '/^SHOWN_EPOCH=/d' '/^case "\$SHOWN_EPOCH"/d' '/^SHOWN_TIME=/d'
doctor
expect "T90  L4  a structured wakeup file no launcher reads is not a defect" UNKNOWN L4
# …and when the launcher DOES read it as a number, the accusation stands, with the read as proof.
make_chain l4kv2
printf 'next_wakeup_epoch=%s\n' "$(( $(date +%s) + 3600 ))" > "$STATE/run.next"
doctor
expect "T91  L4  the same file, read as a number, is still EXPOSED" EXPOSED L4

# F-H — L12's fallback ("then for a known agent CLI called by name") could not fire on macOS:
# it extracted the name with a BRE `\|` alternation, which BSD sed does not support and
# silently matches nothing. Every one of the four foreign chains names its agent in plain text,
# and all four were told "no agent binary name found in the launcher" — a message describing a
# search that had not happened. On a tool whose pitch is "bash 3.2, no dependency, runs on
# someone else's machine", a portability bug that disables a check in silence is the worst kind.
make_chain l12n
mutate 's|BOT_CLI|BOT_RUNNER|g' 's|"\$BOT_RUNNER" -p|aider -p|g'
doctor
expect "T92  L12 an agent named in plain text, with no variable, is still found" EXPOSED L12

# F-I — the same root as F-D(2), and it reaches further than S8: a MENTION inside a message is
# not a use. On a foreign chain the only shell line naming the wakeup file was
# `log "amorcage: prochain reveil a $(cat "$NEXT_FILE")"` — the comparison happens inside a
# python helper — and S10 and S11 both built accusations on it, S10 claiming the value "then
# fails inside the comparison" about a line that compares nothing.
make_chain s10log
mutate '/^DUE=\$(cat "\$DUE_FILE"/d' '/^case "\$DUE" in/d' '/^if \[ "\$DUE" -gt/d' \
       '/^\[ "\$NOW" -lt "\$DUE" \]/d' \
       '/^SHOWN_EPOCH=/d' '/^case "\$SHOWN_EPOCH"/d' '/^SHOWN_TIME=/d' \
       's|^NOW=\$(date +%s)|NOW=$(date +%s)\necho "next wake $(cat "$DUE_FILE")" >> "$RUNLOG"|'
doctor
expect "T93  S10 a wakeup value that is only ever printed is not 'used as a number'" UNKNOWN S10
expect "T94  S11 …and there is no numeric read to bound either" UNKNOWN S11

# F-F — a control path built from a variable only the SCHEDULER supplies resolved to the
# launcher's literal default, which does not exist, and became two flat accusations. The tool
# cannot see that environment unless it is handed the plist; a value it could not resolve is an
# UNKNOWN, never an EXPOSED.
make_chain prov
mutate 's|BOT_BRIEF:=\$BOT_HOME/session-prompt.txt|BOT_BRIEF:=${ACD_NOT_SET_ANYWHERE:-/nonexistent-supplied}/session-prompt.txt|'
doctor
expect "T89 L11  a path from a variable only the scheduler supplies is UNKNOWN, not an accusation" UNKNOWN L11

# L12 / S7 — the launcher's OWN PATH. A launcher that exports its own PATH before calling the
# agent has applied the documented fix for the very failure mode L12 names; a check that reads
# only the scheduler's PATH accuses it anyway. Found by running the tool on a live, working
# chain and being told its agent "exits 127 at every session, forever" — in a report that the
# running session was producing, three lines above L1 GUARDED "the probe's last run exited 0".
make_chain l12c
sed -i.bak "s|<string>$ROOT/bin:/usr/bin:/bin</string>|<string>/usr/bin:/bin</string>|" "$PLIST" && rm -f "$PLIST.bak"
mutate "s|^NOW=\$(date +%s)|export PATH=\"$ROOT/bin:/usr/bin:/bin\"\nNOW=\$(date +%s)|"
doctor
expect "T95  L12 the launcher exports its own PATH and the agent resolves there" GUARDED L12

# The shape of a real chain: the PATH is a default behind a variable the scheduler MAY export.
# The default is still what the chain runs with when nothing overrides it, so the verdict is
# GUARDED with the reserve printed — not an accusation built on a value the tool guessed.
make_chain l12d
sed -i.bak "s|<string>$ROOT/bin:/usr/bin:/bin</string>|<string>/usr/bin:/bin</string>|" "$PLIST" && rm -f "$PLIST.bak"
mutate "s|^NOW=\$(date +%s)|export PATH=\"\${BOT_PATH:-$ROOT/bin:/usr/bin:/bin}\"\nNOW=\$(date +%s)|"
doctor
expect "T96  L12 a PATH exported behind a \${VAR:-default} still resolves the agent" GUARDED L12
# Joined before matching: the evidence is word-wrapped at EV_WIDTH, so a multi-word grep on
# the raw report is a test that fails on the column width instead of on the behaviour.
if printf '%s\n' "$OUT" | tr '\n' ' ' | tr -s ' ' | grep -q "GUARDED L12 .* could override it"; then
  ok "T97  L12 …and the report carries the reserve instead of hiding it"
else
  bad "T97  L12 …and the report carries the reserve instead of hiding it" "no reserve printed under L12"
fi

# A launcher that APPENDS to what the scheduler handed it must be read, not refused: the
# literal '$PATH' segment is resolved from the scheduler entry rather than searched as a
# directory named '$PATH'.
make_chain l12e
sed -i.bak "s|<string>$ROOT/bin:/usr/bin:/bin</string>|<string>/usr/bin:/bin</string>|" "$PLIST" && rm -f "$PLIST.bak"
mutate "s|^NOW=\$(date +%s)|export PATH=\"$ROOT/bin:\$PATH\"\nNOW=\$(date +%s)|"
doctor
expect "T98  L12 a launcher that appends to the scheduler PATH is read, not refused" GUARDED L12

# Same blind spot, second check: S7 resolves the keep-awake wrapper through the same helper.
# It never fired in the wild only because `caffeinate` lives in /usr/bin, which is in launchd's
# default PATH — the false positive was latent, not absent.
# BOTH PATHs are emptied of /usr/bin, the scheduler's and the launcher's: on a Mac the real
# /usr/bin/caffeinate resolves through either of them, and the test would pass for a reason
# that has nothing to do with the defect. It did — twice. First through the scheduler PATH
# (caught by the red phase), then through the launcher PATH the fix had just taught the tool
# to read (caught by a cold reader, in the same session, on the corrected version).
make_chain s7path
mkdir -p "$ROOT/empty"
sed -i.bak "s|<string>$ROOT/bin:/usr/bin:/bin</string>|<string>$ROOT/empty</string>|" "$PLIST" && rm -f "$PLIST.bak"
printf '#!/bin/bash\nexec "$@"\n' > "$ROOT/bin/caffeinate"; chmod +x "$ROOT/bin/caffeinate"
mutate '/^if command -v caffeinate/d' '/^else$/,/^fi$/d' \
       's|^  caffeinate -i|caffeinate -i|' \
       "s|^NOW=\$(date +%s)|export PATH=\"$ROOT/bin\"\nNOW=\$(date +%s)|"
doctor
expect "T99  S7  an unconditional wrapper found only on the launcher's own PATH is GUARDED" GUARDED S7

# L10 — an EMPTY sleep history is not "zero sleeps". awk runs its END block on empty input,
# so the counter printed 0 and the check took the GUARDED branch: on every machine without
# pmset — all of Linux — L10 answered "no sleep transition inside the work window" and printed
# "0 sleeps over the last 7 days" as the proof of a reading that never happened.
make_chain l10empty
: > "$PMSET"
doctor
expect "T100 L10 an empty sleep history is UNKNOWN, not a manufactured GUARDED" UNKNOWN L10

# L10 — the work window was validated on the CONCATENATION of its two bounds, so a launcher
# declaring only one of them produced "between :00 and 19:00 (declared by the launcher)".
make_chain l10half
mutate '/^: "\${WEEKDAY_CLOSED_END:=17}"/d'
doctor
if printf '%s\n' "$OUT" | tr '\n' ' ' | tr -s ' ' | grep -q "declares none this tool can use"; then
  ok "T101 L10 a half-declared work window falls back instead of printing 'between :00 and'"
else
  bad "T101 L10 a half-declared work window falls back instead of printing 'between :00 and'" \
      "$(printf '%s\n' "$OUT" | grep -E '^  [A-Z]+ +L10' | head -n 1 | sed 's/^ *//')"
fi

# S2/S3 — `trap - EXIT INT TERM` removes handlers, it does not install one. It used to be
# read as a handler whose body ('-') contains no exit, so a standard cleanup idiom was
# accused of "releasing and letting the script continue" — while the same line counted as
# INT/TERM coverage for S2. One line, GUARDED and EXPOSED at once.
make_chain trapdash
printf 'trap - EXIT INT TERM\n' >> "$LAUNCHER"
doctor
expect "T102 S3  'trap -' removes a handler and is not one" GUARDED S3

# The same trap, spelled SIGTERM/SIGINT and spelled numerically. Both are the trap the check
# is looking for; neither matched, so both were reported as "every trap covers EXIT only".
make_chain trapsig
mutate "s|^trap 'release; exit 143' TERM INT HUP|trap 'release; exit 143' SIGTERM SIGINT SIGHUP|"
doctor
expect "T103 S2  a trap spelled SIGTERM is the same trap as TERM" GUARDED S2
make_chain trapnum
mutate "s|^trap 'release; exit 143' TERM INT HUP|trap 'release; exit 143' 15 2 1|"
doctor
expect "T104 S2  a trap spelled with signal numbers is read too" GUARDED S2

echo
echo "-- exp-010 S2: the queue the S37 audit verified and left standing"
# Every case below reproduces a defect that three cold auditors located in this repo and that
# the previous session wrote down without fixing. Each was seen RED on the tool as it stood
# before this session, by checking out the previous commit and running exactly these lines.

# B1 — L2 read "no scheduler entry was matched" as "the probe exited 0", and printed that as
# its evidence, in a report whose L1 said the exit code was not readable. `${SCHED_STATUS:-0}`.
make_chain b1; rm -f "$STATE/run.log"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$STATE/run.next"
mkdir -p "$WORK/no-agents"
OUT=$(ACD_LAUNCHAGENTS_DIR="$WORK/no-agents" ACD_PMSET_LOG="$PMSET" \
      bash "$DOCTOR" --verbose "$LAUNCHER" 2>&1); RC=$?
if printf '%s\n' "$OUT" | grep -q "the probe's last run exited 0"; then
  bad "T105 L2  an unmeasured exit code is not evidence that the probe exited 0" \
      "$(printf '%s\n' "$OUT" | grep -n "exited 0" | head -n 1)"
else ok "T105 L2  an unmeasured exit code is not evidence that the probe exited 0"; fi
expect "T106 L2  …and the fresh-chain protection still holds without it" UNKNOWN L2

# B4 — src_line dropped WHOLE-LINE comments and kept trailing ones, so a `# was: mkdir "$GATE"`
# at the end of a live line armed L6's "the launcher creates this with mkdir". Three live
# checks read the launcher through src_line; the invariant was held by load_code alone.
make_chain b4
mutate 's|^if ! mkdir "$GATE" 2>/dev/null; then|if ! : "$GATE" 2>/dev/null; then  # was: mkdir "$GATE"|'
printf '' > "$STATE/run.lock"
doctor
expect "T107 L6  a trailing comment mentioning mkdir does not arm the lock-shape accusation" UNKNOWN L6

# B3 — S8 accepted a LOG LINE as proof that the agent is bounded. The call site six lines
# above had already been hardened against exactly this (code_first_running); the timeout
# lookup had not.
make_chain b3
mutate 's|^( sleep "$TIMEOUT"|( : "$TIMEOUT"|' \
       's|^wait "$AGENT_PID"|echo "timeout 900 reached, killing the agent" >> "$RUNLOG"\
wait "$AGENT_PID"|'
doctor
expect "T108 S8  a log line saying 'timeout' is not a watchdog" EXPOSED S8

# C1 — S5 and S6 earned GUARDED from a numeric-shape test found ANYWHERE in the launcher.
# Here the guard each one claims to see is deleted, and another variable's shape test is left
# untouched: the old code stayed GUARDED, and printed the address of the UNPROTECTED read.
make_chain c1a
mutate 's|^  case "$GATE_MTIME" in.*|  GATE_AGE=$(( NOW - GATE_MTIME ))|'
doctor
expect "T109 S5  a shape test on another variable does not validate this timestamp" UNKNOWN S5
make_chain c1b
mutate 's|^case "$IDLE_RAW" in.*|IDLE=$(( IDLE_RAW / 1000000000 ))|'
doctor
expect "T110 S6  a shape test on another variable does not validate the idle probe" UNKNOWN S6
# …and the positive side: on the correct launcher the evidence must now be the address of the
# PROTECTION, not of the value it protects. Without this the fix could pass by never firing.
make_chain c1c; doctor
if printf '%s\n' "$OUT" | grep -A3 -E '^  GUARDED +S5 ' | grep -q 'case "$GATE_MTIME"'; then
  ok "T111 S5  the GUARDED evidence is the address of the guard, not of the value"
else bad "T111 S5  the GUARDED evidence is the address of the guard, not of the value" \
  "$(printf '%s\n' "$OUT" | grep -A2 -E '^  GUARDED +S5 ' | tail -n 2 | tr '\n' ' ')"; fi

# C9 — T21/T22 put `$$` in the lock, so L8 measured the age of the TEST SUITE. The `sleep 2`
# was decorative and T22 was green only because the suite had been running less than four
# hours. Same child process, same elapsed time, two budgets, two opposite verdicts: now the
# budget is what decides, and nothing about the machine is being read.
make_chain l8c
sleep 300 & L8CHILD=$!
sleep 2
mkdir -p "$STATE/run.lock"; printf '%s\n' "$L8CHILD" > "$STATE/run.lock/pid"
mutate 's|: "${TIMEOUT:=14400}"|: "${TIMEOUT:=1}"|'
doctor
expect "T112 L8  a session past its budget is EXPOSED — on the owner's clock, not the suite's" EXPOSED L8
l8secs=$(printf '%s\n' "$OUT" | grep -E '^ +EXPOSED +L8 ' | sed -nE 's/.*running for ([0-9]+) s.*/\1/p' | head -n 1)
case "$l8secs" in ''|*[!0-9]*) l8secs=-1 ;; esac
# Under a minute: the suite itself has been running far longer by the time it reaches here, so
# a figure this small can only have come from the process named in the lock. That is the whole
# point of the fix — the old T21 was green on the suite's own age.
if [ "$l8secs" -ge 1 ] && [ "$l8secs" -lt 60 ]; then
  ok "T113 L8  …and the elapsed time printed is the lock owner's, not the test process's"
else bad "T113 L8  …and the elapsed time printed is the lock owner's, not the test process's" \
  "read '$l8secs' from: $(printf '%s\n' "$OUT" | grep -E '^ +EXPOSED +L8 ' | head -n 1 | sed 's/^ *//')"; fi
make_chain l8d
mkdir -p "$STATE/run.lock"; printf '%s\n' "$L8CHILD" > "$STATE/run.lock/pid"
doctor
expect "T114 L8  the same process, the same elapsed time, a budget that covers it" GUARDED L8
kill "$L8CHILD" 2>/dev/null; wait "$L8CHILD" 2>/dev/null

# =========================================================================================
# C10 — THE THIRD VERDICT. Everything above proves this tool accuses (42 EXPOSED assertions)
# and that it reassures (25 GUARDED). S54 measured what none of it proved: that it ABSTAINS.
# Fine mutation over the nine most fragile checks turned one `finding UNKNOWN` into `finding
# GUARDED`, one line at a time — sixteen mutants, sixteen survivors, 152 tests still green.
# The tool would have said "protected" where it had measured nothing, which is the exact fault
# it exists to report, and nothing in this suite would have gone red.
#
# So: one fixture per UNKNOWN branch, sixteen branches, each pinned by what the tool said and
# not merely by its verdict. `expect UNKNOWN L3` is green on any of L3's three UNKNOWN
# branches; a fixture landing on the wrong one would certify a branch it never reached.
# =========================================================================================
echo
echo "-- C10  the third verdict: what the tool says when it has NOT measured"

# --- L1: the scheduler's exit-code column, and the two ways it can be unusable -----------
# No scheduler entry matched: the column does not exist for this launcher. Saying GUARDED here
# would be inventing a healthy probe out of an empty registry.
make_chain u1a; : > "$LCTL"; doctor
expect_because "T135 L1  no scheduler entry matched → UNKNOWN, not an invented exit 0" \
  UNKNOWN L1 "last probe exit code not readable"
# The column exists and holds something that is not a number. `case` would otherwise fall into
# the catch-all and print "the probe's last run exited stopped".
make_chain u1b; printf -- '-\tstopped\tcom.test.bot\n' > "$LCTL"; doctor
expect_because "T136 L1  a non-numeric status column → UNKNOWN, not an accusation" \
  UNKNOWN L1 "last probe exit code not a number"

# --- L3: three UNKNOWN branches, none of which had a test ---------------------------------
# Neither the scheduler entry nor the launcher names an error file. A fatal error in the
# launcher then has nowhere to land, and that is precisely what cannot be called protected.
make_chain u3a
mutate 's|^: "${PROBE_ERR:=.*||'
sed -e '/StandardErrorPath/d' "$PLIST" > "$PLIST.2" && mv "$PLIST.2" "$PLIST"
doctor
expect_because "T137 L3  no error file declared anywhere → UNKNOWN" \
  UNKNOWN L3 "no probe error file is declared anywhere"
# Declared and absent. This one used to be GUARDED and was the clearest counter-example to
# this tool's own rule: drained and never-written-to are the same bytes on disk.
make_chain u3b; rm -f "$STATE/probe.err"; doctor
expect_because "T138 L3  declared and absent → UNKNOWN, never 'drained'" \
  UNKNOWN L3 "probe error file declared, and absent"
# The size cannot be read. Not a permission case — `stat` needs none — but a PORTABILITY one:
# a host whose stat speaks neither BSD nor GNU. The fixture supplies exactly that stat, which
# is the only honest way to reach this branch, and it says so in its own name.
make_chain u3c
printf 'a fatal error nothing ever drained\n' > "$STATE/probe.err"
printf '#!/bin/bash\nexit 1\n' > "$ROOT/bin/stat"; chmod +x "$ROOT/bin/stat"
export ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET"
OUT=$(PATH="$ROOT/bin:$PATH" bash "$DOCTOR" --verbose --plist "$PLIST" "$LAUNCHER" 2>&1); RC=$?
note_duplicates "l3c (a host whose stat reports no size)"
expect_because "T139 L3  a stat that reports no size → UNKNOWN, not a size of zero" \
  UNKNOWN L3 "probe error file not readable as this user"

# --- L7: no lock path at all, and a lock that names nobody --------------------------------
make_chain u7a; mutate 's|^GATE=.*||'; doctor
expect_because "T140 L7  no lock path in the launcher → UNKNOWN, not 'nothing is stale'" \
  UNKNOWN L7 "no lock path found in the launcher"
make_chain u7b; mkdir -p "$STATE/run.lock"; doctor
expect_because "T141 L7  a lock naming no owner → UNKNOWN: age alone cannot release it" \
  UNKNOWN L7 "the lock names no owner"
# …and the age it did measure has to be in the evidence. Without this the `[ -n "$m" ]` guard
# can be inverted, the age silently dropped, and the verdict stays right for the wrong reason.
expect_evidence "T142 L7  …and the evidence carries the age the check actually measured" \
  UNKNOWN L7 "held for"

# --- L9: nothing is invoked directly, so there is no +x bit to judge ----------------------
make_chain u9a; mutate 's|^"$SCRIPT_DIR/nap-guard.sh"|bash "$SCRIPT_DIR/nap-guard.sh"|'; doctor
expect_because "T143 L9  everything goes through an interpreter → UNKNOWN, not GUARDED" \
  UNKNOWN L9 "no directly-invoked script found to check"

# --- L13: the two sides of the error path, when there are not two sides -------------------
make_chain u13a
sed -e '/StandardErrorPath/d' "$PLIST" > "$PLIST.2" && mv "$PLIST.2" "$PLIST"
doctor
expect_because "T144 L13 only the launcher declares an error path → UNKNOWN, not 'they match'" \
  UNKNOWN L13 "only one side declares a probe error path"
make_chain u13b
mutate 's|^: "${PROBE_ERR:=.*||'
sed -e '/StandardErrorPath/d' "$PLIST" > "$PLIST.2" && mv "$PLIST.2" "$PLIST"
doctor
expect_because "T145 L13 neither side declares one → UNKNOWN: there is nothing to compare" \
  UNKNOWN L13 "neither side declares a probe error path"

# --- S1: no wakeup variable, and a wakeup variable nothing writes -------------------------
make_chain us1a; mutate 's|^DUE_FILE=.*||'; doctor
expect_because "T146 S1  no wakeup variable → UNKNOWN, not 'the write is safe'" \
  UNKNOWN S1 "no wakeup variable to look for a writer of"
make_chain us1b; mutate 's|.*DUE_FILE\.tmp.*||'; doctor
expect_because "T147 S1  read here, written elsewhere → UNKNOWN, not a certified safe write" \
  UNKNOWN S1 "nothing in this launcher writes the wakeup file"

# --- S4: no mkdir to judge, and a failure branch this tool cannot read ---------------------
make_chain us4a; mutate 's|if ! mkdir "$GATE" 2>/dev/null; then|if ! ln -s . "$GATE" 2>/dev/null; then|'; doctor
expect_because "T148 S4  a launcher that takes its lock another way → UNKNOWN" \
  UNKNOWN S4 "no lock-creating mkdir found"
# The mkdir is there and its failure branch matches neither the safe shapes nor the unsafe
# ones. Guessing either way is how a static check earns its reputation.
make_chain us4b
mutate 's|.*cannot create the lock.*|  echo "the lock could not be taken" >> "$RUNLOG"|' \
       's|^  exit 0$|  exit 3|'
doctor
expect_because "T149 S4  an unrecognised failure branch → UNKNOWN, not a guess either way" \
  UNKNOWN S4 "could not read what happens when mkdir fails"

# --- S4: the decoy mkdir — the one survivor of the S56 fine-mutation matrix ----------------
# S4 builds its search pattern from the lock VARIABLE when discovery found one
# (`mkdir … $GATE`) and falls back to a bare `mkdir[[:space:]]` when it did not. S56 measured
# that flipping that `[ -n "$V_LOCK" ]` to `[ -z` — i.e. never using the specific pattern —
# survived all 173 tests: every fixture in this suite has exactly ONE non-`-p` mkdir, so the
# generic fallback lands on the very same line and the report comes out identical. The two
# only tell themselves apart on a launcher that creates some OTHER directory before taking
# its lock, and no fixture did. This one does, and that is its entire purpose.
make_chain s4decoy
mutate 's|^if \[ -d "\$GATE" \]; then|SCRATCH="$BOT_STATE/scratch"\nmkdir "$SCRATCH" 2>/dev/null\nprintf "scratch\\n" >> "$SCRATCH/.keep"\nSCRATCH_RC=$?\n: "$SCRATCH_RC"\nif [ -d "$GATE" ]; then|'
doctor
expect_because "T157 S4  a decoy mkdir before the lock does not steal the verdict" \
  GUARDED S4 "a failed mkdir is told apart from a lost race"
# The verdict alone is not enough here and that is the whole lesson of the cell: a check can
# reach the right verdict off the wrong line. The address is what pins it.
expect_evidence "T158 S4  …and the evidence addresses the LOCK line, not the decoy" \
  GUARDED S4 'mkdir "$GATE"'
# And the argument the whole tool rests on, which this fixture had nobody making: s4decoy is a
# CORRECT chain. A launcher that creates a scratch directory before taking its lock is ordinary
# writing, not a defect — so the run must raise no alarm anywhere, not merely the right verdict
# on S4. Written in S58 after S57 shipped the fixture without it: "zero false positives on a
# correct chain" is this tool's main claim, and it was asserted on two chain shapes out of the
# hundred-odd this suite builds. The expectation for the mutation matrix was set BEFORE the run
# and is deliberately unflattering: this assertion should kill NOTHING new. If a cell moves, a
# mutant fabricates an accusation that only the decoy shape exposes, and that is a defect of the
# tool being read — not a coverage gain to claim.
expect_no_exposed "T161 S4  …and the decoy chain, being correct, is accused of nothing"

# --- S12: an invariant needs both of its terms --------------------------------------------
make_chain us12a; mutate 's|^: "${DEADMAN:=.*||'; doctor
expect_because "T150 S12 only one of the two settings is readable → UNKNOWN, not GUARDED" \
  UNKNOWN S12 "not both readable"

# --- S13: nothing security-relevant is defaulted at all -----------------------------------
make_chain us13a; mutate 's|^: "${BOT_ARGS=.*||'; doctor
expect_because "T151 S13 no security-relevant default in the launcher → UNKNOWN" \
  UNKNOWN S13 "no security-relevant defaulted variable found"

# =========================================================================================
# C11 — the two half-checks S54 named as having NO test at all, on either side. Neither is an
# UNKNOWN assertion, which is why they are counted apart: they close a hole that was measured,
# not one that was reasoned about.
# =========================================================================================
echo
echo "-- C11  the two half-checks nothing had ever exercised"

# L9's other half: the scheduler runs the launcher ITSELF, with no interpreter in front of it.
# That chain reports 126 at every tick and starts no session, ever — and until now the whole
# sub-path was unmeasured, both when the +x bit is missing and when it is there.
make_chain u9b
sed -e 's|<string>/bin/bash</string>||' "$PLIST" > "$PLIST.2" && mv "$PLIST.2" "$PLIST"
chmod -x "$LAUNCHER"; doctor
expect_because "T153 L9  run directly by the scheduler with no +x bit → EXPOSED" \
  EXPOSED L9 "something the chain runs directly has no +x bit"
expect_evidence "T154 L9  …and the evidence names the scheduler as the direct caller" \
  EXPOSED L9 "the scheduler runs it directly"
make_chain u9c
sed -e 's|<string>/bin/bash</string>||' "$PLIST" > "$PLIST.2" && mv "$PLIST.2" "$PLIST"
chmod +x "$LAUNCHER"; doctor
expect_evidence "T155 L9  …the same chain with the bit set is GUARDED, and says why" \
  GUARDED L9 "(the launcher, run directly by the scheduler)"

# S13's other half: `: "${NAME:=}"` — a security-relevant default ARMED WITH AN EMPTY VALUE.
# The `=` form was tested, this one was not. It is the branch that decides whether exporting
# an empty value disarms the default or is overridden by it.
make_chain us13b; mutate 's|^: "${BOT_ARGS=--quiet}"|: "${BOT_ARGS:=}"|'; doctor
expect_because "T156 S13 a default armed with an EMPTY value can be disarmed → GUARDED" \
  GUARDED S13 "can be disarmed by an empty value"

# =========================================================================================
# C12 — THE THIRD VERDICT, ON THE CHECKS NOBODY LOOKED AT. C10 above closed sixteen
# `UNKNOWN → GUARDED` holes on the nine checks S54 had chosen as "the most fragile". S59 ran
# the same mutation over all TWENTY-NINE and measured what that choice had hidden: 35 more
# survivors, every single one of them on a check C10 never touched, and NINE checks whose
# every way of saying "I do not know" could be turned into "this is protected" without one of
# the 178 tests going red. The sample had not been pessimistic, it had been optimistic — the
# twenty checks left aside as less promising ran at 27 % survival against the nine's 0 %.
#
# These nineteen assertions are those nine checks: L5, L6, L8, L12, S2, S3, S7, S8, S9, one
# fixture per UNKNOWN branch, each pinned by WHAT THE TOOL SAID with expect_because. The rule
# from C10 applies unchanged and matters more here, since L8 has four UNKNOWN branches and L5
# three: `expect UNKNOWN L8` is green on any of them.
# =========================================================================================
echo
echo "-- C12  the third verdict on the checks the first pass never reached"

# --- L5: three ways a wakeup value has no RANGE to check ---------------------------------
# Shape is L4's job; range is this one's. All three branches say the same thing in different
# words — there is no number here to compare against the clock — and a GUARDED on any of them
# reads as "next wakeup is ahead, within a sane range" about a value that does not exist.
make_chain u5a; mutate 's|^DUE_FILE=.*||'; doctor
expect_because "T162 L5  no wakeup path in the launcher → UNKNOWN, not a sane range" \
  UNKNOWN L5 "no wakeup file path found in the launcher"
make_chain u5b; rm -f "$STATE/run.next"; doctor
expect_because "T163 L5  the path is known and nothing is on disk → UNKNOWN" \
  UNKNOWN L5 "no wakeup file on disk to range-check"
make_chain u5c; printf 'tomorrow-ish\n' > "$STATE/run.next"; doctor
expect_because "T164 L5  a wakeup value that is not a number has no range → UNKNOWN" \
  UNKNOWN L5 "the wakeup value is not a number"

# --- L6 and its neighbours: a lock has no SHAPE until it exists --------------------------
# L6 judges the lock's shape against what the launcher does with it. Two of its three UNKNOWN
# branches are about there being nothing to judge, and the third about a directory no mkdir in
# the file ever creates. S2's "no lock, nothing to release" rides the first fixture: it is the
# same absence read by a different check, and both had gone unasserted.
make_chain u6a; mutate 's|^GATE=.*||'; doctor
expect_because "T165 L6  no lock path in the launcher → UNKNOWN, not a shape that matches" \
  UNKNOWN L6 "no lock path found in the launcher"
expect_because "T166 S2  …and with no lock, no trap has anything to release → UNKNOWN" \
  UNKNOWN S2 "no lock found, so nothing here needs releasing on a signal"
# The clean chain, which is the commonest state of all: a chain at rest holds no lock. This
# branch used to be GUARDED and was the clearest counter-example to the tool's own rule —
# "nothing is holding the chain" is L7's measurement, not evidence about a shape.
make_chain u6b; doctor
expect_because "T167 L6  a lock that does not exist has no shape to judge → UNKNOWN" \
  UNKNOWN L6 "no lock on disk, so its shape cannot be judged"
expect_because "T168 L8  …and with no session running, none can be overrunning → UNKNOWN" \
  UNKNOWN L8 "no session is running, so none can be overrunning"
# A lock directory on disk that no `mkdir` in the launcher creates. The launcher took it some
# other way, so "the lock is a directory, as the launcher expects" would be a claim about an
# intent this tool never read.
make_chain u6c
mutate 's|if ! mkdir "$GATE" 2>/dev/null; then|if ! ln -s . "$GATE" 2>/dev/null; then|'
mkdir -p "$STATE/run.lock"; doctor
expect_because "T169 L6  a lock directory the launcher never mkdirs → UNKNOWN, not 'as expected'" \
  UNKNOWN L6 "the launcher's intent is unclear"
expect_because "T170 L8  …and a lock naming no owner has no runtime to read → UNKNOWN" \
  UNKNOWN L8 "the lock names no usable owner"

# --- L8: a runtime you cannot measure is not a session within budget ---------------------
# The dead owner. L7 carries the verdict on the orphan lock itself; L8 must not turn the same
# state into "a session is running, within its time budget", which is what the mutant does.
make_chain u8a; mkdir -p "$STATE/run.lock"; printf '4194303\n' > "$STATE/run.lock/pid"; doctor
expect_because "T171 L8  a lock whose owner is gone → UNKNOWN, not a session within budget" \
  UNKNOWN L8 "the lock's owner is not running"
# The last of L8's four: the owner IS alive and `ps` cannot say for how long. Not a contrived
# case — `ps -o etime=` is not POSIX-mandated output and busybox prints a different column set.
# The fixture supplies exactly that ps, and says so in its own name.
make_chain u8b
mkdir -p "$STATE/run.lock"; printf '%s\n' "$$" > "$STATE/run.lock/pid"
printf '%s\n' '#!/bin/bash' 'for a in "$@"; do case "$a" in etime=) printf "not-a-duration\n"; exit 0 ;; esac; done' 'exit 0' \
  > "$ROOT/bin/ps"; chmod +x "$ROOT/bin/ps"
export ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET"
OUT=$(PATH="$ROOT/bin:$PATH" bash "$DOCTOR" --verbose --plist "$PLIST" "$LAUNCHER" 2>&1); RC=$?
note_duplicates "u8b (a ps that cannot report an elapsed time)"
expect_because "T172 L8  a ps that reports no elapsed time → UNKNOWN, not 'within budget'" \
  UNKNOWN L8 "cannot read how long the session has been running"
expect_once "T202 L8  …and an unmeasurable runtime is one finding, not two" L8

# --- L12 and S8: a launcher that never names the thing it runs ---------------------------
# Rename the one variable whose name says "this holds a CLI" and the tool has nothing to
# resolve and nothing to bound. Both checks must abstain: a GUARDED L12 here claims a PATH
# resolution that was never attempted, and a GUARDED S8 claims a timeout around no call at all.
make_chain u12a; mutate 's/BOT_CLI/BOT_RUNNER/g'; doctor
expect_because "T173 L12 no agent binary name in the launcher → UNKNOWN, not a resolved binary" \
  UNKNOWN L12 "no agent binary name found in the launcher"
expect_once "T205 L12  …and an unnamed binary is one finding, not one plus a PATH verdict on """ L12
expect_because "T174 S8  no agent invocation to bound → UNKNOWN, not a certified watchdog" \
  UNKNOWN S8 "no agent invocation found to bound"
expect_once "T206 S8  …and nothing to bound means one finding, not one plus a timeout verdict on """ S8

# --- L12 and S7: no PATH is known for this chain at all ----------------------------------
# The launcher is named on the command line, no scheduler entry claims it, and it exports no
# PATH of its own. `command -v` in MY shell would answer — and answering from my shell is the
# exact mistake this branch exists to refuse. Same fixture shape as T105's.
make_chain u12b
mkdir -p "$WORK/no-agents"
OUT=$(ACD_LAUNCHAGENTS_DIR="$WORK/no-agents" ACD_PMSET_LOG="$PMSET" \
      bash "$DOCTOR" --verbose "$LAUNCHER" 2>&1); RC=$?
note_duplicates "u12b (a launcher no scheduler entry claims)"
expect_because "T175 L12 no scheduler PATH and none exported → UNKNOWN, not 'it resolves'" \
  UNKNOWN L12 "the scheduler's PATH is unknown and the launcher sets none"
# S7's fourth branch, on the same ground: the keep-awake wrapper is unconditional, so it can
# stop every session on its own, and there is no PATH to check it against.
make_chain u7s
mutate 's|if command -v caffeinate >/dev/null 2>&1; then|if true; then|'
OUT=$(ACD_LAUNCHAGENTS_DIR="$WORK/no-agents" ACD_PMSET_LOG="$PMSET" \
      bash "$DOCTOR" --verbose "$LAUNCHER" 2>&1); RC=$?
note_duplicates "u7s (an unconditional keep-awake wrapper, on a chain with no known PATH)"
expect_because "T176 S7  an unconditional wrapper and no PATH to check it against → UNKNOWN" \
  UNKNOWN S7 "no PATH is known for this chain"

# --- S7, S3, S9: three static checks with nothing to read --------------------------------
# No wrapper at all. Whether that matters is L10's call, made on a measured sleep history —
# so this check must say it did not judge, not that the absence is a protection.
make_chain u7t; mutate 's/caffeinate/napblocker/g'; doctor
expect_because "T177 S7  no keep-awake wrapper at all → UNKNOWN, not GUARDED by absence" \
  UNKNOWN S7 "no keep-awake wrapper in this launcher"
make_chain u3s; mutate '/^trap /d'; doctor
expect_because "T178 S3  no trap at all → UNKNOWN, there is no handler to inspect" \
  UNKNOWN S3 "no trap to inspect"
# Only an EXIT handler, which S3 deliberately does not judge (an `exit` inside an EXIT handler
# is a recursion). "Every kill-signal handler terminates the script" is a statement about a
# set that is empty here.
make_chain u3t; mutate "/^trap 'release; exit 143' TERM INT HUP\$/d"; doctor
expect_because "T179 S3  only an EXIT handler → UNKNOWN, this check does not judge those" \
  UNKNOWN S3 "no handler on INT/TERM/HUP to inspect"
make_chain u9s; mutate 's|^HOUR=.*|HOUR=12|'; doctor
expect_because "T180 S9  a launcher that reads no zero-padded time field → UNKNOWN" \
  UNKNOWN S9 "this launcher reads no zero-padded time field"

# =========================================================================================
# C13 — THE LAST SIXTEEN. C12 closed the nine checks whose every UNKNOWN branch survived the
# `UNKNOWN → GUARDED` mutation. S59's matrix named sixteen more, spread over eleven checks
# that had never been mutated at all: L2, L4, L10, L11, S5, S6, S10, S11, S14, S15, S16.
# With these, no `verdict-U2G` site in the whole corpus is left unasserted — the first time
# a whole mutation operator reaches zero across all twenty-nine checks.
#
# Three of them (S10, S11, S14) emit the SAME first line, "no wakeup variable to follow",
# under three different ids, and each id has a SECOND UNKNOWN branch besides. Pinning on the
# summary would therefore not pin anything: it is the evidence line that says which check
# spoke and which of its two silences this is — reading, bounds, display. Those three use
# expect_evidence for exactly that reason, and it is the first time the distinguishing text
# in this suite lives under the verdict rather than on it.
# =========================================================================================
echo
echo "-- C13  the last sixteen UNKNOWN branches, on the eleven checks never mutated"

# --- one absence, four checks: a launcher that declares no wakeup file -------------------
# The same fixture T162 uses. Four checks read the same variable and must all abstain: L4 has
# no shape to judge, S10 no read to find, S11 no bound to look for, S14 no display to check.
# A GUARDED on any of them is a claim about a file the launcher never names.
make_chain u4a; mutate 's|^DUE_FILE=.*||'; doctor
expect_because "T181 L4  no wakeup path in the launcher → UNKNOWN, not a shape that holds" \
  UNKNOWN L4 "no wakeup file path found in the launcher"
expect_evidence "T182 S10 …and no wakeup variable to follow into a read → UNKNOWN" \
  UNKNOWN S10 "nothing to check the reading of"
expect_evidence "T183 S11 …nor into a bound → UNKNOWN, not 'the value is capped'" \
  UNKNOWN S11 "nothing to check the bounds of"
expect_evidence "T184 S14 …nor into a display → UNKNOWN, not 'the hour shown is real'" \
  UNKNOWN S14 "nothing to check the display of"

# --- L4's other unasserted branch: present, and unreadable as this user ------------------
# Unreadable is not empty and not absent. `head` returns nothing for both, and the EXPOSED
# branch underneath would print "0 bytes of content" as the proof of a file it never opened.
make_chain u4b; chmod 000 "$STATE/run.next"; doctor
expect_because "T185 L4  a wakeup file that cannot be read → UNKNOWN, not '0 bytes'" \
  UNKNOWN L4 "the wakeup file cannot be read as this user"
expect_once "T201 L4  …and an unreadable wakeup file is one finding, not two" L4
chmod 644 "$STATE/run.next"

# --- L2: no log path at all, and a log path this tool had to guess -----------------------
# Erase the one assignment whose name says "log". Everything downstream still writes to
# $RUNLOG, so the chain is not obviously broken — the tool simply has no path to judge, and
# "the chain has been quiet" is a statement about a file it cannot name.
make_chain u2a; mutate 's|^RUNLOG=.*||'; doctor
expect_because "T186 L2  no log path in the launcher → UNKNOWN, not 'quiet on purpose'" \
  UNKNOWN L2 "no main log path found in the launcher"
expect_once "T199 L2  …and the branch that abstains for want of a log path must abstain ONCE" L2
# The guessed path. `${LOG_HOME:-…}` with LOG_HOME declared nowhere this tool can read: the
# value is the scheduler's to supply, so the file's absence from disk is evidence about the
# guess, not about the chain. The wakeup is put in the PAST so the fresh-chain branch above
# it (T78/T106) does not answer first.
make_chain u2b
mutate 's|^RUNLOG=.*|RUNLOG="${LOG_HOME:-$BOT_STATE}/run.log"|'
rm -f "$STATE/run.log"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$STATE/run.next"
doctor
expect_because "T187 L2  a log path built on an undeclared variable → UNKNOWN, not EXPOSED" \
  UNKNOWN L2 "the main log is not where this tool guessed"
expect_once "T200 L2  …and the guessed-path branch must abstain ONCE, not once here and again below" L2

# --- L11: no prompt path, and a prompt whose size cannot be read -------------------------
make_chain u11a; mutate '/BOT_BRIEF:=/d'; doctor
expect_because "T188 L11 no prompt path in the launcher → UNKNOWN, not a contract that holds" \
  UNKNOWN L11 "no prompt file path found in the launcher"
expect_once "T204 L11  …and no prompt path means one finding, not two" L11
# `[ -e ]` says the file is there and `stat` cannot size it. chmod is not enough — stat reads
# the inode, not the content — so the fixture supplies a stat that fails on that one path and
# defers to the real one everywhere else. Without this branch the tool would fall through to
# "exists and is EMPTY", an accusation carrying "0 bytes" as its proof.
make_chain u11b
printf '%s\n' '#!/bin/bash' \
  'for a in "$@"; do case "$a" in */session-prompt.txt) exit 1 ;; esac; done' \
  'exec /usr/bin/stat "$@"' > "$ROOT/bin/stat"; chmod +x "$ROOT/bin/stat"
export ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET"
OUT=$(PATH="$ROOT/bin:$PATH" bash "$DOCTOR" --verbose --plist "$PLIST" "$LAUNCHER" 2>&1); RC=$?
note_duplicates "u11b (a stat that cannot size the prompt file)"
expect_because "T189 L11 a prompt file whose size cannot be read → UNKNOWN, not 'EMPTY'" \
  UNKNOWN L11 "the prompt file is not readable as this user"

# --- L10: no date arithmetic, and a sleep history with a wrapper already in place --------
# Neither BSD `date -v-7d` nor GNU `date -d '7 days ago'` answers. There is then no cutoff,
# so there is no window to count sleeps in — and the GUARDED branch below says "no sleep
# transition inside the work window", a count over a period that was never computed.
make_chain u10a
printf '%s\n' '#!/bin/bash' \
  'for a in "$@"; do case "$a" in -v-7d|-d) exit 1 ;; esac; done' \
  'exec /bin/date "$@"' > "$ROOT/bin/date"; chmod +x "$ROOT/bin/date"
export ACD_LAUNCHCTL_LIST="$LCTL" ACD_PMSET_LOG="$PMSET"
OUT=$(PATH="$ROOT/bin:$PATH" bash "$DOCTOR" --verbose --plist "$PLIST" "$LAUNCHER" 2>&1); RC=$?
note_duplicates "u10a (a date that refuses relative dates)"
expect_because "T190 L10 no 7-day cutoff computable → UNKNOWN, not '0 sleeps in the window'" \
  UNKNOWN L10 "could not compute a 7-day cutoff date"
expect_once "T203 L10  …and no cutoff means one abstention, not one plus a sleep count over nothing" L10
# Sleeps inside the window, WITH a keep-awake call in the launcher. This is the branch that
# says the wrapper exists and does not cover a closed lid on battery — it is neither the
# GUARDED of a quiet machine nor the EXPOSED of one with nothing wrapping it at all.
make_chain u10b
printf '%s 23:10:00 +0400 Sleep               \tEntering Sleep state\n' "$(date '+%Y-%m-%d')" > "$PMSET"
doctor
expect_because "T191 L10 sleeps in the window with a wrapper present → UNKNOWN, not EXPOSED" \
  UNKNOWN L10 "sleep transitions inside the work window"

# --- S5 and S6: two static checks whose subject is simply not in the file ----------------
make_chain u5s; mutate '/stat -f %m/d'; doctor
expect_because "T192 S5  a launcher computing no file age → UNKNOWN, not a validated timestamp" \
  UNKNOWN S5 "this launcher computes no file age"
make_chain u6s; mutate 's|ioreg -c IOHIDSystem|idlequery -c IOHIDSystem|; s|/HIDIdleTime/|/IdleNanos/|'; doctor
expect_because "T193 S6  no human-idle probe at all → UNKNOWN, not a probe that is validated" \
  UNKNOWN S6 "no human-idle probe found"

# --- S15 and S16: the launcher never names the thing it runs -----------------------------
# T173's shape, read by two other checks. With no agent invocation there is no return to
# follow (S15) and no line on which to divide the file into "before the session" and "after"
# (S16). Both must abstain; a GUARDED S15 here claims an exit code is read from a call that
# does not exist.
make_chain u15a; mutate 's/BOT_CLI/BOT_RUNNER/g'; doctor
expect_because "T194 S15 no agent invocation → UNKNOWN, not 'the exit code is read'" \
  UNKNOWN S15 "no agent invocation found to follow"
expect_once "T207 S15  …and no call to follow means one finding, not two" S15
expect_because "T195 S16 …and no line to divide the session on → UNKNOWN" \
  UNKNOWN S16 "cannot tell the start of the session from its end"
expect_once "T208 S16  …and an undividable file is one finding, not one plus a marker verdict" S16
# S16's other absence: no marker variable at all. The spacing floor cannot be judged from a
# file the launcher never names.
make_chain u16a; mutate 's|^STAMP=.*||'; doctor
expect_because "T196 S16 no spacing-marker variable → UNKNOWN, not a marker written twice" \
  UNKNOWN S16 "no spacing-marker variable found"
expect_once "T209 S16  …and no marker variable means one finding, not two" S16

# The global invariant, read once at the end over every run the suite made. It is deliberately
# weaker than expect_full_catalogue (it asks "never twice", not "all 29, once each") because it
# has to hold for the partial reports too — but it holds for EVERY run instead of four.
echo
echo "-- the duplicate sweep itself, seen both ways"
# T152 has no fixture: it reads the output of every other run. S56 measured that EIGHT of the
# 77 fine-mutation cells — 10 % of the matrix — die by T152 ALONE, no other test noticing
# them. A mechanism carrying a tenth of the coverage and never itself seen red is a single
# point of failure dressed as a guarantee: break its regex or turn its `uniq -d` into
# something that can never match, and it goes mute, the suite stays 100 % green, and the
# eight cells go dark at once with nothing to say so. These two cases are its red proof.
# They deliberately do NOT run the tool — they exercise the harness — which is why they are
# green under LEGACY=1 too. That is correct here and would be a defect anywhere else in this
# file, so it is written down rather than left to be rediscovered.
_dup_selftest() {
  local saved_trail="$DUP_TRAIL" saved_runs="$DUP_RUNS" saved_out="$OUT"
  DUP_TRAIL=""
  OUT=$(printf '  GUARDED  L1  a first verdict\n  EXPOSED  S4  another id entirely\n  UNKNOWN  L1  the same id, a second time\n')
  note_duplicates "self-test: L1 emitted twice"
  case "$DUP_TRAIL" in
    *L1*) ok "T159  the duplicate sweep SEES an id emitted twice (its own red proof)" ;;
    *)    bad "T159  the duplicate sweep SEES an id emitted twice (its own red proof)" \
            "the trail stayed empty on an output carrying L1 twice — the sweep is mute" ;;
  esac
  DUP_TRAIL=""
  OUT=$(printf '  GUARDED  L1  a first verdict\n  EXPOSED  S4  another id entirely\n')
  note_duplicates "self-test: nothing duplicated"
  if [ -z "$DUP_TRAIL" ]; then ok "T160  …and stays silent when nothing is duplicated"
  else bad "T160  …and stays silent when nothing is duplicated" "$DUP_TRAIL"; fi
  DUP_TRAIL="$saved_trail"; DUP_RUNS="$saved_runs"; OUT="$saved_out"
}
_dup_selftest

# The root guard's own red proof, on the same principle as T159/T160: a guard nobody ever saw
# fire is a comment. Two calls with the answer known in advance and opposite. Like them, these
# do not run the tool, so they are green under LEGACY=1 too.
if not_root 0; then bad "T197  the root guard REFUSES uid 0 (its own red proof)" "not_root 0 said the run was safe"
else ok "T197  the root guard REFUSES uid 0 (its own red proof)"; fi
if not_root 501; then ok "T198  …and lets an ordinary uid through"
else bad "T198  …and lets an ordinary uid through" "not_root 501 refused a non-root uid"; fi

echo
echo "-- the invariant every run had to keep"
if [ -z "$DUP_TRAIL" ]; then
  ok "T152  no run in this suite ever printed an id twice ($DUP_RUNS runs watched)"
else
  bad "T152  no run in this suite ever printed an id twice ($DUP_RUNS runs watched)" "$DUP_TRAIL"
fi

echo
echo "================================================================"
printf '  %s passed, %s red\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '  red:%s\n' "$RED_LIST"; fi
echo "================================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
