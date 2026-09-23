# CLAUDE.md — Command

Guide for anyone (human or agent) changing this repo. Durable rules only; start
with [`docs/START-HERE.md`](docs/START-HERE.md).

## What Command is

1. A **SwiftUI iOS app** (iPhone, iPad, Mac Catalyst) for fast capture — calendar
   plus one-tap notes, typed or on-device voice — and review of notes, people,
   goals and assignments.
2. A **lean self-hosted server**: a REST API for the app and an **MCP server**
   for an external agent, over one SQLite store.
3. The **MCP workflow**: an agent reads notes, helps turn them into goals and
   assignments, and delegates each to someone on the roster (a person or an AI
   model), routine or one-off, with realistic lead time.

## Stack

**Server** — Python 3.12, one process, one uvicorn worker. FastAPI for REST;
MCP via the official `mcp` SDK's bundled `FastMCP` (not the standalone `fastmcp`
package), Streamable HTTP at `/mcp`, stdio for local use. SQLite in WAL mode
behind a shared `core/` package. `uv` for deps; two-stage Docker image on
`python:3.12-slim`. Auth: bcrypt passwords, sessions stored as `sha256(token)`,
a per-account memorable access token for MCP bearer auth.

**iOS** — SwiftUI, Swift 6, XcodeGen (`ios/project.yml`; the `.xcodeproj` is
generated and ignored), `@Observable` + `@MainActor`. Thin client: the server is
the source of truth. On-device transcription is tiered: Parakeet v3 (downloaded
on demand) → `SpeechTranscriber` (iOS 26) → `SFSpeechRecognizer`.

## Architecture

```
iOS app ──REST──▶ ┌──────────────── Command server ───────────────┐
                  │  rest/  ─┐                                     │
agent ───MCP────▶ │  mcp/   ─┴─▶ core/ (all domain rules) ─▶ SQLite │
                  └────────────────────────────────────────────────┘
```

REST routers and MCP tools call the **same** `core/` functions. Change a domain
rule once, in `core/`, and both surfaces inherit it.

## Hard rules

1. **Notes are never deletable via MCP.** MCP may read and create notes, never
   delete or destructively edit them. Enforced in `core/`, not by annotations.
2. **MCP permissions are server-controlled** by a settings table, least
   privilege by default; destructive operations require a confirm token.
3. **Lean.** Target < 100 MB idle RSS on a small host; measure with
   `docker stats` before claiming it. No idle busy-loops.
4. **No stubs.** Nothing that pretends to work; no `TODO: fix later` in shipped
   paths. Understand a change with evidence before making it.
5. **Verify on the wire first.** Tests, HTTP responses, logs and DB rows before
   screenshots. Say which links in a claim you observed and which you assumed.
6. **No personal data in the repo.** No real names, home addresses, private
   hostnames or IPs, machine usernames, or secrets in code, docs, fixtures or
   commit messages. Use `example.com`, `10.0.0.x`, `192.168.1.x`. CI enforces
   part of this (`.github/workflows/pii-guard.yml`).

## MCP design

- Descriptions are written for an agent's decisions: what the tool does, when
  to use it and when not; units, formats and defaults go in parameter schemas.
- Semantic identifiers (names, slugs) over raw IDs in tool I/O.
- Honest annotations (`readOnlyHint`, `destructiveHint`, …), treated as hints;
  real safety lives in `core/`.
- Targeted/search tools over list-all; creation checks for duplicates.
- Actionable errors (`isError` plus a fix), never tracebacks.
- An access token resolves to exactly one account; an agent sees only its data.

Full contract: [`docs/mcp/MCP-GUIDE.md`](docs/mcp/MCP-GUIDE.md).

## Working on it

```sh
# server
cd server && uv sync && uv run pytest && uv run ruff check . && uv run mypy src
uv run command-server                 # http://127.0.0.1:8000

# iOS
cd ios && xcodegen generate && open Command.xcodeproj
```

CI runs only on GitHub-hosted Linux runners. Never attach a self-hosted runner
to this public repository. Secrets go in `server/.env` or `deploy/.env` (both
ignored); commit only the `.env.example` files.

## Docs

- `docs/START-HERE.md` — orientation.
- `docs/specs/` — design documents (dated; the code wins where they differ).
- `docs/decisions/` — recorded decisions.
- `docs/mcp/MCP-GUIDE.md` — the agent-facing MCP contract.
