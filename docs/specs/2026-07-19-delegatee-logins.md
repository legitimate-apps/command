# Delegatee logins — design (2026-07-19)

**Goal:** "Delegatee logins — give a delegatee their own account/app view of just what's
assigned to them." The mission is advance-notice delegation; this closes the loop so the humans you
delegate to can see and act on their work — without seeing anything else of yours.

## Decision: invite-token sessions, not full accounts

A delegatee is a roster row owned by an operator account (`delegatees` table), not a person with
their own data. Full self-registered accounts would drag in password reset, App-Review
account-deletion, and cross-account linking UI — heavy, and wrong-shaped (the delegatee owns
nothing). Instead, the house token pattern (access tokens / calendar HMAC tokens):

- The operator generates an **invite token** for a human delegatee from the People screen.
- The delegatee installs Command, taps **"I have an invite"** on the auth screen, pastes the token
  (or opens an invite link), and gets a **delegatee session** — the standard `sessions` mechanics,
  scoped to `(account_id, delegatee_id)`.
- They land in a dedicated, minimal **My Work** shell: only assignments assigned to them.

Revocation = deleting the invite/its sessions from the People screen. Deactivating or deleting the
roster row revokes automatically (CASCADE / active check).

## Server

### Data (migration 0015)
```sql
CREATE TABLE delegatee_invites (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id    INTEGER NOT NULL REFERENCES accounts(id)   ON DELETE CASCADE,
    delegatee_id  INTEGER NOT NULL REFERENCES delegatees(id) ON DELETE CASCADE,
    token_hash    TEXT NOT NULL UNIQUE,          -- sha256(raw); raw shown once, word-style token
    created_at    TEXT NOT NULL,
    revoked_at    TEXT,
    UNIQUE(delegatee_id)                          -- one live invite per delegatee (regenerate replaces)
);
ALTER TABLE sessions ADD COLUMN delegatee_id INTEGER REFERENCES delegatees(id) ON DELETE CASCADE;
ALTER TABLE device_tokens ADD COLUMN delegatee_id INTEGER REFERENCES delegatees(id) ON DELETE CASCADE;
```
`sessions.delegatee_id IS NULL` ⇒ a normal operator session (existing behavior untouched).

### Core (`core/delegatee_access.py`, single source of truth)
- `create_invite(conn, account_id, delegatee_id) -> raw_token` — human kind only, active only;
  regenerating revokes the old token and its sessions. Token = 4 words from `_wordlist` (same
  entropy stance as MCP access tokens) prefixed `inv-` so surfaces can recognize it.
- `redeem_invite(conn, raw_token) -> session` — creates a session row with `delegatee_id` set.
  Invite stays live (multi-device sign-in) until revoked/regenerated.
- `delegatee_for_session(...)` — resolves (Account, Delegatee) for scoped requests; rejects if the
  roster row is inactive or deleted.
- **Scope enforcement lives here**: every read/write helper takes `delegatee_id` and filters
  `assignee_id = delegatee_id` in SQL — not in the routers.

### REST (`rest/my.py`, all under `/api/my/…`, delegatee-session-authed)
- `GET  /api/my/profile` → delegatee name, operator display name (what to show in the shell).
- `GET  /api/my/assignments` → open assignments where `assignee_id = me`, **hidden excluded**
  (an operator who veiled an item chose privacy; it never renders on someone else's phone).
- `GET  /api/my/calendar?start&end` → occurrence expansion (reuses `assignments.calendar()`
  filtered to me, hidden excluded).
- `POST /api/my/assignments/{id}/status` and `/occurrences/{date}/status` → done / in_progress /
  blocked / skipped only (no delete, no edit, no reassign). Status changes append to the operator's
  activity log with the delegatee as actor, so the operator sees who did what.
- `POST /api/auth/invite` (unauthed) → redeem token, set session cookie. Login rate-limited like
  password login.
- Existing operator surface additions: `POST /api/delegatees/{id}/invite` (create/regenerate,
  returns raw token once), `DELETE …/invite` (revoke). People screen consumes these.

Delegatee sessions get **404-shaped rejection** on every other endpoint (notes, goals, people,
agent, MCP, peers): `get_current_account` gains a variant that refuses delegatee-scoped sessions,
so the entire existing surface is closed by default — least privilege by construction, matching
Hard Rule 2's spirit.

### Reminders
`device_tokens.delegatee_id` lets a delegatee device register for push. The reminder job already
walks account tokens; it gains a filter: a token with `delegatee_id` set only receives reminders
whose `assignee_id` matches. The operator's own devices stop receiving reminders for occurrences
assigned to a delegatee **only** if that delegatee has ≥1 registered device (otherwise the operator
remains the safety net). This is the feature's point: the lead-time nudge lands on the doer's phone.

## iOS

- **AuthView**: an "I have an invite" affordance → token field → `redeem`. Session storage identical
  to today (cookie).
- **Delegatee shell** (`Features/MyWork/`): a single-tab shell replacing the 5-tab operator shell
  whenever the session is delegatee-scoped (server tells us via `/api/my/profile` at bootstrap).
  Screens: **My Work** list (today / upcoming / done, grouped), a day agenda strip, and an
  assignment detail sheet (title, details, schedule summary, status buttons + per-occurrence
  actions for routines). Uses the same Palette/Typeface design system; reuses PlannerFormat.
- **Push**: PushService registers the token as usual; server scoping does the rest.
- Sign out = normal logout. No account settings, no timezone (times render in the delegatee
  device's zone), no billing (the operator's subscription covers the roster).

## Phasing
1. **P1 (this build):** migration, core, `/api/my/*`, invite mgmt REST, People-screen invite UI,
   AuthView redeem path, My Work shell (list + status actions), tests for every scope rule.
2. **P2 (follow-up):** delegatee push registration + reminder routing filter, occurrence parity
   polish, invite deep link (`command://invite/<token>`).

## Explicitly out
- Delegatee-originated content (notes/comments) beyond status+activity rows.
- AI-model delegatees (kind `ai_model`) — invites are human-only; agentic auto-run remains
  deferred (see `docs/decisions/`).
- Web surface.

## Security review checklist (tests must cover)
- A delegatee session cannot read/write ANY non-`/api/my` endpoint (parametrized sweep).
- `/api/my/*` never returns another delegatee's or unassigned work; hidden never leaks.
- Redeeming a revoked/regenerated token fails; sessions die on revoke/deactivate/delete.
- Invite creation is operator-session-only, human-kind-only.
- Rate limits on redeem mirror login.
