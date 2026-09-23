# Command Cloud + guided onboarding (design)

Date: 2026-09-23. Status: approved, implementing.

## Goal

Anyone can use Command without running anything: **Command Cloud** is a persistent,
multi-tenant server operated by Legitimate LLC. Self-hosting stays a first-class choice.
Onboarding becomes guided end to end, with a one-tap way to hand the whole setup to an AI agent.

## Decisions

- Cloud runs the **same published image** on Railway (Legitimate LLC workspace), separate from
  any personal server. Hostname: `https://cloud.legitimateapps.com` (fallback: the Railway domain).
- Cloud is **free** for notes, calendar, tasks, people, goals and MCP. **Command Pro** (the
  existing subscription) unlocks the in-app assistant on Cloud, paid from Legitimate LLC's model
  key under the existing per-account USD budget. Self-hosted servers stay ungated and use the
  owner's own key.
- Identity separation: every account sees only its own data on every surface (REST, MCP, A2A,
  attachments, calendar export). No cross-account admin UI; operator access is limited to
  backups and aggregate health.

## Server contract

Cloud is configured by env only; nothing Cloud-specific is compiled in.

`COMMAND_SERVER_KIND=cloud|self` (default `self`), `COMMAND_ALLOW_REGISTRATION=true`,
`COMMAND_AGENT_REQUIRE_SUBSCRIPTION=true`, `COMMAND_BACKUP_TOKEN=<secret>`.

### `GET /api/server/info` (public, no auth)

```json
{
  "service": "command",
  "version": "1.1.0",
  "kind": "cloud",                 // "cloud" | "self"
  "registration_open": true,       // false once a self-hosted server has its owner
  "ai": {
    "configured": true,            // a model key is available to the assistant
    "requires_subscription": true, // Command Pro gates the assistant here
    "key_settable": false          // true ⇒ the owner may set a key from the app
  }
}
```

The app uses this to label the server, decide whether "Create account" is offered, and whether
to show the "Add your AI key" step.

### `PUT /api/server/ai-key` (owner only)

Body `{"api_key": "sk-or-..."}`; `DELETE` clears it. Only on `kind=self`, only for the owner
(the server's first account), and only when no key is supplied by env (`key_settable`).
The key is validated against the provider (a models call) before it is stored, stored
encrypted at rest beside the instance secrets, never returned by any endpoint, and applied
without a restart. Errors are actionable (`invalid_key`, `not_owner`, `managed_by_env`).

### `GET /api/admin/backup` (backup token)

`Authorization: Bearer <COMMAND_BACKUP_TOKEN>`; 404 when no token is configured. Streams a
consistent snapshot: a `tar.gz` holding an online SQLite backup plus the attachments directory.
Constant-time token compare; rate limited.

### Multi-tenant hardening (applies to every server; matters most on Cloud)

- Per-client-IP rate limit on registration and login (honoring `X-Forwarded-For` only from a
  configured trusted proxy count), in addition to the per-username limiter.
- Per-account quotas: attachment bytes and counts, note/assignment volume ceilings that no real
  planner reaches but that stop abuse; clear errors when hit.
- An isolation test suite that creates two accounts and proves account B can neither read nor
  change A's data through each REST router, each MCP tool, attachments, peers and the calendar
  feed.
- Entitlement: in addition to the RevenueCat webhook, the server can confirm a subscriber via the
  RevenueCat REST API (`COMMAND_REVENUECAT_API_KEY`) when the app refreshes, so any number of
  servers work with one RevenueCat project.

## App

1. **Welcome** → two choices: **Command Cloud** (recommended, free) or **My own server**
   (Railway, own computer, existing address — the current guide).
2. **Account**: sign up or sign in against the chosen server (`/api/server/info` decides
   whether sign-up is offered).
3. **AI key** (self-hosted owner, `key_settable` and not configured): paste an OpenRouter key,
   or skip. Explains what it costs and that it stays on their server.
4. **Ready**: a short tutorial — capture a note (typed or voice), ask the assistant, connect
   Claude Code over MCP — each with one action button.
5. **Hand to your AI agent**: a button in the top bar of every onboarding/setup screen and in
   Account → Server. It opens a sheet that explains what it does and has one CTA: copy complete
   setup instructions (share sheet too). The text is tailored to the chosen path and links the
   web version.
6. Account → Server shows Cloud vs self-hosted and lets the user switch.

## Web

`legitimateapps.com/command/setup` becomes a small guide: Cloud, Railway, Docker, the assistant
key, and Claude Code (MCP). Every page's top bar carries the same "Hand to your AI agent" modal.
Each step has real screenshots or short captioned videos of the actual screens.
`/command/setup/agent.txt` is the plain-text agent brief.
