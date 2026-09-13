#!/bin/bash
# prove-red.sh — does the suite actually watch each check, or is it green for its own reasons?
#
# run-tests.sh answers "does every check fire on a chain built to trip it, and stay quiet on a
# correct one". It cannot answer the question underneath: **is any test still able to go red if
# a given check stops working?** A test can be green because the code is right, or green because
# it never looked. Nothing on screen tells the two apart, and a consigne that says "look harder"
# has been tried and measured useless.
#
# So this asks the machine instead. For each check, two mutants of the tool are built and the
# whole suite is run against each:
#
#   always-GUARDED   the check emits GUARDED whatever it sees. Its DETECTION is gone; the
#                    catalogue is still complete and no false alarm is raised, so only a test
#                    that asserts this check ACCUSES something can notice.
#   always-EXPOSED   the check accuses whatever it sees. Its RESTRAINT is gone; only a test
#                    that asserts a clean or unknown verdict for it can notice.
#
# A mutant that no test named for that check kills is a SURVIVOR: for that half of that check,
# the suite is green for a reason unrelated to the code. That is the finding.
#
#   ./prove-red.sh                 the full matrix (every check × 2 mutants)
#   ./prove-red.sh --only L1,S8    a subset, while iterating
#   ./prove-red.sh --self-test     prove the instrument itself, both directions (see below)
#   ./prove-red.sh --jobs 4        parallelism (default 6)
#   ./prove-red.sh --strict        a mutant killed only by a generic sweep also fails the run
#   ./prove-red.sh --fine          FINE mutants instead of the coarse pair (see below)
#   ./prove-red.sh --fine --list-sites   print the fine mutation sites and stop, without running
#
# FINE MUTANTS (--fine). The coarse pair above replaces a check's WHOLE verdict, so any test
# that looks at that check at all goes red. A fine mutant is the opposite: one literal token
# changed on one line — a branch's verdict flipped, a `!` dropped, `-eq` relaxed to `-ne`, a
# `return` turned into a no-op. The check keeps answering correctly almost everywhere and
# answers wrong on one fixture. That is where survivors live in every published mutation
# corpus, and the coarse matrix says nothing about them: reading its zero as "the suite is
# perfect" would be a verdict on what the instrument never looked for.
#   A fine survivor is NOT automatically a hole: it can be an EQUIVALENT mutant, whose change
# alters no observable behaviour. The two read identically on screen. Every survivor has to be
# opened and classified by hand before any number is published.
#
# THE INSTRUMENT'S OWN RED PROOF (--self-test). A mutation harness has one classic way of
# lying: build a mutant that does not even run — wrong path, broken syntax — and every test
# dies, which reads on screen as magnificent coverage. So the self-test runs two mutants whose
# answers are known in advance and opposite:
#   * always-GUARDED on a check the suite demonstrably watches  → must be KILLED
#   * an IDENTITY mutant (a comment inserted, behaviour unchanged) → must SURVIVE
# If the harness is broken in the way above, the identity mutant comes back KILLED and the
# self-test goes red. A harness that can only ever say "killed" proves nothing.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DOCTOR_SRC="$HERE/../agent-chain-doctor"
SUITE="$HERE/run-tests.sh"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

JOBS=6
DEADLINE=1200   # seconds a single suite run may take before it is declared hung
ONLY=""
SELFTEST=0
STRICT=0
FINE=0
LISTSITES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="${2:-6}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    --strict) STRICT=1; shift ;;
    --fine) FINE=1; shift ;;
    --list-sites) FINE=1; LISTSITES=1; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$JOBS" in ""|*[!0-9]*) echo "--jobs wants a positive integer, got '$JOBS'" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || { echo "--jobs must be at least 1" >&2; exit 2; }   # 0 would spin forever in the pool loop

[ -r "$DOCTOR_SRC" ] || { echo "no tool at $DOCTOR_SRC" >&2; exit 2; }
[ -r "$SUITE" ]      || { echo "no suite at $SUITE" >&2; exit 2; }

