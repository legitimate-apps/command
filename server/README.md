# Command server

Lean Python backend for Command. One process serves:

- a **REST API** (`/api/*`) for the iOS app, and
- an **MCP server** (`/mcp`, Streamable HTTP) for an external agent,

over a single **SQLite** store, through a shared `core/` module that is the only
place domain rules live.

## Run (dev)

```bash
uv sync
uv run command-server            # serves on 127.0.0.1:8000 by default
curl localhost:8000/api/health
```

Config is env-driven (prefix `COMMAND_`); see `.env.example`. Tests: `uv run pytest`.

Architecture and data model: `../docs/specs/2026-06-16-command-design.md`.
Agent-facing MCP contract: `../docs/mcp/MCP-GUIDE.md`.
