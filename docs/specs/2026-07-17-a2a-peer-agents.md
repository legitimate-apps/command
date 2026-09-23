# A2A peer agents — Command ↔ external app agents (design)

Date: 2026-07-17. Status: implemented (approach A of three; an MCP ask-tool and
a bespoke REST API were rejected).

## Goal

Command's in-app AI and the AI of a user's other webapps can converse
agent-to-agent, both directions, in natural language — no fixed tool vocabulary
between apps, so each side's development never breaks the interface. Example
peer used throughout: a small pantry-tracking webapp (Python + SQLite).

The channel is the **Agent2Agent protocol (A2A) v1.0** (Linux Foundation,
stable April 2026): Agent Card discovery + JSON-RPC-over-HTTP task exchange.
"Add an agent by URL" is A2A's native discovery flow.

## Non-goals

- No Pantry UI inside Command; the only integration surface is agent↔agent.
- No fine-grained cross-app tool schemas (that's what we're avoiding).
- No A2A push notifications or signed-card issuance in v1 (verify-only if
  cheap; revisit later).
- No third-party peer marketplace/directory; users paste URLs they trust.

## Architecture

```
Command agent ──ask_peer tool──▶ HTTPS ──▶ Peer /a2a ──▶ peer's agent loop
Command /a2a ◀── HTTPS ◀──ask_peer tool── Peer agent
```

- Each app serves an **Agent Card** at `/.well-known/agent-card.json`
  (name, description, skills summary, endpoint URL, auth scheme) and an
  **A2A endpoint** at `/a2a` (JSON-RPC 2.0 over HTTP; message/send at
  minimum; streaming optional in v1 — final method list per the K3 research
  report, `docs/decisions/` addendum after it lands).
- Incoming tasks are natural-language messages fed into the app's existing
  agent runner (Command: `core/agent/runner.py`; Pantry: `app/ai.py`), reply
  returned as the task result. Multi-turn continues via A2A `contextId`
  mapped to the app's native thread/session.