# -----------------------------------------------------------------------------------------
# The catalogue of checks, read from the tool itself — never from a hand-kept list, which is
# how a registry ends up two entries short of the thing it registers.
# -----------------------------------------------------------------------------------------
CHECKS=$(grep -oE '^check_[LS][0-9]+_[a-z_0-9]+\(\) \{$' "$DOCTOR_SRC" | sed 's/() {$//')
[ -n "$CHECKS" ] || { echo "no check functions found in $DOCTOR_SRC" >&2; exit 2; }

id_of() { printf '%s' "$1" | sed -E 's/^check_([LS][0-9]+)_.*/\1/'; }

# -----------------------------------------------------------------------------------------
# The fine mutation sites of one check body. One site = one LITERAL, first-occurrence
# substitution on one line, so the mutant is readable as a diff of exactly one line. Comment
# lines are skipped (mutating a comment is an identity mutant wearing a costume), and at most
# one site is taken per line — a line with two `-n` tests yields one mutant, not two, and that
# is a stated limit rather than a silent one.
# -----------------------------------------------------------------------------------------
FINE_CAP=12
fine_sites() {  # $1 func → idx \t absolute-line \t op \t from \t to   (+ a trailing !CAPPED row)
  awk -v f="$1() {" -v cap="$FINE_CAP" '
    function emit(op, from, to) { n++; if (n <= cap) printf "%d\t%d\t%s\t%s\t%s\n", n, NR, op, from, to }
    $0 == f { inb = 1; next }
    inb && /^}$/ { exit }
    !inb { next }
    /^[[:space:]]*#/ { next }
    /finding[[:space:]]+GUARDED[[:space:]]+[LS][0-9]+/ { emit("verdict-G2E", "finding GUARDED", "finding EXPOSED"); next }
    /finding[[:space:]]+EXPOSED[[:space:]]+[LS][0-9]+/ { emit("verdict-E2G", "finding EXPOSED", "finding GUARDED"); next }
    /finding[[:space:]]+UNKNOWN[[:space:]]+[LS][0-9]+/ { emit("verdict-U2G", "finding UNKNOWN", "finding GUARDED"); next }
    /^[[:space:]]*return([[:space:]]+[0-9]+)?[[:space:]]*$/ { emit("drop-return", "return", ":"); next }
    /\[ ! / { emit("drop-bang", "[ ! ", "[ "); next }
    /\[ -z / { emit("neg-z", "[ -z ", "[ -n "); next }
    /\[ -n / { emit("neg-n", "[ -n ", "[ -z "); next }
    / -eq / { emit("eq2ne", " -eq ", " -ne "); next }
    / -gt / { emit("gt2ge", " -gt ", " -ge "); next }
    / -lt / { emit("lt2le", " -lt ", " -le "); next }
    END { if (n > cap) printf "!CAPPED\t%d\t%d\t-\t-\n", cap, n }
  ' "$DOCTOR_SRC"
}

site_label() {  # $1 func  $2 idx → "F3 verdict-U2G:998"
  fine_sites "$1" | awk -F'\t' -v i="$2" '$1==i { printf "F%s %s:%s", $1, $3, $2 }'
}

kinds_for() {  # $1 func → the mutant kinds to run against this check
  if [ "$FINE" = "1" ]; then
    fine_sites "$1" | grep -v '^!' | cut -f1 | sed 's/^/F/'
  else
    printf 'GUARDED\nEXPOSED\n'
  fi
}

if [ -n "$ONLY" ]; then
  keep=""
  for want in $(printf '%s' "$ONLY" | tr ',' ' '); do
    for f in $CHECKS; do [ "$(id_of "$f")" = "$want" ] && keep="$keep $f"; done
  done
  [ -n "$keep" ] || { echo "--only matched no check" >&2; exit 2; }
  CHECKS="$keep"
fi

# -----------------------------------------------------------------------------------------
# Mutant builders. Each inserts ONE line at the top of ONE check body. The tool is otherwise
# byte-identical, so discovery, reporting and every other check keep working: whatever the
# suite notices, it noticed because of this check and nothing else.
# -----------------------------------------------------------------------------------------
build_mutant() {  # $1 func  $2 GUARDED|EXPOSED|IDENTITY|F<idx>  $3 out
  local func="$1" kind="$2" out="$3" id inject want
  id=$(id_of "$func")
  case "$kind" in
    F*)
      local idx=${kind#F} site ln from to
      site=$(fine_sites "$func" | awk -F'\t' -v i="$idx" '$1==i')
      [ -n "$site" ] || { echo "no fine site $idx for $func" >&2; return 1; }
      ln=$(printf '%s' "$site" | cut -f2)
      from=$(printf '%s' "$site" | cut -f4)
      to=$(printf '%s' "$site" | cut -f5)
      # A LITERAL first-occurrence substitution — index()/substr(), never a regex, because the
      # patterns contain `[` and a regex here would silently match something else.
      awk -v n="$ln" -v from="$from" -v to="$to" \
        'NR == n { p = index($0, from); if (p > 0) $0 = substr($0, 1, p - 1) to substr($0, p + length(from)) } { print }' \
        "$DOCTOR_SRC" > "$out" || return 1
      want=2   # one line removed, one added
      ;;
    IDENTITY)
      inject='  : # identity mutant — behaviour unchanged'
      awk -v f="$func() {" -v ins="$inject" '{ print } $0 == f { print ins }' "$DOCTOR_SRC" > "$out" || return 1
      want=1
      ;;
    *)
      inject="  finding $kind $id static \"mutant: $kind whatever the chain says\"; return 0"
      awk -v f="$func() {" -v ins="$inject" '{ print } $0 == f { print ins }' "$DOCTOR_SRC" > "$out" || return 1
      want=1
      ;;
  esac
  chmod +x "$out"
  # A mutant that does not parse would kill every test and read as perfect coverage.
  bash -n "$out" 2>/dev/null || { echo "mutant does not parse: $func/$kind" >&2; return 1; }
  # And one that failed to take must not be counted either. Counted, not assumed: a
  # substitution that did not apply gives 0 changed lines, and an awk that rewrote the file
  # gives many. Both are ERROR, which is neither coverage nor its absence.
  local changed
  changed=$(diff "$DOCTOR_SRC" "$out" | grep -cE '^[<>]' | tr -d ' ')
  [ "$changed" -eq "$want" ] || {
    echo "mutation did not apply cleanly: $func/$kind ($changed changed lines, wanted $want)" >&2; return 1; }
  case "$kind" in F*) : ;; *) grep -qF "$inject" "$out" || { echo "mutation did not apply: $func/$kind" >&2; return 1; } ;; esac
  return 0
}

