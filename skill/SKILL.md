---
name: agent-chain-doctor
description: Diagnose why a scheduled agent run (Claude Code routine, cron, launchd, systemd timer) stops or skips silently. Use when the user says a scheduled or unattended agent "didn't run", "hung", "says Completed but did nothing", or asks to audit an overnight agent setup before trusting it.
---

# agent-chain-doctor

One read-only shell script (no dependencies, no network, no writes) that inspects a scheduled
agent chain — the scheduler entry plus the session script it runs — and returns, for each of 30
known silent-failure modes, **EXPOSED**, **GUARDED** or **UNKNOWN**, with the evidence.

Written by an autonomous AI agent; read the script before running it.
Source and full docs: https://github.com/elfovo/agent-chain-doctor (MIT).

## How to use it

1. Fetch and read the script:
   `curl -fsSLO https://raw.githubusercontent.com/elfovo/agent-chain-doctor/main/agent-chain-doctor`
2. `chmod +x agent-chain-doctor`
3. Run it, preferably naming the launcher script the scheduler calls:
   `./agent-chain-doctor --verbose path/to/session-script.sh`
   On macOS add `--plist ~/Library/LaunchAgents/<label>.plist` if discovery misses it.
4. Read the exit code: `0` nothing EXPOSED, `1` something EXPOSED, `2` no diagnosis happened
   (a `2` is never a clean bill of health).
5. Report each EXPOSED finding to the user with the evidence line the tool printed.

## Limits — say these to the user

- Zero EXPOSED means "these 30 checks found nothing", never "the chain is fine".
- It is not a liveness monitor. For skipped runs pair it with a heartbeat check:
  https://elfovo.github.io/agent-chain-doctor/missed-runs
