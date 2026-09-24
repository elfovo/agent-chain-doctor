# agent-chain-doctor

> Written end-to-end by an autonomous AI agent (Claude Code). It is one file — read it before
> you run it. Details in [Origin of this work](#origin-of-this-work).
>
> **Zero EXPOSED means "these 29 checks found nothing" — never "your chain is fine".** The
> false-negative rate is unknown and will stay unknown; [What it does not
> do](#what-it-does-not-do--read-this-before-trusting-a-clean-report) says why.

**You scheduled an agent to run while you sleep. This reads the traces its chain leaves on disk
and tells you which known ways of stopping silently it is currently exposed to.**

It is *not* a liveness monitor and it cannot tell you your agent is doing good work. It is one
shell script — no dependencies, no network, no writes, no privileges — that inspects a scheduled
agent chain (launchd / cron / systemd + the session script they run) and returns, for each of
29 checks, **exposed**, **guarded** or **undecidable**, with the evidence that establishes the
verdict.

```sh
curl -fsSLO https://raw.githubusercontent.com/elfovo/agent-chain-doctor/main/agent-chain-doctor
chmod +x agent-chain-doctor
./agent-chain-doctor
```

One file. Nothing is added to your system, no package manager is involved, and you can delete it
afterwards with `rm`. (`git clone` works too; the executable bit is in the index.) It runs on the
stock macOS `/bin/bash` — bash 3.2 — and on any later bash.

---

## Why this exists

An unattended agent fails in a way nothing else does: **silently**. The scheduler does not
complain — it fired, the script exited, status 0. The agent is not there to shout. The only
symptom is an absence, and nobody notices an absence. You find out four days later that the chain
stopped on the second night, when you go looking for work that was never done.

The five shapes below come from **one chain — mine**. Each either stopped it or was found in a
cold audit of it. I have no data on how common they are elsewhere; only the belief that the shapes
are generic enough to be worth looking for.

- `date … > wakeup` truncates the file *before* running `date`, so one failing `date` leaves an
  empty trigger and the chain never wakes again.
- A crashed session leaves a lock that nothing clears.
- `trap 'cleanup' TERM` looks complete and lets the script keep running after the signal.
- The scheduler hands the agent a `PATH` that does not contain the agent's own binary.
- The laptop sleeps through the work window.

Every one of those leaves a trace on disk. This tool goes and looks.

---

## Usage

```
agent-chain-doctor [--verbose] [--plist FILE] [LAUNCHER]

  LAUNCHER       path to the session script your scheduler runs. This is the recommended form
                 and the only one that guesses nothing. At most one may be given.
  --plist FILE   the LaunchAgent plist that runs it (macOS), if discovery misses it. Works with
                 or without a LAUNCHER: on its own, the launcher is read out of the plist.
  --verbose, -v  print the evidence under GUARDED and UNKNOWN too, not only under EXPOSED.
                 (-v is verbose here, NOT version. The version flag is --version, spelled out.)
  --version      print the version and exit.
  --help, -h     the same text.
```

With no `LAUNCHER`, it looks through **your own user's** scheduler entries — launchd agents, your
crontab, your systemd user timers — for something shaped like an agent chain, and prints what it
found before diagnosing anything. Candidates are scored on five markers and anything below 2/5 is
rejected; if nothing clears that floor it says so and stops rather than diagnosing the least-bad
guess. A file that is not a `#!` script, or a script with no resolvable control files, is refused
outright.

**Exit codes:** `0` nothing EXPOSED · `1` something EXPOSED · `2` the tool refused to diagnose.
Three values and no richer scale — a rich exit code invites automating it blind. **A `2` is not a
clean bill of health: it means no diagnosis happened.**

It refuses, and returns `2`, in every one of these cases: a bad or empty option, two launchers
named at once, an unreadable clock, a target that is not a file or does not start with `#!`, a
`--plist` that cannot be read or that names no readable script, no chain found by discovery, and
a script that resolves none of the four control files (log, lock, wakeup, prompt). That list is
the whole of it — not an illustration.

### What a run looks like

Real output, **captured 2026-09-04**, on a deliberately broken chain — findings trimmed to the
first few and nothing else edited. It is dated because it is a capture and captures go stale:
the block that stood here until 2026-09-04 was a faithful run of the 26-check version, and its
counters still added to 26 six lines above a sentence promising they always add to 29.

```
agent-chain-doctor 1.1 — read-only: it writes nothing and opens no socket.
Verify that yourself: bash tests/run-tests.sh, cases T35 to T39.

CHAIN
  scheduler   not identified — diagnosing the launcher alone
  launcher    /tmp/demo/session.sh   (matched 4/5 markers)
  state dir   /tmp/demo/state
  prompt      /tmp/demo/state/prompt.txt
  no scheduler entry matched this launcher — L1 and L12 will say UNKNOWN. Point at it with --plist if you have one.

FINDINGS
  EXPOSED  L10  429 sleep transitions in the window, and nothing keeps the machine awake [live]
                    429 sleeps between 0:00 and 6:00 over the last 7 days (a default window —
                    the launcher declares none this tool can use)
                    no caffeinate or systemd-inhibit call found in session.sh
                    sessions launched in that window are being suspended mid-run
  EXPOSED  S1   the wakeup file is written by truncating redirection [static]
                    session.sh:11: date -v +${MINUTES}M +%s > "$WAKEUP_FILE"
                    the redirection truncates before the command on its left runs; a command
                    that fails leaves an EMPTY trigger
                    an empty trigger is read as 'no wakeup' by most launchers: silent stop,
                    every tick, forever
  EXPOSED  S2   every trap covers EXIT only — none covers INT/TERM/HUP [static]
                    session.sh:9: trap 'rmdir "$LOCK"' EXIT
                    EXIT does not run on SIGTERM: a scheduler bootout or a reboot leaves the
                    lock owned by nobody
                    every session after that exits on the orphan lock until it ages out
  …
  GUARDED  L4   the wakeup file holds a well-formed epoch    [live]
  GUARDED  L11  the prompt file exists and has content       [live]
  UNKNOWN  L1   last probe exit code not readable            [live]
  …
  5 exposed · 4 guarded · 20 unknown
  (--verbose prints the evidence under GUARDED and UNKNOWN too)

[ask] five things this tool cannot see — answer them yourself
  Q1  Does every session write a journal entry, including the empty ones? …
```

**The 29 checks always report — all of them, exactly once, whatever your chain looks like.** The
three counters always add up to 29. A check that finds nothing to measure says `UNKNOWN` and says
what it was missing; none of them may quietly not appear. (That guarantee is younger than the
tool: three checks used to vanish when their subject was absent, and no test noticed. Cases T68 to
T71 now hold it.)

---

## The three verdicts, and the two levels of proof

There are three verdicts and there is no fourth:

| Verdict | Means |
|---|---|
| `EXPOSED` | a proof of the defect was found — the proof is printed under the verdict |
| `GUARDED` | a proof of the protection was found — the proof is printed with `--verbose` |
| `UNKNOWN` | this check could not decide — and it says exactly what it was missing |

**There is no "OK".** A check that measured nothing returns `UNKNOWN`, never `GUARDED`. An
instrument that answers "all fine" when it measured nothing is worse than no instrument: it
manufactures a confidence no measurement supports. For the same reason the report has no green
summary line at the end. It counts the three verdicts and stops.

Evidence is printed **under every `EXPOSED`, always**; `--verbose` adds it under `GUARDED` and
`UNKNOWN` too. The default lists those two without their proof, because the ones you have to act
on are the red ones.

Every finding carries **where its conclusion comes from**, because that is part of the conclusion:

- **`[live]`** — state of the system. A file exists or it does not, a pid is alive or dead, an
  epoch is in the past or it is not. These are facts and carry no reserve.
- **`[static]`** — a pattern in the launcher's source. A heuristic. It reads shell it did not
  write, so it misses things and it can recognise a dangerous shape in a context where the shape
  is not dangerous. Every static finding prints `file:line` and the line itself, so you can go and
  read it. You decide; the tool only points.

A finding you cannot verify yourself is not a finding. That rule is why the evidence line is
mandatory rather than an option.

---

## What it does not do — read this before trusting a clean report

**The false-negative rate is unknown, and it will stay unknown.** Each check was tested against a
purpose-built launcher fixture broken in exactly one place: at least one red fixture per check —
**42 in all, measured 2026-09-07, several checks having more than one** — plus a correct launcher on
which no check may fire, and four launchers written in *another* idiom whose only job is to prove
that a correct chain the author would not have written is still read correctly.

The 42 had been asserted, never counted. Counted now, and here is the rule so you can re-run it:
of the **153** fixtures the suite builds, a fixture is *red* when at least one `expect … EXPOSED`
assertion is made on it — 42 are, and between them they cover **all 29 checks**, none left out.
Ten of the 42 sit outside the two "one fixture per check" sections — `a1` `a2` `a4` `a5` `a7`
`l2d` `l4kv2` `l12n` `b3` `l8c` — which is why a count taken by reading those two sections alone
comes back short. `L8` is the thin one: its only red fixture, `l8c`, is one of those ten.

**The two sentences that stood here were both wrong, in opposite directions, and both are
replaced by a count (2026-09-04).** They said *twenty-seven of the 29* have a fixture proving
they can return `GUARDED`, and that *only 13 of the 29* have one pinning `UNKNOWN`. Measured by
reading the suite: every assertion of the `expect…` family that names a verdict and an id
(continuation lines joined, comments excluded), plus the two cases that pin a verdict by matching
the report text directly rather than through a helper (`T111` on `S5`, `T124` on `S14`) — leaving
those two out is how the same count first came back one short here:

| a named assertion pins this verdict, on this check | measured |
|---|---|
| `EXPOSED` | **29 of 29** (2026-09-04) |
| `UNKNOWN` | **29 of 29** (2026-09-04) — it really was 13 when that was written on 2026-08-30; the passes of 2026-08-31 and 2026-09-03 took it to 22 and then 29, and the sentence never moved |
| `GUARDED` | **27 of 29** (2026-09-10) — missing on `L4` and `L6`, and on nothing else |

**The `GUARDED` line has now been wrong twice, in opposite directions, and the second error was
this page's own correction of the first.** A sentence here long claimed *twenty-seven of the 29*
without ever counting; on 2026-09-04 a count replaced it with **21 of 29**, naming six more gaps
(`S1`, `S6`, `S10`, `S11`, `S12`, `S15`) and calling the old sentence over-stated. Those six were
never gaps. `T51` asserts `GUARDED` by name on **all sixteen** static checks against the correct
launcher, and it is green — so every one of those six `GUARDED` branches is exercised by a named
assertion, and has been for longer than the table has existed. The uncounted sentence was right;
the count was wrong. Only `L4` and `L6` are real, exactly as first written.

**How a count went under, and why it is the same defect the tool sells.** `T51` is a loop —
`for sid in S1 … S16; do expect "…" GUARDED "$sid"; done` — so its check id is a **variable**,
not a literal. The counting rule read assertion call sites for a literal id, and this one site
is the only one in the suite that has none. The suite's own static pass says so out loud, every
run: *170 assertion call sites read — 169 with a literal id, 1 with a computed id.* The instrument
that would have caught this was already printing the answer above the number that was wrong.

So the honest lesson is not the tidy one this paragraph used to draw (*a count of how well
something is proven drifts upward; a count of how much of it there is drifts downward*). It is
narrower and less comfortable: **a count is only as wide as the shape it matches, and a number
obtained by counting is not thereby more true than the sentence it replaces.** Measuring beat
believing on `UNKNOWN`, where the drift was real and large. It lost on `GUARDED`, because the
rule quietly excluded sixteen assertions written as one loop. A count that disagrees with a
standing claim is a reason to go read both — not a reason to publish the count.

*Re-run it yourself:* `grep -nE 'expect(_because|_evidence)? .*GUARDED' tests/run-tests.sh`
returns the literal-id sites; the loop at `tests/run-tests.sh:562` is the sixteen the grep cannot
see, and `bash tests/run-tests.sh 2>&1 | grep T51` shows them passing.

`UNKNOWN` is still the side to watch, and the reason has not changed: a check that can only be
seen firing and being quiet has not been shown to abstain for the right reason. That proves every check *can* fire on the defect it was
written for. It proves nothing whatsoever about defects the catalogue never thought of — and
the defects and the checks have the same author. **A report with zero EXPOSED means "these 29
checks found nothing", not "your chain is fine".**

Four more limits, stated here rather than discovered later:

- **Static checks read shell they did not write.** They strip comments before matching (a launcher
  that quotes its own past bugs next to the fix — a common and good habit — would otherwise be
  accused of having them), they read the *union* of every `trap` in the file rather than one trap
  in isolation, and each one requires a **positive** pattern to return `GUARDED`. All of that
  reduces false positives; none of it eliminates them.
- **Run `shellcheck` as well.** It parses; this only pattern-matches, and the two find different
  things. Nothing here duplicates a shellcheck rule: the static checks are about properties of a
  *scheduled chain* — an invariant between two timeout settings, a missing cap on a wakeup value,
  a `|| echo 0` that makes a timestamp look infinitely old — not about shell correctness.
- **It sees the parts of your chain that leave traces on disk.** Not your agent's judgement, not
  your prompt's contract, not what happened inside a session. Five of the failure modes it was
  built from are *practices*, not file states — they come out as the five questions the report
  ends on, not as checks.
- **Linux coverage is thinner than macOS coverage, and less thin than this section used to
  claim.** Discovery handles crontab and systemd user timers, and the portable fallbacks
  (`stat -c`, `date -d`) are there. This paragraph used to warn that four live checks — L1 (last
  exit status), L10 (sleep history), L12 (the scheduler's `PATH`), L13 (error-path divergence) —
  "have no launchd registry to query" on Linux. **Two of the four were wrong, and they were wrong
  in the direction that costs a reader most: the tool printed an absence about something present.**
  systemd keeps both facts and hands them over for free — `ExecMainStatus`/`Result` for L1, and
  the unit's `Environment=` falling back to the manager environment for L12 — and the tool simply
  never asked. It asks now, on both the discovery path and the named-launcher path. Measured on
  systemd 255 on 2026-09-21 against a real user timer, not reasoned about: on that chain L1 went
  from "last probe exit code not readable" to a read status, and L12 from "the scheduler's PATH is
  unknown" to a verdict on the PATH the unit actually runs with. Of the four, **L13 keeps its
  `UNKNOWN` honestly** (systemd declares `StandardError=`, but as a journal, and the check is
  about two *file* paths diverging) and **L10 is still unmeasured** — the machine that made this
  measurement possible is a VM that never sleeps, so there was no sleep history to read and
  nothing was changed there on a guess. On a cron chain, naming the launcher still skips the
  crontab walk, so L13 loses its second error path and L9 loses the "the scheduler invokes it
  directly" test. Run it both ways if the answers differ.

### Where it *has* been measured — including on four chains the author did not write

Two runs on the author's own chains, which prove nothing about anyone else's. **Both were
captured on 2026-08-29, when the tool had 26 checks** — which is why their three counters add up
to 26 and not to the 29 the guarantee above promises. They are left as captured rather than
quietly edited upward:

- On a reference launcher **installed for real** — plist loaded with `launchctl bootstrap`, state
  primed, first wakeup an hour out, chain at rest — diagnosed with an argument and again with
  none: **0 EXPOSED, 21 GUARDED, 5 UNKNOWN**, identical both ways.
- On a chain the author wrote a year before the tool existed, whose variables are named in French
  and which the tool had to find on its own among eleven LaunchAgents: **0 EXPOSED, 22 GUARDED,
  4 UNKNOWN**, in 2.1 s.

Neither run is reproducible from this repository — neither launcher ships here — and both chains
were written by the author of the checks. Treat those two as a non-regression result **of the
26-check version**, not of this one. Re-running them would need two launchers this repository does
not ship; inventing the three numbers the 29-check tool *would* print is the one thing that is not
allowed here, so the stale capture stays, dated and labelled. This is the same defect the
*What a run looks like* block carried until 2026-09-04, in a second place, 130 lines below the
sentence it contradicts — the session that fixed the first one did not look for a second.

**And one run that is not the author's.** Four agent chains were written by four authors who had
never seen this code, its name, or the list of checks, each in an idiom the author does not use
(`sh` + cron, `bash` + systemd, `zsh` + launchd, `bash` + `python3` + cron). Two of them were
asked to leave silent-stop defects of *their own choosing*, declared in a separate file — because
a list of defects written by the author of the checks is a list the checks catch by construction.
The denominator, and three predicted false positives, were committed before the tool was run once.

The number, and it is not a good one:

> **The tool found 6 of the 12 defects that fall inside the 26 checks it then had: 50%.**
> On this corpus, half of what it was built to name, it named — file and line, correctly. The
> other half it was silent about.

Three of the six it missed are *dormant*: real in the code, but the chain had not failed yet, so
the thirteen live checks had nothing on disk to read. **That is the shape of the miss you should
expect** — if you run this before anything has broken, roughly half the catalogue cannot speak.
Excluding the dormant three would put the rate at 6 of 9, and that is the flattering way to count
it; the sealed denominator said "dormant included", so 50% is the number.

The first pass, before the repairs below, scored **5 of 12 with three false verdicts**. What the
foreign chains actually bought was the repairs: **ten defects in the tool**, none of which was
visible on the test suite — which passed then and passes now, because its fixtures are written by
the author, in the author's idiom. The two worst: a chain declaring its paths with
`readonly LOG=…` was refused outright (**zero of the 26 checks it then had ran**), and an empty positional
argument made the tool diagnose *a different chain* at exit 0. Both are fixed, each with a test
seen red first.

The corpus is versioned with the experiment and the run is reproducible, mtimes included.

---

## The 29 checks

**Live state** — exact, no reserve.

| | Asks |
|---|---|
| L1 | What exit code did the probe's last run return, according to the scheduler itself? |
| L2 | Is the chain registered and silent past a wakeup that has already come due? |
| L3 | Is the probe's error file filling up, and does anything ever drain it? |
| L4 | Is the wakeup file present but empty, or present but not a number? |
| L5 | Is the next wakeup within a sane range, or a millisecond epoch / a year away? |
| L6 | Does the lock have the shape the launcher expects (plain file vs directory)? |
| L7 | Is there a stale lock whose owner process is dead? |
| L8 | Has a session been running far past any plausible budget? |
| L9 | Is something the chain invokes *directly* missing its executable bit? (Exit 126, silently.) |
| L10 | Did the machine sleep during the hours the chain is supposed to work? |
| L11 | Does the prompt file — the whole session contract — exist and have content? |
| L12 | Does the scheduler's `PATH` actually resolve the agent's binary? |
| L13 | Do the scheduler and the launcher name *different* error files? |

**Static patterns** — heuristics on the launcher's source, each printing `file:line`.

| | Asks |
|---|---|
| S1 | Is the wakeup written by truncating redirection instead of temp-then-rename? |
| S2 | Do the traps cover a kill signal, or only `EXIT`? |
| S3 | Does every kill-signal handler actually terminate the script? |
| S4 | Is a failed `mkdir` told apart from a lost race for the lock? |
| S5 | Does a `\|\| echo 0` fallback make an unreadable timestamp look *infinitely old*, so a live session's lock gets deleted? |
| S6 | Is an idle probe divided into zero before being compared? |
| S7 | Is the keep-awake wrapper unconditional *and* unresolvable in the scheduler's environment? |
| S8 | Does anything bound the agent's run, or can one hung call hold the chain forever? |
| S9 | Is arithmetic done on a zero-padded hour? (`08` is invalid octal; bash dies.) |
| S10 | Is the value read from the wakeup file trusted as a number without being one? |
| S11 | Does anything cap the wakeup value, or does one bad write park the chain in 2189? |
| S12 | Does the invariant *between* two settings hold — the class no single-value check sees? |
| S13 | Is a default armed (`:=`) on a variable whose empty value is a security decision? |
| S14 | Is the wakeup shown as a readable time without having been checked as a number? (`date -r 0` prints "Thu 01:00" instead of failing.) |
| S15 | Is the agent's exit code captured, logged, and never acted on? |
| S16 | Is the spacing marker stamped only at the *start* of the session, so the floor stops biting after the longest ones? |

The last three are a different shape from the first thirteen, and it is worth knowing why. Each
of those looks for a dangerous pattern; these three look for a **construction** and then for the
reading that gives it meaning. They exist because on 2026-08-30 this tool was pointed at the same
launcher before and after three defects of that family were repaired in it, and printed a report
identical line by line on both. A pattern-matcher cannot see a line that is not there. When the
construction itself is absent — no wakeup ever formatted, no exit code ever captured, no marker
anything paces on — they answer `UNKNOWN`, never `GUARDED`.

---

## Running the tests

```sh
bash tests/run-tests.sh            # every case must pass — the suite prints its own total
LEGACY=1 bash tests/run-tests.sh   # most must go RED — it prints that total too
```

The counts are not repeated here: the suite recomputes and prints them on every run, and a number
copied out of a run is a number that starts going stale the next time a case is added. Where a
count *is* given below, it carries the date it was measured.

No network, no fixture outside a temporary directory the suite cleans up. Two cases read the
wall clock — a 20-second upper bound on diagnosing a 400-line launcher, and a 2-second sleep to
age a session past its budget — so a heavily loaded machine can turn those two red without a bug.

**The suite refuses to run as root**, and says why: two cases (`T185`, `T189`) build a file the
tool must find unreadable, and `[ ! -r ]` is false for root — under root they would land on a
different branch of the same check, stay green, and certify a branch they never reached. A pass
looks identical either way, so nothing inside a test file can catch it. `ALLOW_ROOT=1` runs anyway
and those two are then to be read as unproven. This is the same rule the tool applies to itself:
what could not be measured is not reported as measured.

`LEGACY=1` rebuilds a **neutralised** copy of the tool, with every check returning immediately,
and runs the suite against it: **188 of the 228 went red on 2026-09-06**. A test never seen red
proves nothing, so the suite carries its own way of being seen red.

**40 stayed green that day, and here is the whole list rather than a sample.** An earlier version of this
paragraph named two of them and left the reader to assume that was all — it was not, and the fix
belongs in the open. A neutralised tool detects nothing, so every test asserting that *nothing* is
detected passes trivially; and neutralisation leaves discovery, argument handling and the
read-only guard intact by design. The 40 are:

| why it is green on a neutralised tool | count | which ones |
|---|---|---|
| asserts an **absence** — a silent tool satisfies it for the wrong reason | 11 | `T01` `T02` `T05` `T39` `T42` `T65` `T66` `T67` `T105` `T134` `T161` |
| **static properties of the source file**, which neutralisation does not rewrite | 8 | `T35` `T35b` `T36` `T36b` `T37` `T38` `T38b` `T71c` |
| **argument handling and report shape**, untouched by neutralisation | 11 | `T43` `T45` `T46` `T49` `T50` `T73` `T74` `T75` `T76` `T77` `T83` |
| **discovery and classification**, untouched by neutralisation | 5 | `T03` `T04` `T34` `T51` `T80` |
| the suite's **own instruments**, which never run the tool | 5 | `T152` `T159` `T160` `T197` `T198` |

The whole list is given rather than a sample, because the boundary between the first two rows is a
judgement call and you should be able to check it: `T39` ("an observed run modified nothing") reads
like a static guarantee but is an observation of a run, so it sits with the absence assertions;
`T80` (an ancestor directory named `next` must not hijack the classification) is grouped with
discovery rather than with argument parsing.

Eleven of the 40 are the honest weak spot: an absence assertion cannot be seen red this way, only
differentially. That is what the mutation matrix below is for, and it is why `LEGACY` is presented
here as one proof and not the proof.

### Does the suite actually watch each check?

`LEGACY=1` neuters all 29 checks at once, which proves the suite needs *some* check to be there.
It does not prove that any test would still go red if **one** check stopped working. So:

```sh
bash tests/prove-red.sh --self-test   # the harness proves itself, both directions
bash tests/prove-red.sh               # the full matrix (58 cells: 29 checks × 2 mutants)
bash tests/prove-red.sh --only L1,S8  # a subset, while iterating
bash tests/prove-red.sh --jobs 1      # serial. The default is 6, and measurably slower --
                                      # see the timing table below before you raise it
```

**How long the full matrix takes.** It used to say "~30 min on 8 cores" — a number nobody had ever
measured, and which the measurements since have refuted. Here is what is measured, on an 8-logical
/ 4-performance-core M-series Mac:

| what | measured | date |
|---|---|---|
| one full pass of `run-tests.sh` (what every cell runs, on top of building its mutant) | **68.9 s** wall, of which **47.6 s is `sys`** | 2026-09-09 |
| `tests/prove-red.sh --only L1 --jobs 1` — baseline pass + 2 static passes + **2 cells, serial** | **3 min 30 s** wall (93 s user, 145 s sys) | 2026-09-10 |
| the one full matrix ever timed end to end — 292 `--fine` cells at `--jobs 3` | **6 h 57** | 2026-09-04 |

Subtract the baseline pass from the second row and a cell costs **~70 s of wall clock, serial** —
which lines up with the first row: a cell is essentially one suite run, and building the mutant is
noise beside it. The full 58-cell matrix is therefore **about 70 minutes. Budget an hour and a
sixth.** That figure is still an extrapolation from 2 cells to 58, but every input in it is now a
stopwatch reading rather than a guess; the cells do identical work, so the line is straight.

**Do not reach for `--jobs` to make that shorter — it makes it longer.** The third row is 292 cells
in 6 h 57, i.e. **85.7 s of wall clock per cell while three ran at once**, against **70 s per cell
running them one at a time**. Three workers did not merely fail to help: each cell came out **~21 %
slower**. That is what a suite bound by filesystem syscalls does on four performance cores —
the workers queue behind the same resource and pay the contention on top. The default is `--jobs 6`,
which is very likely worse still. If you want the matrix to finish sooner, the lever is the 47.6 s
of `sys` in row one, not the core count.

*Caveat, stated because the comparison is the interesting part:* rows two and three are not the same
kind of cell — row two builds coarse mutants, row three fine ones. Both are dominated by the same
68.9 s suite run, which is why they are compared at all, but a fine cell is not proven to cost
exactly what a coarse one costs.

For each check it builds two mutants of this file — one line inserted, everything else identical —
and runs the whole suite against each. **always-GUARDED** destroys that check's detection;
**always-EXPOSED** destroys its restraint. A mutant that no test *named for that check* kills is a
survivor: for that half of that check, the suite is green for a reason unrelated to the code.

Measured on v1.1, 2026-08-30: **58 mutants, 58 killed by a named test, 0 survivors, 0 killed only
by a generic sweep.** Two things that figure does *not* claim, stated here so nobody has to guess:
the mutants are coarse (a whole verdict replaced, not a flipped comparison), and **22 of the 58
hang on a single named test** — `prove-red.tsv` says which, and that is where to add a test first.

#### Fine mutants — and they put a number on that caveat

```sh
bash tests/prove-red.sh --fine --list-sites   # instant: the sites, no suite run
bash tests/prove-red.sh --fine --only L1,L3   # one token changed per mutant, not a whole verdict
```

A fine mutant flips one branch's verdict, drops one `!`, relaxes one `-eq`, or neutralises one
`return`. The check keeps answering correctly almost everywhere.

**Read the two columns below in this order, or you will read the wrong number.** The first three
runs cover **9 of the 29 checks** — the ones whose *both* halves hung on a single named test. The
fourth covers **all 29**. The tool did not change between any of the runs, so within a perimeter
the difference is the suite and nothing else:

| on the same 77 sites | 2026-08-30 | 2026-08-31 | 2026-08-31 |
|---|---|---|---|
| killed by a **named** test | 42 (55 %) | 63 (82 %) | **64 (83 %)** |
| killed by a **generic** sweep only | 5 | 13 | **13** |
| **SURVIVED** | **30 (39 %)** | **1 (1.3 %)** | **0** |

| all 29 checks | the 9 above | the other 20 | total |
|---|---|---|---|
| mutants | 77 | 215 | **292** |
| killed by a **named** test — *2026-08-31* | 64 | 121 | **185** |
| killed by a **generic** sweep only — *2026-08-31* | 13 | 35 | **48** |
| **SURVIVED** — *2026-08-31* | **0** | **59 (27 %)** | **59 (20 %)** |
| killed by a **named** test — *2026-09-04* | 64 | **157** | **221** |
| killed by a **generic** sweep only — *2026-09-04* | 13 | **46** | **59** |
| **SURVIVED** — *2026-09-04* | **0** | **12 (5.6 %)** | **12 (4.1 %)** |
| killed by a **named** test — *2026-09-06* † | 64 | **168** | **232** |
| killed by a **generic** sweep only — *2026-09-06* † | 13 | **35** | **48** |
| **SURVIVED** — *2026-09-06* † | **0** | **12 (5.6 %)** | **12 (4.1 %)** |

† **The 2026-09-06 row is not a full re-run and is marked so on purpose.** Eleven cells were
re-measured individually — the eleven dropped-`return` sites, each mutant rebuilt and run against
the whole suite — and each moved from *generic only* to *named*. The remaining 281 are carried over
from 2026-09-04 unchanged, on a stated basis: the tool is byte-identical and the suite watches the
same 147 runs, so the generic sweep cannot have caught anything new. A row derived this way is
weaker than a measured one; publishing it as measured would be the sort of quiet arithmetic this
page has already had to correct twice.

The 2026-09-04 row is the full re-run promised below, on the same 292 sites. **Read the two
`59`s in this table as the different quantities they are**: 59 *survivors* on 2026-08-31, 59
*killed by a generic sweep only* on 2026-09-04. The coincidence is arithmetic, not a figure that
stayed put — the survivor count fell to **12**.

The first run's shape was the finding, and it was ugly: `UNKNOWN` → `GUARDED` survived **16 out of
16**. The suite carried 42 `EXPOSED` assertions, 25 `GUARDED` and 19 `UNKNOWN` — not one of the 19
on those nine checks. This tool's whole argument is that it says *I do not know* instead of
claiming a protection it never measured, and that was the one verdict its own suite never checked.
Twenty assertions later, all sixteen are killed by a named test — **on those nine checks. Across
all 29, the same mutation was killed 28 times out of 63** when that figure was published on
2026-08-31; nineteen more branches were closed on 2026-09-03, which takes it to **47 of 63**. The
`16/16` was true on its perimeter and false as a statement about the tool; the paragraph after next
says exactly how far the hole went and what is left of it.

The last survivor was `S4:1933`, `[ -n ` → `[ -z `: the check falls back to its generic `mkdir`
pattern, and in every fixture that existed it picked the same line, so the report came out
identical. It is dead now — a fixture whose launcher creates some *other* directory before taking
its lock separates the two, and it takes **two** assertions, not one: the verdict *and* the address
the verdict is built on. A check can reach the right verdict off the wrong line.

**What the 0 does not say, and it matters more than the 0.** Thirteen cells are still killed by a
generic sweep only — twelve of them `return`-drop mutants, where the check emits twice and no test
written for that check notices — and **eight of the 77 (10 %) are killed by `T152` alone**, the
automatic duplicate-id recording. **That number did not move**: the same eight cells, before and
after. What changed is that `T152` now has a red proof of its own (`T159`), so breaking it is
*visible*. Until this run, neutering that one sweep left the suite 100 % green with a tenth of its
coverage switched off. This is a gain in **detectability, not in coverage**, and a headline `0`
that let you assume otherwise would be the same lie by omission the `1` was published to avoid.

Across all 29 checks the concentration is the same, not worse and not better: **36 of the 292 cells
(12 %) are killed by `T152` alone** when this was measured on 2026-08-31. It was not an artefact of
the narrow perimeter. One test carries an eighth of this matrix.

**On 2026-09-04 that figure went the wrong way: 47 of 292 (16 %).** One test then carried a sixth of
the matrix, and the eleven cells it had gained are the subject of the next paragraph. That was the one
number on this page to get *worse* while everything around it improved, and it was reported here
rather than left for a reader to derive.

**On 2026-09-06 it is back to 36 of 292 (12 %)** — eleven named assertions (`T199`–`T209`), one per
dropped-`return` site, each attached to the fixture that already walked that site. **How that 36 was
obtained, because it is not a re-run of the matrix and should not be read as one:** the eleven cells
were measured one by one, by building each mutant and running the whole suite against it — all
eleven now go red on their own named test *and* on `T152`, where before they went red on `T152` and
nothing else. The other 281 cells are **carried over, not re-measured**, on two facts that are
themselves checked: the tool is byte-identical, and the suite still watches **147 runs** — exactly as
many as before — because these assertions read the output of runs that already existed and add none.
`T152`'s sweep therefore cannot have widened, and an added assertion can only add a killer, never
remove one. The full 292-cell re-run is the way to close that gap and it takes about seven hours;
until one is published here, treat the 36 as **eleven measured cells over an unchanged remainder**.

#### The other 20 checks, now measured — and the honest version is unflattering

Until 2026-08-31 this section said the 9-check perimeter had been *picked to maximise the chance of
finding holes, not to represent the tool*. **The full run says the opposite, so here is the
correction rather than a quiet edit.** The 20 checks left out have **59 survivors (27 %)** where the
9 "promising" ones have **0**. The sample was optimistic, not pessimistic.

Split by what the mutant makes the tool *say* — the column that matters, since the operator, not
the site index, is what carries meaning:

| the mutant makes the tool say | the 9 checks | the other 20, 2026-08-31 | the other 20, 2026-09-04 |
|---|---|---|---|
| **"I don't know" → "it's protected"** (`U2G`) | **0 / 16 survive** | **35 / 47 survive** | **0 / 47** |
| the check emits twice (`return` dropped) | 0 / 12 | 11 / 46 | **0 / 46** |
| one condition inverted (`-n`→`-z`) | 0 / 18 | 5 / 43 | 4 / 43 |
| "it's exposed" → "it's protected" | 0 / 8 | 3 / 18 | 3 / 18 |
| "it's protected" → "it's exposed" | 0 / 10 | 2 / 16 | 2 / 16 |
| one comparison relaxed (`-gt`→`-ge`, …) | 0 / 1 | 3 / 5 | 3 / 5 |

**The second row is the finding of the 2026-09-04 run, and nobody aimed at it.** All 35 assertions
written on 2026-09-03 targeted `U2G`; not one was written for a dropped `return`. That operator
still went from 11 survivors to 0. The mechanism is exact and worth stating, because it is the
same fact as the `T152` regression above rather than a second piece of good news: dropping a
`return` makes a check emit **twice**, so it trips `T152`'s duplicate-id sweep — but only if some
test actually *runs* that code path. The 35 new assertions added 35 new runs, those runs walked
the eleven dropped-`return` sites, and `T152` collected them. **Eleven cells stopped being
survivors without anyone writing a test for them, and for two days all eleven were held by one
generic sweep.** Coverage bought that way is real but thin: it would have evaporated if those 35
assertions were ever deleted, and no named test would have noticed.

**Closed on 2026-09-06, and this is the part worth copying rather than the number.** Each of the
eleven sites is a `return` under an `UNKNOWN` finding — *I could not measure this*. Dropping it makes
the check answer twice: once honestly, then again on the branch below, about a value it never read.
Eleven assertions now say so by name — `L2` must abstain **once** for want of a log path, `S8` **once**
for want of a call to bound — each on the fixture that was already reaching that branch for another
reason. No new fixture, no new run: the assertions were missing, not the coverage. The red proof is
the same eleven mutants, each rebuilt and run against the new suite: **11 of 11 kill their own named
test**, one-to-one, and each also still trips `T152` — which is the point, since a property should
have both a named witness and a sweep, not a sweep alone.

The split is clean rather than gradual: **every one of the 20 unworked checks has at least one
surviving `UNKNOWN` → `GUARDED` mutant, and none of the 9 worked ones has any.** **Nine** were open
on *all* their `UNKNOWN` branches — `L5`, `L6`, `L8`, `L12`, `S2`, `S3`, `S7`, `S8`, `S9`. On
`check_L8_long_session`, all four of its "I cannot tell" answers could be replaced by "this is
protected" without a single one of the 178 tests going red.

**Those nine are closed as of 2026-09-03, and the tense above changed with them.** Nineteen
assertions — one per `UNKNOWN` branch, each pinning *what the tool said* and not merely its
verdict — brought the suite to 197 cases. Each was measured against the mutant of its own line,
serially, on a frozen snapshot: **19 mutants, 19 killed, and every one of the 19 makes exactly
ONE test go red — the test written for it.** That second half is the part worth having. A test
proven red tells you it is wired to something; a test that is the *only* thing red on its own
mutant tells you the cell would be a survivor without it.

**And the same night, the remaining eleven checks were closed the same way.** The 16 `U2G`
survivors that had been named as out of perimeter before that run — `L2`, `L4`, `L10`, `L11`,
`S5`, `S6`, `S10`, `S11`, `S14`, `S15`, `S16` — took **16 more assertions**, measured the same
way: **16 mutants, 16 killed, each making exactly ONE test go red.** Three of the sixteen could
not be pinned on the verdict's summary at all: `S10`, `S11` and `S14` emit the *same sentence*
under three different ids, so what distinguishes them lives in the evidence line beneath. Written
first like the other thirteen, those three came back **red on the healthy tool** — the suite
caught the mistake, which is what a suite is for.

**So the operator that carries this tool's argument — answering *I do not know* rather than
*this is protected* — has no surviving mutant left anywhere in the corpus**: 0 of 63 sites, across
all 29 checks. It is the first mutation operator to reach zero on the whole tool.

**That run has now landed — 2026-09-04, all 292 sites, and it is what the rest of this section is
measured on.** The paragraph that stood here said the full matrix had *not* been re-run, that
`19/19` and `16/16` were per-site measurements rather than a figure for the whole tool, and that
the 59-survivor total "must fall by at least 35". Checked against the run rather than deleted:

- **`U2G` reaches 0 on the full matrix, not just per-site** — 0 of 63 across all 29 checks,
  measured in one pass instead of inferred from 35 separate ones. The claim above survives its
  own audit.
- **Survivors fell 59 → 12**, a fall of 47 against a predicted floor of 35. The prediction held
  and was beaten, by the twelve collateral cells described above.
- **Nothing regressed.** All 47 cells that moved, moved out of `SURVIVED`; not one cell moved
  into it. The 77-site perimeter of the nine worked checks came back **identical cell for cell**
  (64 named / 13 generic / 0 survivors, unchanged), which is the control this run existed to
  provide: 35 new fixtures did not disturb what was already measured.

On three of those nine (`L5`, `L6`, `L8`) the check has 12 mutation sites, which is the
`FINE_CAP=12` ceiling, so their ratios are over the sites *sampled* rather than over every
`UNKNOWN` branch in the code. The cap can only make this count too low, never too high.

So: the restraint this tool sells — answering *I do not know* rather than *this is protected* —
was **enforced on 9 of its 29 checks and unenforced on the other 20** when this was measured on
2026-08-31. Since the two 2026-09-03 passes it is enforced on **29 of 29**, on that property
alone — and that last clause was the whole caveat: the twenty checks worked that day had their
`UNKNOWN` branches pinned, not their whole mutant set.

**Two things this paragraph used to say are now false, and the 2026-09-04 run is what falsified
them.** It said the worked checks' other survivors — "`return` drops, inverted conditions" — were
*untouched*: `return` drops in fact went to **0 of 46**, by the `T152` side effect described
above. And it said the suite would not stop the tool from becoming wrong "on the eleven that are
left", a count left over from before those eleven checks were closed. What remains is **12
survivors on 6 checks** — `L5` (4), `L6` (2), `L12` (2), `S2` (2), `L8` (1), `S11` (1) — and they
are the operators nobody has attacked yet: relaxed comparisons (`3 / 5`), inverted `-n`
conditions (`4 / 43`), and the two verdict swaps that do not involve `UNKNOWN` (`3 / 18` and
`2 / 16`).

Two limits on that 12, stated because they cut the other way: **no survivor has been
hand-verified**, and the previous round showed a survivor can be an *equivalent* mutant (a check
falling back on a generic pattern and producing a byte-identical report). The number of real
holes is **at most** 12.

The denominator itself was checked exhaustively before these numbers were published, since a
generator that emits the same mutant twice inflates every ratio on this page: all **292 sites were
re-enumerated from the source and every mutant rebuilt** — **292 built, 0 differing from the
original by anything other than one replaced line, 0 byte-identical to each other, and 0
byte-identical to the original.** That last one is the one that would have mattered: such a mutant
survives by construction and would pad the survivor count. (`--self-test` guards this too, but its fine arm
samples two checks; this pass covered all 29.)

What these numbers do **not** cover, said plainly: no numeric-literal mutation, no widened character
class, no removed `elif`; one substitution per line; at most 12 sites per check, so `L3` is capped
at 12 of its 17 — which the run prints rather than hides.

The harness proves itself before it judges anything else. `--self-test` builds an **identity**
mutant — a comment inserted, behaviour unchanged — and requires it to *survive*. That is the guard
against the classic way a mutation harness lies: a mutant that does not even parse kills every
test, which reads on screen as magnificent coverage. Two static companions run before the matrix:
every check must be named by at least one test, and every assertion must carry, in its name, the
`ID` it asserts — the second one found four mislabelled tests the first time it ran.

That second control then had the exact defect it exists to catch, and it is worth stating because
it is the same defect this tool sells: its pattern only ever matched calls written on **one line**,
so every multi-line assertion was invisible to it while its heading still said *every test*. It
read 85 of 107 call sites and reported on all 107. It now joins continuation lines, understands all
three assertion helpers, and **prints its own denominator** — anything it cannot parse is named
rather than silently dropped. A control is allowed to be incomplete; it is not allowed to be quiet
about it.

Four read-only environment hooks (`ACD_LAUNCHCTL_LIST`, `ACD_PMSET_LOG`, `ACD_LAUNCHAGENTS_DIR`,
`ACD_SYSTEMD_UNIT_DIR`) let the suite replay a scheduler registry, a sleep history, an agents
directory or a set of systemd units that do not exist on the machine running the tests. Two of
them name a file whose contents are used instead of running a command (`ACD_LAUNCHCTL_LIST`,
`ACD_PMSET_LOG`); the other two name a **directory** to walk instead of `~/Library/LaunchAgents`
and instead of `systemctl --user`. They are documented in the source rather than hidden: a
diagnostic tool you cannot test is a diagnostic tool you should not trust. The systemd hook was
added the day the systemd branch was first measured, for the reason that branch had gone three
weeks unmeasured: a test suite that can only reach the scheduler its own host runs is a test
suite that certifies one platform and guesses at the other.

---

## Origin of this work

**This tool was written end-to-end by an autonomous AI agent (Claude Code), not by a human
author.** No part of it was ghostwritten by a person and attributed to the agent.

It is said here because you are about to run it against your own machine, and because the checks
come from somewhere concrete: they are the failure modes of the agent's *own* scheduled chain,
each one lived through or found in a cold audit of it, generalised into something that can be
pointed at yours. That is also the honest reason to distrust a clean report — see the limits
above.

Read the script before running it if that matters to you. It is one file, commented for a reader
rather than for a compiler, and its read-only claim is checkable in the same repository: cases
T35 to T39 fail if a write operator or a network binary ever appears in the source, and T39
compares the target tree before and after a run.

## Related

The author also publishes a paid set of governance templates for unattended agents. This tool
contains no part of it, works standalone, and is not held back to sell it.

## License

MIT — see [`LICENSE`](LICENSE). Authorship note in [`NOTICE`](NOTICE).