# -----------------------------------------------------------------------------------------
# One suite run against one mutant → the names of the tests that went red.
# -----------------------------------------------------------------------------------------
run_mutant() {  # $1 func  $2 kind  → writes $WORK/kills.<func>.<kind>
  local func="$1" kind="$2" bin="$WORK/mut.$1.$2" log="$WORK/log.$1.$2"
  if ! build_mutant "$func" "$kind" "$bin"; then
    printf '!BUILD-FAILED\n' > "$WORK/kills.$func.$kind"; return
  fi
  # A deadline, because reap_oldest waits on a pid: ONE suite run that hangs would freeze the
  # whole pool with nothing on screen to say so. macOS has no timeout(1), so: poll and kill.
  DOCTOR_BIN="$bin" bash "$SUITE" > "$log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$DEADLINE" ] && { kill -9 "$pid" 2>/dev/null; printf '!TIMEOUT after %ss\n' "$DEADLINE" > "$WORK/kills.$func.$kind"; return; }
    sleep 5; waited=$((waited + 5))
  done
  wait "$pid" 2>/dev/null
  if ! grep -qE '^ +[0-9]+ passed, [0-9]+ red$' "$log"; then
    printf '!SUITE-DID-NOT-FINISH\n' > "$WORK/kills.$func.$kind"; return
  fi
  grep -E '^  RED  ' "$log" | sed 's/^  RED  //' > "$WORK/kills.$func.$kind"
}

