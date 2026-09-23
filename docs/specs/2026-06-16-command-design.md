# Command — System Design

Date: 2026-06-16 · Status: implemented (later specs extend it; the code wins
where they differ)

> The original architecture + data-model spec. The agent-facing MCP contract is
> `docs/mcp/MCP-GUIDE.md`.

---

## 1. Purpose & shape

Command is a personal planning system. Capture is one tap on the phone; the
plan is assembled by an AI agent that can see everything through MCP.

- **iOS app** — calendar up top, a one-tap "write a note" bar at the bottom
  (typed or on-device voice), plus notes / people / tasks / account views.
- **Server** — one lean Python process serving a **REST API** (for the app) and
  an **MCP server** (for the operator's Claude Code) over a shared **SQLite**
  store. Self-hosted in Docker, typically behind a TLS reverse proxy or tunnel.
- **Workflow** — the agent reads captured **notes**, walks the operator through
  turning them into **goals** and **assignments**, and delegates each assignment
  to a **delegatee** (human or AI model) on the roster, **routine** or
  **sporadic**, with enough **lead time** that type-A delegatees will act on it.

### Non-goals (v1, explicit YAGNI)
- No in-app agent / auto-running of AI delegatees (the external Claude Code is
  the brain for now; in-app agentic execution comes "much later").
- No server-side audio storage (transcribe on device, store text only).
- No multi-tenant org features; accounts are peers on one personal server.
- No push notifications in v1 (calendar lead-time reminders are a fast-follow).

---

## 2. Architecture

```
┌──────────────────┐         REST/HTTPS          ┌───────────────────────────┐
│  iOS app (Swift) │ ──────────────────────────▶ │  Command server (Python)  │
│  capture+review  │ ◀────────────────────────── │  one process, one SQLite  │
└──────────────────┘    session cookie/bearer    │                           │
                                                 │   FastAPI router  ─┐       │
┌──────────────────┐    MCP / Streamable HTTP    │   MCP /mcp tools  ─┼─▶ core/│
│  Claude Code      │ ─────────  /mcp  ─────────▶ │                    │  └─SQLite
│  (operator's CLI) │ ◀──────  bearer token  ──── │   (shared core/ is the    │
└──────────────────┘   per-account access token   │    single source of truth)│
                                                 └─────────────┬─────────────┘
                                    loopback bind 127.0.0.1    │
                                ┌───────────────────────────────┘
                                ▼
                   reverse proxy / tunnel ────────▶ https://<command host>
```

**One process, two surfaces, one core.** REST routers and MCP tools both call
`core/` functions; a domain rule (e.g. "notes are never deleted") is enforced
once, in `core/`, so both surfaces inherit it (a curated endpoint/tool layer
over shared logic).

### Server module layout
```
server/
  pyproject.toml            # uv-managed; deps: mcp, fastapi, uvicorn, pydantic,
                            #   pydantic-settings, bcrypt, structlog, anyio
  command/
    __init__.py
    config.py               # pydantic-settings; env-driven
    app.py                  # builds the ASGI app: FastAPI + mounted MCP app
    db.py                   # sqlite connection, WAL, migrations runner
    migrations/             # 0001_init.sql, ... idempotent CREATE IF NOT EXISTS
    core/                   # THE source of truth — no HTTP/MCP imports here
      accounts.py           # register/login/sessions/access-tokens
      tokens.py             # memorable access-token generation + verification
      notes.py              # create/read/search/archive (NO destructive delete)
      delegatees.py         # upsert/list/search/remove
      goals.py              # crud + note linking
      assignments.py        # crud + scheduling + occurrence expansion
      settings.py           # server settings incl. MCP permission matrix
      audit.py              # write/delete audit trail
      errors.py             # typed domain errors (→ actionable HTTP/MCP errors)
    rest/                   # FastAPI routers (thin; call core/)
      auth.py notes.py delegatees.py goals.py assignments.py settings.py
    mcp/                    # MCP server (thin; call core/)
      server.py             # FastMCP instance, instructions, transport wiring
      auth.py               # per-account TokenVerifier
      policy.py             # read/write/destructive tags + confirm-tokens
      tools/                # one module per domain; register(mcp, ...)
  tests/                    # pytest: core unit + REST + an MCP end-to-end call
  docker/Dockerfile         # two-stage uv → python:3.12-slim
```

---

## 3. Data model (SQLite, WAL)

All timestamps are ISO-8601 UTC TEXT. All ids are INTEGER PK. Foreign keys ON.
Every user-owned row carries `account_id` and is filtered by it on every access
(per-account isolation is enforced in `core/`, not left to callers).

| Table | Key columns | Notes |
|---|---|---|
| `accounts` | `username` UNIQUE, `display_name`, `password_hash` (bcrypt) | the human login |
| `access_tokens` | `account_id`, `token` UNIQUE, `label`, `last_used_at`, `revoked_at` | memorable MCP bearer token; viewable+regenerable (see §5.2) |
| `sessions` | `token_hash` PK (sha256), `account_id`, `expires_at` | REST app login; raw token only on device |
| `notes` | `account_id`, `body`, `source`(typed\|voice), `engine`, `locale`, `processed_at`, `archived_at` | **never hard-deleted via MCP**; `archived_at` is app-only soft hide |
| `delegatees` | `account_id`, `slug` UNIQUE/acct, `name`, `kind`(human\|ai_model), `lead_time_minutes`, `metadata` JSON, `active` | people + models; `metadata` holds personality, contact, model_id, capabilities |
| `goals` | `account_id`, `title`, `description`, `status`(open\|in_progress\|done\|dropped), `target_date` | assembled from notes |
| `goal_notes` | `goal_id`,`note_id` PK | provenance: which notes a goal came from |
| `assignments` | `account_id`, `goal_id?`, `title`, `details`, `assignee_id?`, `schedule_kind`(routine\|sporadic), `rrule?`, `scheduled_start?`, `scheduled_end?`, `lead_time_minutes`, `status`, `priority` | the planner unit; shown on calendar |
| `occurrence_status` | `assignment_id`,`occurrence_date` PK, `status`, `note` | per-occurrence completion overrides for routine items |
| `settings` | `key` PK, `value` JSON | server settings incl. `mcp_permissions` matrix |
| `audit_log` | `account_id`, `actor`(mcp\|rest), `tool`, `action`, `entity`, `entity_id`, `summary` | traceability for writes/deletes |
| `confirm_tokens` | `token` PK, `account_id`, `tool`, `payload_hash`, `expires_at`, `used_at` | single-use confirmation for destructive MCP ops |

**Scheduling.** `schedule_kind = routine` uses an iCal **RRULE** string
(`rrule` column); the server expands it to occurrences for a requested calendar
window (`assignments_calendar` / REST calendar endpoint) and overlays
`occurrence_status`. `schedule_kind = sporadic` uses `scheduled_start` only.
`lead_time_minutes` defaults from the assignee's `lead_time_minutes` (the
lesson: type-A delegatees need advance notice; the system makes that a
first-class field and can warn when an assignment is scheduled inside an
assignee's lead-time window).

**`mcp_permissions` settings value** (the operator-controlled matrix that the
prompt requires — "all that should be controlled in server settings"):
```json
{
  "notes":       { "read": true,  "create": true,  "update": false, "delete": false },
  "delegatees":  { "read": true,  "create": true,  "update": true,  "delete": true  },
  "goals":       { "read": true,  "create": true,  "update": true,  "delete": true  },
  "assignments": { "read": true,  "create": true,  "update": true,  "delete": true  },
  "settings":    { "read": true,  "create": false, "update": false, "delete": false }
}
```
`notes.update`/`notes.delete` default **false** and are **hard-capped** false in
`core/` regardless of settings (Hard Rule 1 — a settings bug must never make
notes destructible via MCP). The other rows are honored from settings.

---

## 4. REST API (for the iOS app)

JSON over HTTPS. Auth = session cookie (httpOnly) or `Authorization: Bearer
<session-token>`. Errors are `{error:{code,message}}` with actionable messages.

```
POST   /api/auth/register            {username,password,display_name?}
POST   /api/auth/login               {username,password} → sets session
POST   /api/auth/logout
GET    /api/auth/me                  → account + capabilities

GET    /api/access-token             → current memorable token (viewable)
POST   /api/access-token/regenerate  → new token (invalidates old)

GET    /api/notes?query=&unprocessed=&from=&to=&cursor=
POST   /api/notes                    {body,source,engine?,locale?}
GET    /api/notes/{id}
PATCH  /api/notes/{id}               {body?}            # app-only edit
POST   /api/notes/{id}/archive       # soft hide; never hard delete

GET/POST          /api/delegatees       ; GET /api/delegatees/search?q=
GET/PATCH/DELETE   /api/delegatees/{id}

GET/POST          /api/goals ; GET/PATCH/DELETE /api/goals/{id}
POST              /api/goals/{id}/notes        {note_ids:[]}

GET/POST          /api/assignments ; GET/PATCH/DELETE /api/assignments/{id}
GET    /api/assignments/calendar?from=&to=      # expanded occurrences
POST   /api/assignments/{id}/occurrences/{date}/status  {status,note?}

GET/PUT           /api/settings
GET    /api/health
```

---

## 5. Auth & the memorable access token

### 5.1 Accounts & app sessions
- Passwords hashed with **bcrypt**. Login issues a session token; the server
  stores only `sha256(token)`; the raw token lives in the iOS Keychain and is
  sent as a cookie/bearer. Lazy expiry cleanup.

### 5.2 The MCP access token (the operator's ask)
"A short but secure access token that is easy to remember for humans and can be
regenerated at will, that each account uses to let a Claude Code instance access
their account via MCP."

- **Format:** `cmd_<word>-<word>-<word>-<NNNN>`, e.g. `cmd_otter-maple-harbor-7421`.
  Words drawn from a curated ~1500-word list (short, common, unambiguous, no
  homophones); 4-digit suffix. **Entropy ≈ 45 bits** (`1500³ × 10⁴`). The
  `cmd_` prefix makes it identifiable (GitHub-style) and greppable in logs as a
  secret to redact.
- **Viewable + regenerable.** Because the operator must paste it into Claude
  Code's MCP config on each machine, the token is **stored retrievably** and
  shown in the app and via `GET /api/access-token`. Regeneration replaces it
  (old token immediately invalid). This is a deliberate single-owner
  self-hosted trade-off (the DB file is the same trust boundary as the token);
  Verification is a
  constant-time compare on an indexed lookup.
- **Brute-force defense (required to make 45 bits safe over a network):**
  per-token + per-IP auth rate limiting with backoff on the MCP endpoint;
  `Origin` validation (MCP spec) — harmless and satisfied behind the tunnel;
  optional Cloudflare Access in front for defense-in-depth (operator choice).
- **Scoping:** a token resolves to exactly one account; the MCP session only
  ever sees that account's rows.

---

## 6. MCP server (for Claude Code)

Transport **Streamable HTTP** (spec `2025-11-25`) at `/mcp`, plus **stdio** for
local use. Per-account opaque-bearer auth via a custom `TokenVerifier`
(token → account). Full agent-facing contract: `docs/mcp/MCP-GUIDE.md`.

### Tool surface (namespaced, per-account, search-over-list, check-before-create)

| Tool | Tags | Purpose |
|---|---|---|
| `command_whoami` | read | account + capabilities + current MCP permission matrix; orients the agent |
| `notes_search` | read | search/filter notes (query, `unprocessed`, date range, source); cursor-paginated |
| `notes_get` | read | one note by id |
| `notes_create` | write·additive | agent jots a note (e.g. capturing a decision). **No delete/destructive-edit tool exists.** |
| `notes_mark_processed` | write·additive | flag notes as turned-into-goals (non-destructive; reversible) |
| `delegatees_search` / `delegatees_list` | read | find people/models |
| `delegatees_get` | read | one delegatee |
| `delegatees_upsert` | write | create-or-update by `slug`; **checks existence internally** (check-before-create) |
| `delegatees_remove` | destructive | settings-gated; **requires confirm-token** |
| `goals_search` / `goals_get` | read | |
| `goals_create` / `goals_update` / `goals_link_notes` | write | assemble goals from notes |
| `goals_delete` | destructive | settings-gated; confirm-token |
| `assignments_search` / `assignments_get` / `assignments_calendar` | read | `assignments_calendar` expands routine RRULEs over a window |
| `assignments_create` / `assignments_update` / `assignments_assign` / `assignments_set_status` | write | `assignments_assign` warns if scheduled inside the assignee's lead-time window |
| `assignments_delete` | destructive | settings-gated; confirm-token |
| `settings_get` | read | |
| `settings_update` | write | controls the MCP permission matrix etc.; itself permission-gated |

**Conventions (all tools):** honest annotations
(`readOnlyHint`/`destructiveHint`/`idempotentHint`/`openWorldHint=false` — closed
domain); front-loaded descriptions written for agent decision-making; **semantic
slugs**, not raw UUIDs, in I/O; `isError` results with a fix (not tracebacks);
opaque-cursor pagination; destructive tools return a **confirm-token** that must
be passed back to execute (single-use, payload-bound, SQLite-backed so it
survives across HTTP requests). Server enforces read/write/delete **server-side**
from the settings matrix — annotations are untrusted hints, never the gate.

### Server instructions string (given to the agent on connect)
Explains: the capture→goals→assignments→delegatee workflow; **notes are sacred
(read/create only)**; the lead-time concept and how to respect each delegatee's
`lead_time_minutes`; the confirm-token flow for destructive ops; per-account
scoping; and to prefer `*_search` + `command_whoami` before mutating.

---

## 7. iOS app

SwiftUI · Swift 6 · XcodeGen (`ios/project.yml`; generated `.xcodeproj`
git-ignored) · MVVM with `@Observable` + `@MainActor` · **min iOS 17.0** ·
bundle `com.legitimateapps.command`. Thin client over the
REST API (`APIClient` actor); server is source of truth; local store is cache.

### Screens
1. **Calendar** (root) — month/week with assignments plotted; routine items
   expanded from RRULE; a persistent bottom **"write a note"** bar (text field +
   mic). One tap saves a typed note; mic records → transcribe → fill → save.
2. **Notes** — list + search of captured notes.
3. **People** — delegatees list; add/edit with metadata (kind, personality,
   contact, lead-time, model id); inline-add while typing an assignee name
   (autocomplete against `delegatees_search`, create-on-the-fly).
4. **Tasks** — assignments list/detail (complementary to the calendar).
5. **Account** — login/register; server URL; **view/copy/regenerate** the MCP
   access token; transcription settings (engine, model download/manage).

### Transcription (tiered, language-aware — see §1 research)
- **Tier 1 — Parakeet v3** via **FluidAudio v0.15.3** (SPM): premium, 25 EU
  languages, on-device ANE, **file-based** transcription of the recorded note;
  ~600 MB model **downloaded on first use** (from a self-hosted mirror — see
  open questions — with progress UI; never bundled). `AsrManager` kept warm.
- **Tier 2 — iOS 26 `SpeechTranscriber`**: gated on `isAvailable` (A16+); covers
  CJK/Arabic/Thai/Vietnamese that Parakeet lacks; OS-managed model assets.
- **Tier 3 — `SFSpeechRecognizer`**: universal fallback; on-device forced where
  `supportsOnDeviceRecognition`; chunk < 60 s otherwise.
- A **language-aware router** picks the best available tier for the detected/
  selected locale (not a strict quality ladder). Output normalized
  (punctuation/casing) so notes look consistent across engines.
- Recording flow: `AVAudioRecorder` → `.m4a` file → chosen engine → text → note.
  Audio stays on device (server stores text only).

---

## 8. Deployment

- **Where:** any Docker host, via `deploy/docker-compose.yml`; the container
  binds to `127.0.0.1:<port>` behind a TLS reverse proxy or tunnel.
- **Image:** two-stage `uv` → `python:3.12-slim`, non-root, single uvicorn
  worker. SQLite on a mounted volume outside the image.
- **TLS:** terminate HTTPS in front of the container (e.g. Cloudflare Tunnel,
  Caddy, or a platform like Railway).
- **Leanness gate:** measure idle RSS (`docker stats`) and confirm < 100 MB,
  single worker, no idle CPU, before calling it done (Hard Rule 3).

---

## 9. Error handling

- `core/` raises typed domain errors (`NotFound`, `PermissionDenied`,
  `Conflict`, `ValidationError`, `ConfirmRequired`, `RateLimited`).
- REST maps them to HTTP status + `{error:{code,message}}`.
- MCP maps them to `isError: true` results with an actionable message (the model
  self-corrects), reserving JSON-RPC protocol errors for malformed/unknown-tool.
- Destructive MCP ops raise `ConfirmRequired` carrying a confirm-token on first
  call; the agent re-calls with the token to execute.

---

## 10. Testing & verification

- **core/** — pytest unit tests per module (accounts, tokens incl. entropy +
  constant-time verify, notes "no-delete" invariant, delegatee upsert idempotency,
  rrule expansion, settings/permission gating, confirm-token single-use).
- **REST** — httpx against the app (auth round-trip, per-account isolation,
  calendar expansion).
- **MCP** — a real end-to-end Streamable-HTTP call: connect with bearer, list
  tools, exercise a read + a write + a destructive(confirm) flow, assert
  per-account scoping and the notes-no-delete enforcement. (Verify on the wire,
  not by inspection — Hard Rule 5.)
- **iOS** — ViewModel logic tests with an injected transport; visual
  verification of each screen state via the simulator before merge.
- **Leanness** — idle RSS measured with `docker stats` on the deploy host.

---

## 11. Build phases

0. Research + this design (done at commit of this doc).
1. Server foundation — schema, db, core/accounts+tokens, REST auth.
2. REST API — notes, delegatees, goals, assignments, settings, calendar.
3. MCP server — tools, per-account auth, policy/confirm-tokens, instructions,
   end-to-end test. Finalize `docs/mcp/MCP-GUIDE.md`.
4. Deploy — Docker, compose, tunnel route; verify on the wire;
   measure RSS.
5. iOS app — scaffold, APIClient, auth, calendar + quick-note, notes, people,
   tasks, account.
6. Transcription — FluidAudio/Parakeet tier + Apple tiers + router + model mgmt.
7. TestFlight — CI on self-hosted runner, archive, upload, submit.
8. Polish + docs finalization.

Each phase ends with pasted verification evidence before the next begins.
