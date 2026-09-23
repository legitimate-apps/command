# Start here

**Command** is a calendar-and-notes app for iPhone, iPad and Mac, plus a small
server you host yourself. The server keeps your data in one SQLite file and
lets an AI agent (over MCP) turn your notes into goals and delegated tasks.

## Using it
- [`../README.md`](../README.md) — what it is and how to run a server.
- [`mcp/MCP-GUIDE.md`](mcp/MCP-GUIDE.md) — connecting an agent such as Claude Code.

## Changing it
1. [`../CLAUDE.md`](../CLAUDE.md) — stack, architecture and the hard rules.
2. [`specs/2026-06-16-command-design.md`](specs/2026-06-16-command-design.md) —
   the original design: data model, REST and MCP surfaces.
3. The other files in [`specs/`](specs/) and [`decisions/`](decisions/) cover
   later features (activity log, hidden items, assistant, peer agents, billing).

## Layout
- `server/` — Python server (REST + MCP + shared `core/` + SQLite).
- `ios/` — SwiftUI app, widgets and App Intents (XcodeGen).
- `deploy/` — Docker Compose template for self-hosting.
- `docs/` — this.