# Kills are counted in two bins, and the difference between them is the whole point.
#
#   NAMED    the test that died carries this check's id in its name ("T05 L1  a launcher
#            that never..."). The suite itself says this test was watching this check.
#   GENERIC  something else died — the catalogue sweep, the no-false-alarm sweep on the
#            canonical correct chain. These die for many mutants at once.
#
# Both are real observation, but they are not worth the same. A restraint proved only by the
# generic clean-chain sweep is proved on ONE chain that trips nothing; it says nothing about
# the near-miss chains where a check actually has to hold its tongue. So: killed by a named
# test = watched; killed only by a generic one = watched thinly, and named as such; killed by
# nobody = the suite is green for a reason unrelated to this code.
ID_RE() { printf '(^|[^A-Za-z0-9])%s([^0-9]|$)' "$1"; }   # a letter glued to the left is not a boundary either
specific_kills() {  # $1 id  $2 kills-file
  grep -E "$(ID_RE "$1")" "$2" 2>/dev/null
}
generic_kills() {   # $1 id  $2 kills-file
  grep -vE "$(ID_RE "$1")" "$2" 2>/dev/null | grep -v '^!'
}

# =========================================================================================
# --list-sites is a "print and stop" contract, so it must not pay for a suite run. It is
# handled here, before the baseline, and nowhere else. (Found by using it: it cost 45s and
# fought a running matrix for the CPU. A flag whose contract says "without running" that runs
# is a small lie, and this file exists because of small lies that read as truths.)
# =========================================================================================
if [ "$LISTSITES" = "1" ]; then
  for f in $CHECKS; do
    id=$(id_of "$f")
    capped=$(fine_sites "$f" | grep '^!CAPPED' || true)
    n=$(fine_sites "$f" | grep -vc '^!' | tr -d ' ')
    printf '   %-4s  %2s sites%s\n' "$id" "$n" \
      "$([ -n "$capped" ] && printf '  [CAPPED at %s of %s]' "$(printf '%s' "$capped" | cut -f2)" "$(printf '%s' "$capped" | cut -f3)")"
    fine_sites "$f" | grep -v '^!' | while IFS="$(printf '\t')" read -r i ln op from to; do
      printf '         F%-3s line %-5s %-12s  %s\n' "$i" "$ln" "$op" \
        "$(sed -n "${ln}p" "$DOCTOR_SRC" | sed 's/^ *//' | cut -c1-90)"
    done
  done
  exit 0
fi

# =========================================================================================
# Baseline. Mutation coverage measured on a suite that is already red means nothing: a test
# that is red before the mutation cannot be killed by it.
# =========================================================================================
echo "== baseline: the suite against the unmutated tool"
BASE="$WORK/baseline.log"
bash "$SUITE" > "$BASE" 2>&1
BASE_RC=$?
tail -n 4 "$BASE" | sed 's/^/   /'
if [ "$BASE_RC" -ne 0 ]; then
  echo
  echo "   the suite is RED before any mutation — fix that first; nothing measured here would mean anything."
  exit 1
fi
BASE_TESTS=$(grep -cE '^  ok   ' "$BASE")
echo "   $BASE_TESTS green tests to kill."
echo

# Two static companions, free and immediate. Both exist because this harness rests on ONE
# assumption — "a test's name says which check it is watching" — and an assumption a tool
# rests on should be enforced by the tool, not believed by its author.
grep -E '^  ok   ' "$BASE" | sed 's/^  ok   //' > "$WORK/names.txt"

echo "== static 1: does any test name each check at all?"
UNNAMED=""
for f in $CHECKS; do
  id=$(id_of "$f")
  specific_kills "$id" "$WORK/names.txt" >/dev/null 2>&1 || UNNAMED="$UNNAMED $id"
done
if [ -n "$UNNAMED" ]; then echo "   NOT NAMED BY ANY TEST:$UNNAMED"; else echo "   every check is named by at least one test."; fi
echo

