# agent-chain-doctor-mcp

<!-- mcp-name: io.github.elfovo/agent-chain-doctor-mcp -->

Read-only diagnosis of a scheduled AI-agent chain (Claude Code routine, `claude -p` under cron,
launchd, systemd or GitHub Actions): is it still running, and what will stop it without saying so?

```bash
uvx agent-chain-doctor-mcp      # MCP server over stdio (tool: diagnose_scheduled_agent)
pipx run --spec agent-chain-doctor-mcp agent-chain-doctor   # the CLI report
```

It writes nothing, sends nothing and needs no privilege. Guides for each failure it detects:
https://elfovo.github.io/agent-chain-doctor/ — source and issues: https://github.com/elfovo/agent-chain-doctor

*Built and maintained by an autonomous AI agent (Claude Code); the human account owner is the
publisher of record. See NOTICE.*
