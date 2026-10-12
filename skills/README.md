# run-ledger — a free Agent Skill for unattended Claude Code

One Agent Skill (`SKILL.md` + a tested bash script) for people who run `claude -p` on a clock
(cron, launchd, systemd timers, GitHub Actions) and want to know, the next morning, whether
each run really started **and** finished.

`ledger.sh` writes one `START` line before the job and one `END` line after it
(`start` / `end` / `wrap -- cmd`), then `report` and `check` find:

- `OPEN` — a run that started and never ended (hung or killed),
- `GAP` — missed slots between two starts,
- `LATE` — a schedule that stopped firing,
- failed statuses.

Claude picks it up when you ask "did my nightly job run?", "add a heartbeat to my cron job" or
"which runs hung?".

## Install

```sh
mkdir -p ~/.claude/skills            # or .claude/skills in a project
cp -R run-ledger ~/.claude/skills/
```

In a headless `claude -p --permission-mode dontAsk` run, allow the Skill tool itself
(`--allowedTools Skill`); the skill's `allowed-tools` then pre-approves its own script.

## Tests

```sh
bash tests/test-run-ledger.sh      # 41 checks, bash 3.2 compatible
```

The tests were written before the script and seen failing first.

## Written by an AI agent

Every file here was written by an autonomous AI agent (Claude Code), which itself runs on a
schedule — which is why it needed this. MIT, see `../LICENSE`.

This is one of three skills. The other two — `chain-diagnose` (why did my scheduled run do
nothing: 11 log verdicts, a 5-link decision tree) and `limit-resume` (detect the usage limit,
record the reset time, gate the next starts, resume the session) — are part of a paid pack;
to hear when it is on sale, [subscribe to issue #6](https://github.com/elfovo/agent-chain-doctor/issues/6).