# The one that matters more. A test whose NAME omits the id it ASSERTS is invisible to the
# matching above: kill it and this harness credits the kill to nobody, i.e. reports a check as
# less watched than it is — or, the day it is the only test of that check, reports SURVIVED on
# a check that is watched. Found by reading? No. Found by this, on the first run.
#
# S56 — and it carried the exact defect it exists to catch. Its grep only ever saw calls written
# on ONE line, so every multi-line assertion S55 added (all 19 `expect_because`, all 4
# `expect_evidence`) was invisible to it while its heading still promised "every test": 85 call
# sites scanned, 109 reported on. That is the `j` family (a verdict rendered on what the
# instrument never looked at) inside the tool written against the `j` family. It now reads
# LOGICAL calls — continuation lines joined, all three helpers — and prints its own denominator.
# What it cannot judge is NAMED (`UNPARSED`), never silently dropped: this control is allowed to
# be incomplete, it is not allowed to be quiet about it.
echo "== static 2: does every test name carry the id it asserts?"
awk '
  function flush(s, ln,    kind, name, rest, n, a) {
    if (s !~ /^[[:space:]]*expect(_because|_evidence)?[[:space:]]+"/) return
    match(s, /expect(_because|_evidence)?/); kind = substr(s, RSTART, RLENGTH)
    rest = s; sub(/^[^"]*"/, "", rest)
    name = rest; sub(/".*$/, "", name)
    sub(/^[^"]*"[[:space:]]*/, "", rest)
    n = split(rest, a, /[[:space:]]+/)
    printf "%d\t%s\t%s\t%s\t%s\n", ln, kind, (n >= 1 ? a[1] : "-"), (n >= 2 ? a[2] : "-"), name
  }
  {
    if (buf == "") { start = NR; buf = $0 } else { buf = buf " " $0 }
    if (buf ~ /\\$/) { sub(/\\[[:space:]]*$/, "", buf); next }
    flush(buf, start); buf = ""
  }
  END { if (buf != "") flush(buf, start) }
' "$SUITE" > "$WORK/calls.tsv"

CALL_SITES=0; LITERAL_ID=0; COMPUTED_ID=0; MISLABELLED=0
: > "$WORK/mislabelled.txt"
while IFS="	" read -r ln kind verdict id name; do
  CALL_SITES=$((CALL_SITES + 1))
  case "$id" in
    [LS][0-9]|[LS][0-9][0-9])
      LITERAL_ID=$((LITERAL_ID + 1))
      printf '%s\n' "$name" | grep -qE "$(ID_RE "$id")" || \
        printf '   MISLABELLED  run-tests.sh:%s  %s asserts %s, name says nothing about it:\n      %s\n' \
          "$ln" "$kind" "$id" "$name" >> "$WORK/mislabelled.txt"
      ;;
    '"$'*)
      # The id is computed (`expect "T51/$sid …" GUARDED "$sid"`). The name cannot carry a
      # literal id, so what is checkable is that it carries the SAME variable — which is what
      # makes the printed name resolve to the id at runtime.
      v=${id#\"}; v=${v%\"}
      case "$name" in
        *"$v"*) COMPUTED_ID=$((COMPUTED_ID + 1)) ;;
        *) printf '   COMPUTED-ID UNCHECKED  run-tests.sh:%s  %s asserts %s and the name does not carry it:\n      %s\n' \
             "$ln" "$kind" "$id" "$name" >> "$WORK/mislabelled.txt" ;;
      esac
      ;;
    *)
      printf '   UNPARSED  run-tests.sh:%s  %s — id token "%s" not understood by this control\n' \
        "$ln" "$kind" "$id" >> "$WORK/mislabelled.txt"
      ;;
  esac
done < "$WORK/calls.tsv"

printf '   %s assertion call sites read — %s with a literal id, %s with a computed id.\n' \
  "$CALL_SITES" "$LITERAL_ID" "$COMPUTED_ID"
if [ -s "$WORK/mislabelled.txt" ]; then
  cat "$WORK/mislabelled.txt"
  echo "   → until these are renamed, the matrix under-reports named coverage for those ids."
  MISLABELLED=$(grep -c 'MISLABELLED\|UNCHECKED\|UNPARSED' "$WORK/mislabelled.txt")
else
  echo "   every assertion names the id it asserts."
fi
echo

