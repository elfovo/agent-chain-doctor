# MCP server for agent-chain-doctor (stdio). Inside a container it can only diagnose the
# container itself; to diagnose your real chain, run `python3 mcp/server.py` on the host.
FROM python:3.12-alpine
RUN apk add --no-cache bash
WORKDIR /app
COPY agent-chain-doctor ./agent-chain-doctor
COPY mcp/server.py ./mcp/server.py
LABEL io.modelcontextprotocol.server.name="io.github.elfovo/agent-chain-doctor-mcp"
ENTRYPOINT ["python3", "/app/mcp/server.py"]
