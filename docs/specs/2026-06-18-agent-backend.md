# Spec — Agent backend (Phase B)

**Date:** 2026-06-18 · **Status:** building slice 1 (agent core + meter).
**Decision record:** `docs/decisions/2026-06-18-ai-backend.md` (why pydantic-ai, not the Code SDKs).

A metered, multi-tenant AI agent the operator's users reach from the app, sold as a
**$19.99/mo** plan and hard-capped at **~$10 of API spend/user/month**. Claude and
Qwen run interchangeably behind one tool layer + one meter. The agent runs
server-side; the app stays CRUD + a chat/status view.

## Why pydantic-ai (not the Claude/Qwen "Code SDKs")

The Claude Agent SDK spawns a Node CLI subprocess per session (~20–30s cold start,
RAM per session) — wrong for a lean (<100 MB idle) multi-tenant server, and its
tool-sandboxing is fragile (issue #361). No embeddable Qwen Code SDK exists.
**pydantic-ai** is in-process, drives **Anthropic-native + any OpenAI-compatible**
model (DashScope/OpenRouter) through one `Agent`, attaches our tools/MCP once, and
exposes per-run token usage for billing. One framework, both agents, one meter.

## Architecture

```
iOS chat (CRUD + SSE status)  ──REST──▶  POST /api/agent/chat (SSE)
                                            │  entitlement + $10 cap gate (pre)
                                            ▼
                                  core/agent/runner  ── router ─▶ Claude | Qwen
                                            │            (weighted-random / by task)
                                  one toolset (core/agent/tools) over core/ domain
                                            │  per-account RunContext deps
                                  usage meter (post): tokens×rates → month-to-date USD
```

- **Models:** default **`claude-sonnet-4-6`** (escalate `claude-opus-4-8` for hard
  tasks; `claude-haiku-4-5` for trivial sub-calls). Qwen via DashScope
  OpenAI-compatible (`qwen-plus` / `qwen3-coder-plus`), 3–10× cheaper.
- **Router:** nondeterministic — weighted-random pick per run (configurable split),
  later refine by task type. Both agents share the toolset, system prompt, and meter.
- **Tools (one layer, `core/agent/tools.py`):** read + safe-write over the planning
  DB — search/create notes, list/create/assign/(re)schedule assignments, list/upsert
  delegatees, goals, activities — each scoped to the caller's account via
  `RunContext` deps. Honors the hard rules: **notes never deletable**, least
  privilege, destructive ops gated. Plus a **`web_search`** tool.
- **Status streaming:** `agent.iter()` → relay `PartDelta` (text/thinking),
  `FunctionToolCallEvent`/`Result` as SSE events; persist the final turn.

## Cost + metering

- Per run, sum `RequestUsage` (input/output/cache tokens) × the model's USD rates →
  run cost. Accumulate **`agent_usage.month_to_date_usd`** per account per period.
- **Pre-run gate:** refuse when MTD ≥ cap (`COMMAND_AGENT_MONTHLY_CAP_USD`, default
  `10`) with a friendly "resets <date>". **Post-run:** record cost.
- pydantic-ai usage is authoritative token counts; price table in `core/agent/pricing`.
  Reconcile against provider console out of band; the cap is a soft cutoff.
- Period = calendar month for now; later driven by the subscription renewal date.

## Data model (migration 0004)

```sql
agent_usage(account_id, period TEXT, cost_usd REAL, input_tokens, output_tokens,
            runs INT, updated_at)               -- one row per account+period
agent_threads(id, account_id, title, created_at, updated_at)
agent_messages(id, thread_id, account_id, role, content, model, cost_usd, created_at)
```

## API (slice 1)

- `POST /api/agent/chat` — body `{thread_id?, message}`; **SSE** stream of
  `{type: status|tool|text|done|error, ...}`; creates a thread if none; records the
  message pair + usage; returns final + remaining budget in the `done` event.
- `GET /api/agent/threads`, `GET /api/agent/threads/{id}` — history. Each message in
  `messages[]` carries its `id` (plus `thread_id`, `role`, `content`, `model`,
  `cost_usd`, `created_at`); threads carry `origin` (`app` | `a2a`).
- *(2026-09-22)* `POST /api/agent/threads/{id}/truncate` — body
  `{"after_message_id": <int>}` (deletes every later message in that thread) or
  `{"from_message_id": <int>}` (deletes that message too — what the app uses, since it
  always knows the id of the user message it is replacing); exactly one. Returns `{"ok": true, "remaining": <count>}`. 404 = not this account's thread,
  422 = the message isn't in that thread, 409 = a reply is still streaming. Used for
  "Edit & resend" / "Regenerate": truncate back to the message before the one being
  edited (or to the user message being regenerated), then `POST /api/agent/chat` again.
- *(2026-09-22)* The chat SSE stream emits a comment line `: ping` roughly every 15 s
  while a run is quiet (SSE parsers ignore it; it keeps client idle timers alive), and
  the first `thread` event carries `user_message_id` (the persisted id of the message
  just sent).
- *(2026-09-22)* Destructive tools in chat/A2A: the confirm token a delete returns is only
  accepted in the user's NEXT message of the same thread (never the turn that issued it);
  that turn's run context lists the pending plan and its token.
- `GET /api/agent/usage` — MTD spend + remaining + reset date.

## Slices

1. **Agent core + meter (this slice):** tools, dual-model router, web search, cap,
   streaming endpoint, threads — verified on the wire, deployed. **Entitlement gate
   is a stub** (any authed account, still capped) until slice 3.
2. Usage polish: per-task model escalation, prompt-cache the system prompt + schemas.
3. **$19.99 IAP** (RevenueCat, Small Business 15%) + server entitlement (App Store
   Server Notifications v2) + ToS passthrough of Anthropic Usage Policy + AI
   disclosure/consent. Cap period → renewal date.
4. **iOS:** chat UI + SSE status, paywall, consent gate.

## Compliance (slice 3, designed now)

Reselling our **pay-per-token** Anthropic API is permitted (the subscription path is
not). Must: pass Anthropic Usage Policy through to users (ToS) + basic moderation;
disclose AI + get consent before sending user data to a third-party model (Apple,
late-2025); optional "powered by Claude". Verify DashScope commercial terms before
shipping the Qwen path.

## Open questions

1. **web_search provider** — Anthropic's built-in web tool vs an external search API
   (Tavily/Brave) as a neutral tool both models share. (Lean toward a neutral tool.)
2. Exact Qwen model + DashScope region/key (or route Qwen via OpenRouter to share one
   key/meter).
3. Router split (start 80% Claude / 20% Qwen?) + when to escalate to Opus.