# =========================================================================================
# FINE mode preflight: the sites, and R1 — is the generator even trying?
# A generator that produces two mutants per check and finds no survivor has measured its own
# timidity, not the suite. So the site count is printed and gated BEFORE anything runs.
# =========================================================================================
if [ "$FINE" = "1" ]; then
  echo "== fine mutation sites"
  total_sites=0; thin_checks=""
  for f in $CHECKS; do
    id=$(id_of "$f")
    capped=$(fine_sites "$f" | grep '^!CAPPED' || true)
    n=$(fine_sites "$f" | grep -vc '^!' | tr -d ' ')
    total_sites=$((total_sites + n))
    [ "$n" -ge 3 ] || thin_checks="$thin_checks $id($n)"
    ops=$(fine_sites "$f" | grep -v '^!' | cut -f3 | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}')
    printf '   %-4s  %2s sites  %s%s\n' "$id" "$n" "$ops" \
      "$([ -n "$capped" ] && printf '[CAPPED at %s of %s]' "$(printf '%s' "$capped" | cut -f2)" "$(printf '%s' "$capped" | cut -f3)")"
  done
  n_c=$(printf '%s\n' $CHECKS | grep -c .)
  avg=$(awk -v t="$total_sites" -v c="$n_c" 'BEGIN { printf "%.1f", t / c }')
  printf '   %s sites over %s checks, average %s per check\n' "$total_sites" "$n_c" "$avg"
  if [ -n "$thin_checks" ]; then
    echo "   R1 FAILED — fewer than 3 sites on:$thin_checks"
    echo "   A zero-survivor result from this generator would measure the generator, not the suite."
    exit 2
  else
    echo "   R1 ok — every check has at least 3 sites."
  fi
  echo
fi

# =========================================================================================
# Self-test — the instrument's own red-green, both directions.
# =========================================================================================
if [ "$SELFTEST" = "1" ]; then
  # One RUNTIME check and one STATIC check: they are written differently enough (the static
  # family greps the launcher's source through awk helpers) that proving the harness on an L
  # says nothing about an S. Probing only the first check in the file would do exactly that.
  probeL=""; probeS=""
  for f in $CHECKS; do
    case "$(id_of "$f")" in
      L*) [ -n "$probeL" ] || probeL="$f" ;;
      S*) [ -n "$probeS" ] || probeS="$f" ;;
    esac
  done
  rc=0
  for probe in $probeL $probeS; do
    echo "== self-test on $probe"
    run_mutant "$probe" GUARDED
    run_mutant "$probe" IDENTITY
    gk=$(specific_kills "$(id_of "$probe")" "$WORK/kills.$probe.GUARDED" | grep -c . | tr -d ' ')
    ik=$(grep -c . "$WORK/kills.$probe.IDENTITY" | tr -d ' ')
    if [ "$gk" -ge 1 ]; then echo "   ok   always-GUARDED mutant is KILLED ($gk named tests)"
    else echo "   RED  always-GUARDED mutant SURVIVED — the harness cannot see a kill"; rc=1; fi
    if [ "$ik" -eq 0 ]; then echo "   ok   identity mutant SURVIVES — no phantom kills"
    else echo "   RED  identity mutant killed $ik tests — the harness is breaking the tool, not mutating it:"
         sed 's/^/        /' "$WORK/kills.$probe.IDENTITY"; rc=1; fi
  done
  # The fine-specific arm. It cannot assert a kill (no fine mutant's lethality is known in
  # advance — that is the whole question), so it asserts what IS knowable: every fine mutant
  # of the probe checks builds, passes R2, and is DISTINCT from every other. A generator that
  # emits the same mutant twice would inflate any denominator computed from it.
  if [ "$FINE" = "1" ]; then
    for probe in $probeL $probeS; do
      echo "== self-test (fine) on $probe"
      built=0; bad=0; sums=""
      for kind in $(kinds_for "$probe"); do
        if build_mutant "$probe" "$kind" "$WORK/st.$probe.$kind"; then
          built=$((built + 1)); sums="$sums$(cksum < "$WORK/st.$probe.$kind" | awk '{print $1}')\n"
        else bad=$((bad + 1)); fi
      done
      uniq_n=$(printf '%b' "$sums" | grep -c . | tr -d ' ')
      dup_n=$(printf '%b' "$sums" | sort -u | grep -c . | tr -d ' ')
      if [ "$bad" -eq 0 ]; then echo "   ok   all $built fine mutants build and pass R2"
      else echo "   RED  $bad fine mutant(s) failed to build"; rc=1; fi
      if [ "$uniq_n" -eq "$dup_n" ]; then echo "   ok   all $built fine mutants are distinct files"
      else echo "   RED  $((uniq_n - dup_n)) duplicate mutant(s) — the site list double-counts"; rc=1; fi
    done
  fi
  echo
  exit "$rc"
