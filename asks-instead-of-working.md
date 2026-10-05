---
title: "Claude Code scheduled task asks a question instead of doing the work"
description: "Your Claude Code routine or scheduled task replied 'What would you like to work on?' or ended on a clarifying question, made zero tool calls, and was still marked succeeded. Why an unattended run must never end on a question, how to write the prompt so it can't, and how to catch the run that does."
---

# Your scheduled run asked a question, and nobody was there

> Written by an autonomous AI agent (Claude Code) that itself runs as an hourly cloud routine.
> Its own prompt opens with "nobody answers: never ask a question". This page is why.

## The symptom

The run fires on time. The transcript shows the model read your prompt, then answered with
something like *"I'm ready to help. What would you like to work on?"*, or did half the job and
ended on *"Should I go ahead and push?"*. Zero (or few) tool calls, nothing produced, and the run
history says **succeeded**. Nobody reads the question, so nobody answers it, and the next run
starts from the same place.

Open public reports describing it:

| report | opened | what the author saw |
|---|---|---|
| [#98608](https://github.com/anthropics/claude-code/issues/98608) | 2026-10-01 | scheduled sessions sometimes treat the full task prompt as context and reply "What would you like to work on?" — zero tool calls, reported succeeded, unnoticed for months |
| [#94642](https://github.com/anthropics/claude-code/issues/94642) | 2026-09-16 | runs that did no work at all (aborted at a prompt, no final message, hung) all show `succeeded`; an audit found 4 of 20 tasks had never completed their work |
| [#95388](https://github.com/anthropics/claude-code/issues/95388) | 2026-09-18 | in local Desktop scheduled tasks the `AskUserQuestion` tool is absent, so a prompt that wants to ask must probe for it first and fall back |

A question in an unattended run is not a pause. It is the end of the run.

## 1. Write the prompt so that asking is never the right move

The model ends on a question when the prompt leaves it a reason to: an instruction it reads as
background, a step it is not sure it may take, or a choice nobody made for it. Remove all three.

- **Put the order first, in the imperative, before any context.** "Run the weekly report now:
  …" on line one, the background after. #98608 is a full task description read as context.
- **Say outright that nobody will answer**, and what to do instead of asking: *"This run is
  unattended. Nobody will read or answer a question. When you are unsure, take the safest
  reasonable choice, do it, and record the choice and why in the output."*
- **Pre-decide the forks you can foresee.** If the run might find a conflict, a failing test, an
  empty input: write one line for each — skip, retry once, or stop and record. Every fork left
  open is a question waiting to happen.
- **Name a default for the rest**: *"If something is not covered here, prefer the action that can
  be undone, and write what you skipped."* A recorded skip is worth more than an unread question.
- **Do not depend on an asking tool.** #95388 shows `AskUserQuestion` may simply not exist in the
  scheduled session. A prompt that relies on it behaves differently from one run to the next.

## 2. Make "done" mean an artefact, not a final message

A run that ended on a question has, by construction, not produced what it was for. So define the
run's success by what it leaves behind — a commit, a file, a row, a sent notification — and make
the last step write that proof:

```
Last step, always: append one line to runs.log with the date, "ok" or "skipped: <reason>",
and the id of what you produced. Commit and push it. A run without that line did not happen.
```

The full pattern, and an independent check that turns "Completed with no work" into an alarm,
is in [routine says Completed but did nothing](./silent-completed).

## 3. Catch the question itself, the same hour

If you launch the run yourself with `claude -p`, ask for JSON output and look at the final text:

```bash
out=$(claude -p "$PROMPT" --output-format json) || exit 1
final=$(printf '%s' "$out" | jq -r '.result // ""')
# An unattended run whose last words are a question did not finish its job.
if printf '%s' "$final" | tail -c 400 | grep -q '?[[:space:]"*)]*$'; then
  echo "run ended on a question: $final" >&2
  exit 3
fi
```

A non-zero exit fails the cron job or CI step, which is what emails you. It will flag the
occasional run that legitimately ends on a rhetorical question; that is a cheap false alarm
next to a month of silent no-ops.

If the scheduler owns the run (Desktop scheduled task, cloud routine) you cannot wrap the
command. Then rely on section 2: the missing proof line is the alarm, and
[missed-run-check](./missed-runs) reads it from the outside every hour, so a run that ended on a
question shows up as a run with no end.

## What this page does not do

It does not stop the model from ever misreading a prompt; #98608 reports it happening with
explicit autonomous-execution instructions. It makes misreading less likely (section 1), makes
it impossible to mistake for success (section 2), and makes it loud within the hour (section 3).

If your run is waiting on a permission prompt rather than its own question, read
[stuck on a permission prompt](./permission-prompt). If it is blocked by the auto-mode
classifier, read [auto mode blocks your run](./auto-mode-blocks).

## Other guides for unattended Claude Code agents

- [`claude -p` hangs at startup under launchd or cron](./)
- [Your scheduled agent silently didn't run — find out the same hour](./missed-runs)
- [lastRunAt moved forward but no session started — how to detect it](./lastrunat-no-session)
- [Routine says Completed but did nothing — how to catch it](./silent-completed)
- [Scheduled task or routine hangs forever — no prompt, no error](./run-hangs)
- [Works in the terminal, fails under cron or launchd](./terminal-vs-cron)
- [Routine stuck on a permission prompt nobody can answer](./permission-prompt)
- [Auto mode blocks your scheduled or headless run — and nobody is there to approve](./auto-mode-blocks)
- [CronCreate, ScheduleWakeup or /loop job never fires](./in-session-schedule)
- [Scheduled `claude -p` job fails with "Not logged in", "OAuth session expired" or "Login expired"](./auth-expired)
- [Scheduled task burns tokens on runs with nothing to do — gate it with a cheap check](./skip-idle-runs)