- **Shared adapter**: one dependency-free Python file (~200–400 lines,
  target stdlib + the app's existing web layer only) implementing card
  serving, JSON-RPC parsing/validation, auth hook, task lifecycle, and two
  integration points an app must provide: `get_card()` and
  `run_agent_turn(message, context_id, account)`. Command mounts it in
  FastAPI; Pantry wires it into its stdlib server. Any future webapp copies
  the file and implements the two functions.
  - Decision pending K3 dep-tree evidence: default is hand-roll (Command's
    <100 MB RSS hard rule; official `a2a-sdk` suspected heavy). If K3 shows
    a slim, mountable, light-footprint SDK path, prefer it and record the
    reversal in `docs/decisions/`.

## Command server

**Peers registry** — new `core/peers/` + migration:

```
peers(id, account_id, name UNIQUE per account, url, card_json, card_fetched_at,
      token_ciphertext, enabled, created_at, updated_at)
peer_exchanges(id, account_id, peer_id NULL for inbound, direction in|out,
               context_id, request_text, response_text, status, tokens/cost
               fields, created_at)   -- full audit log, both directions
```

- Add-peer flow: client submits URL (+ optional token) → server SSRF-guarded
  fetch of the card → returns card summary for confirmation → row created.
  Refresh-card endpoint. Semantic identifiers (peer name) everywhere.
- REST: `GET/POST /peers`, `PATCH/DELETE /peers/{name}`,
  `POST /peers/{name}/refresh`. Token accepted on create/update, never
  returned in any response.

**Agent tool** — `ask_peer(peer, message, context?)` in `core/agent/tools.py`:
sends message/send to the peer, returns the peer agent's reply. Tool
description enumerates the account's enabled peers with their card
descriptions so the agent knows who can answer what. Follow-ups pass the
returned context id. Timeouts + size caps; errors are actionable
(`isError` semantics, e.g. "peer unreachable — ask the user to check the URL").

**Inbound surface** — card + `/a2a` mounted in the same ASGI app (like `/mcp`):
- Auth: existing per-account human-memorable access token as bearer;
  resolves to exactly one account; declared in the card's security scheme.
- Each inbound task runs one agent turn via the same runner with the same
  budget/credits debiting, model resolution, and `core/`-enforced hard rules
  (notes never deletable, MCP/agent permission settings) as in-app turns.
- Per-token rate limit; per-turn output cap; every exchange logged to
  `peer_exchanges`.

**iOS** — "Connected Agents" settings screen: list (name, description,
enabled, last-verified), add-by-URL flow with card-preview confirm step,
edit token, enable/disable, delete, plus a row showing *this account's*
inbound address (Command's A2A URL + access-token pointer) for pasting into
other apps. Thin client over the REST endpoints.

## Example peer (pantry app)

- Drop in the shared adapter: card (name "Pantry", description of what its
  agent can do) + `/a2a` over `ai.py`'s agent loop; single static bearer
  token (single-user app) checked by the adapter's auth hook.
- Peer registry: minimal — settings rows for Command's URL + account access
  token; `ask_peer` tool added to Pantry's agent tool set.
- Behind Cloudflare, Browser Integrity Check can reject server-to-server
  requests with non-browser user agents; check the hop in both directions.

## Security

1. **SSRF guard** (Command, production, multi-tenant): HTTPS-only peer URLs;
   resolve DNS and reject private/loopback/link-local/multicast ranges
   (IPv4+IPv6) at fetch time; re-validate on every redirect hop; response
   size cap (card ≤ 64 KB, task reply ≤ 256 KB) and connect/read timeouts;
   card refetch only server-initiated.
2. **Token handling**: peer tokens encrypted at rest (app-level key from
   env), never in logs, never returned to clients.
3. **Prompt-injection containment**: peer replies are injected into the
   agent context as clearly-delimited untrusted data ("Peer X replied: …"),
   never as system/tool authority; Command's confirm-gated destructive
   actions remain confirm-gated regardless of what a peer says; peer output
   never executes tools directly.
4. **Inbound abuse limits**: bearer rate limit (per token per hour),
   concurrent-task cap of 1 per account, budget debiting identical to
   in-app turns so a peer cannot spend beyond the account's credits.
5. **Anonymity**: cards contain app identity only (Command / Legitimate
   LLC), no personal data.

## Error handling

- Outbound: distinguish unreachable / auth-rejected / protocol-error /
  peer-agent-error; each maps to an actionable message the agent can relay.
- Inbound: JSON-RPC error objects per spec; malformed requests never 500;
  auth failures 401 with no account-existence leak.
- Card drift: if a peer's card fails to refresh, keep serving the cached
  card with a staleness note in the tool description.

## Verification (wire before screen)

1. Unit/regression: adapter protocol tests (card, message/send, auth,
   malformed input) in Command's pytest and the peer's own tests.
2. Live loopback: `curl` both cards; a task in each direction with real
   replies; `peer_exchanges` and credits-debit rows as evidence.
3. RSS measured on the deploy host before/after (hard rule 3).
4. iOS add-peer flow driven on simulator last (visual claim only).

## Rollout

Phase 1: shared adapter + Command outbound (peers registry, ask_peer, REST)
+ Command inbound surface. Phase 2: the example peer's adapter + ask_peer.
Phase 3: iOS Connected Agents screen + TestFlight. Each phase lands with its
verification evidence before the next starts.


## Update 2026-09-22 — inbound trust hardening

- **Permission matrix applies to peers.** An inbound turn runs the PEER toolset: every tool
  first checks the account's agent permission matrix (the same one MCP uses, via
  `core/settings.require_agent_permission`), and `fetch_url` / `ask_peer` are not offered.
- **Same entitlement gate as chat:** consent, then `entitlements.can_use_agent` (subscription
  when `COMMAND_AGENT_REQUIRE_SUBSCRIPTION` is on).
- **Threads record `origin`** (`app` | `a2a`, migration `0023`). A `contextId` may only name a
  thread A2A started; an app thread reads as "Unknown context".
- **Destructive confirms** issued in a peer conversation are consumable only by the peer's
  next message in that thread (migration `0022`), never in the turn that issued them.
- `/a2a` authenticates before reading the body and caps it at 256 KB (413 beyond).