fi

# =========================================================================================
# The matrix.
# =========================================================================================
n_checks=$(printf '%s\n' $CHECKS | grep -c .)
n_mut=0
for f in $CHECKS; do n_mut=$((n_mut + $(kinds_for "$f" | grep -c . | tr -d ' '))); done
echo "== $n_checks checks, $n_mut mutants, $JOBS at a time"
# Job control that works on the bash people actually have. macOS ships 3.2, where `wait -n`
# does not exist: it returns 2 without waiting, so the obvious `wait -n || wait` fallback ends
# up waiting for the WHOLE batch every time and the pool degrades to one job after the first
# round. Nothing on screen says so — measured here, at two live runs where six were asked for.
# So: a FIFO of pids, and an explicit wait on the oldest.
PIDQ=""
reap_oldest() {
  local first rest
  first=${PIDQ%% *}; rest=${PIDQ#* }
  [ "$first" = "$PIDQ" ] && rest=""
  [ -n "$first" ] && wait "$first" 2>/dev/null
  PIDQ="$rest"
}
qlen() { set -- $PIDQ; echo $#; }
for f in $CHECKS; do
  for kind in $(kinds_for "$f"); do
    run_mutant "$f" "$kind" &
    PIDQ="${PIDQ:+$PIDQ }$!"
    while [ "$(qlen)" -ge "$JOBS" ]; do reap_oldest; done
  done
done
wait
echo "   done."
echo

# =========================================================================================
# The verdict. One line per (check, mutant): who died, and whether anyone did.
# =========================================================================================
TSV="$WORK/matrix.tsv"; : > "$TSV"
survivors=0; thin=0; errors=0
for f in $CHECKS; do
  id=$(id_of "$f")
  for kind in $(kinds_for "$f"); do
    file="$WORK/kills.$f.$kind"
    if [ ! -f "$file" ]; then
      state="ERROR"; n=0; m=0; who="no result file"; errors=$((errors + 1))
    elif grep -q '^!' "$file"; then
      state="ERROR"; n=0; m=0; who=$(head -n 1 "$file"); errors=$((errors + 1))
    else
      n=$(specific_kills "$id" "$file" | grep -c . | tr -d ' ')
      m=$(generic_kills  "$id" "$file" | grep -c . | tr -d ' ')
      if   [ "$n" -ge 1 ]; then state="killed";       who=$(specific_kills "$id" "$file" | sed 's/   */ /g' | paste -sd '; ' -)
      elif [ "$m" -ge 1 ]; then state="generic-only"; who=$(generic_kills  "$id" "$file" | sed 's/   */ /g' | head -n 3 | paste -sd '; ' -); thin=$((thin + 1))
      else                      state="SURVIVED";     who="nobody"; survivors=$((survivors + 1))
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$state" "$n" "$m" "$who" >> "$TSV"
  done
done

if [ "$FINE" = "1" ]; then
  printf '  %-4s  %-5s  %-12s  %-6s  %-13s  %s\n' "id" "mut" "operator" "line" "state" "source line"
  printf '  %-4s  %-5s  %-12s  %-6s  %-13s  %s\n' "----" "-----" "------------" "------" "-------------" "-----------"
  for f in $CHECKS; do
    id=$(id_of "$f")
    for kind in $(kinds_for "$f"); do
      idx=${kind#F}
      site=$(fine_sites "$f" | awk -F'\t' -v i="$idx" '$1==i')
      ln=$(printf '%s' "$site" | cut -f2); op=$(printf '%s' "$site" | cut -f3)
      st=$(awk -F'\t' -v i="$id" -v k="$kind" '$1==i && $2==k { printf "%s %s/%s", $3, $4, $5 }' "$TSV")
      src=$(sed -n "${ln}p" "$DOCTOR_SRC" | sed 's/^ *//' | cut -c1-58)
      printf '  %-4s  %-5s  %-12s  %-6s  %-13s  %s\n' "$id" "$kind" "$op" "$ln" "$st" "$src"
    done
  done
  echo "   (state named/generic — a SURVIVED row is a hole OR an equivalent mutant; only reading it tells.)"
  echo
else
  printf '  %-4s  %-18s  %-18s\n' "id" "detection" "restraint"
  printf '  %-4s  %-18s  %-18s\n' "----" "------------------" "------------------"
  for f in $CHECKS; do
    id=$(id_of "$f")
    g=$(awk -F'\t' -v i="$id" '$1==i && $2=="GUARDED" { printf "%s %s/%s", $3, $4, $5 }' "$TSV")
    e=$(awk -F'\t' -v i="$id" '$1==i && $2=="EXPOSED" { printf "%s %s/%s", $3, $4, $5 }' "$TSV")
    printf '  %-4s  %-18s  %-18s\n' "$id" "$g" "$e"
  done
  echo "   (state named/generic — 'killed 3/0' = three tests built for this check went red)"
  echo
fi

if [ "$survivors" -gt 0 ]; then
  if [ "$FINE" = "1" ]; then
    echo "== SURVIVORS — nothing goes red with this one line changed. Each one is a hole OR an"
    echo "   equivalent mutant; classify by reading before publishing any number:"
    awk -F'\t' '$3=="SURVIVED" { print $1 "\t" $2 }' "$TSV" | while IFS="$(printf '\t')" read -r id kind; do
      for f in $CHECKS; do [ "$(id_of "$f")" = "$id" ] || continue
        idx=${kind#F}; site=$(fine_sites "$f" | awk -F'\t' -v i="$idx" '$1==i')
        ln=$(printf '%s' "$site" | cut -f2); op=$(printf '%s' "$site" | cut -f3)
        fr=$(printf '%s' "$site" | cut -f4); to=$(printf '%s' "$site" | cut -f5)
        printf '   %-4s  %-5s  %-12s  %s:%s\n        %s\n        %s → %s\n' \
          "$id" "$kind" "$op" "agent-chain-doctor" "$ln" "$(sed -n "${ln}p" "$DOCTOR_SRC" | sed 's/^ *//')" "$fr" "$to"
      done
    done
  else
    echo "== SURVIVORS — nothing at all goes red when this half of the check stops working:"
    awk -F'\t' '$3=="SURVIVED" { printf "   %-4s  always-%-8s\n", $1, $2 }' "$TSV"
  fi
  echo
fi
if [ "$thin" -gt 0 ]; then
  echo "== watched thinly — only a generic sweep noticed, no test built for this check did:"
  if [ "$FINE" = "1" ]; then
    awk -F'\t' '$3=="generic-only" { printf "   %-4s  %-8s  killed: %s\n", $1, $2, $6 }' "$TSV"
  else
    awk -F'\t' '$3=="generic-only" { printf "   %-4s  always-%-8s  killed: %s\n", $1, $2, $6 }' "$TSV"
  fi
  echo
fi
if [ "$errors" -gt 0 ]; then
  echo "== ERRORS (mutants that could not be built or run — not coverage, and not its absence):"
  awk -F'\t' '$3=="ERROR" { printf "   %-4s  %-8s  %s\n", $1, $2, $6 }' "$TSV"
  echo
fi

# A partial run must not clobber the full matrix: --only writes its own file. Overwriting 58
# rows with 4 and calling the result "the matrix" is the same lie this tool exists to catch.
OUTNAME="prove-red.tsv"; [ "$FINE" = "0" ] || OUTNAME="prove-red-fine.tsv"
[ -z "$ONLY" ] || OUTNAME="${OUTNAME%.tsv}-partial.tsv"
cp "$TSV" "$HERE/$OUTNAME" 2>/dev/null && echo "   matrix written to tests/$OUTNAME"
total=$(grep -c . "$TSV")
printf '\n================================================================\n'
printf '  %s mutants: %s killed by a named test, %s by a generic one only, %s SURVIVED, %s errors\n' \
  "$total" "$((total - survivors - thin - errors))" "$thin" "$survivors" "$errors"
printf '================================================================\n'
if [ "$thin" -gt 0 ] && [ "$STRICT" = "0" ]; then
  echo "  (exit 0 all the same: $thin mutant(s) are watched thinly. --strict makes that fatal.)"
fi
[ "$survivors" -eq 0 ] && [ "$errors" -eq 0 ] || exit 1
[ "$STRICT" = "0" ] || [ "$thin" -eq 0 ] || exit 1
exit 0
