# AI assistant expansion — design

Date: 2026-08-02. Status: implemented.

---

## The problem

The in-app assistant has **18 tools**. The MCP surface (external Claude Code) has **31**. The app
itself does considerably more than either. The assistant is the product's headline feature and it
is the least capable way to use the product.

Concretely, the assistant today **cannot see the calendar**, cannot mark a note processed (the
one workflow the mission statement is built around), cannot log an activity, cannot read an
attachment, cannot reschedule an occurrence, and cannot touch checklists.

## What this delivers

Four tracks. Tracks 1–2 ship server-side with no app build; tracks 3–4 need a release.

---

## Track 1 — Tool parity + expansion (server)

Grouped by priority. Every tool goes in `core/agent/tools.py`, reuses the
existing `core/` functions (no new domain logic), and inherits the `_guard` error contract.

### Calendar & scheduling (priority)
| Tool | Why |
|---|---|
| `get_calendar(start, end)` | The assistant is blind to the calendar today. Highest-value single addition. |
| `find_free_time(duration_minutes, window, workday_only)` | New capability. Makes "when can I fit this?" answerable. |
| `reschedule_occurrence(assignment_id, date_key, start, end)` | Wraps migration 0018 `occurrence_overrides`. |
| `reset_occurrence(assignment_id, date_key)` | Undo for the above. |
| `find_conflicts(window)` | Overlap detection across occurrences. |

### Notes → goals loop (the mission workflow)
`get_note`, `mark_note_processed`, `link_notes_to_goal`, `update_goal`,
`triage_unprocessed_notes(limit)` — the last is a consolidated read that returns unprocessed
notes plus existing goals, so the agent can propose the mapping in one turn instead of N.

### Delegation & follow-through (priority)
`get_assignment`, `assign_assignment`, `log_activity`, `activity_summary(window)`,
`find_stale_assignments(threshold_days)` (overdue / untouched / blocked, grouped by delegatee),
`search_people`, `get_person`, plus checklists: `list_task_items`, `add_task_item`,
`set_task_item_done`.

### Attachments & rich input (priority)
`list_attachments(entity_kind, entity_id)`, `read_attachment(attachment_id)` — text extracted
inline; images returned as image parts so the existing vision path handles them.

### State
`archive_assignment`, `unarchive_assignment`, `set_assignment_reminder`, `list_reminders`.

### Invariants (non-negotiable)
- **Notes stay non-deletable** (Hard Rule 1). No delete-note tool, ever, on any surface.
- Destructive tools keep the existing `_confirm_gate` confirm-token pattern.
- Hidden/invisible-ink captures stay excluded unless explicitly requested, matching MCP's
  `include_hidden=false` default.
- Tool descriptions written for agent decision-making per the MCP design principles already in
  `CLAUDE.md`; units/formats/defaults go in per-parameter schema descriptions.

**Cache note:** tools are the Anthropic prompt-cache breakpoint (`stamp_cache_breakpoint`, commit
550f6d8). Roughly doubling the tool count grows the cached prefix — which *increases* the value of
the existing cache, but the block must stay byte-stable. Tool order must therefore be
deterministic, and no timestamps or per-run values may appear in any tool schema.

---

## Track 2 — Proactive briefings (server)

A digest the user actually wants: what's due, what's overdue, who's blocked, which notes are
still unprocessed. Rides the existing `reminder_job.run_loop` sweep — no new daemon, honouring
the no-recurring-jobs rule.

### Per-user settings (`settings` table, key `agent_briefings`)
```json
{ "enabled": false, "cadence": "daily", "hour_local": 8,
  "kinds": { "due_today": true, "overdue": true, "blocked": true, "unprocessed_notes": true } }
```
Default **off**. Surfaced as toggles on the iOS settings screen, written through a new
`PUT /api/settings/briefings`.

### Notification budget — the cost guard
New migration `0019_notification_budget.sql`:
```sql
CREATE TABLE notification_budget (
  account_id      INTEGER PRIMARY KEY,
  sends_since_open INTEGER NOT NULL DEFAULT 0,
  last_send_at    TEXT,
  last_open_at    TEXT
);
```
- `COMMAND_MAX_SENDS_BEFORE_OPEN: int = 30` in `config.py` — env-tunable, **no code change to
  retune**, by requirement.
- Checked **before generating**, not before sending: the LLM call is the real cost, so a
  budget-exhausted account never reaches the model.
- **Open detection resets the counter to 0.** An open is: `POST /api/app/opened` (called on
  foreground), the `/api/auth/me` bootstrap, or tapping a push (which routes through both).
- **Scope: anything that spends LLM tokens** (decided 2026-08-02). The cost being
  guarded is model spend, not APNs delivery. So:
  - **Briefings are counted and capped** — every one is a model call.
  - **Plain reminders are neither counted nor capped** — `send_account_reminders` pushes a
    template (`title="Reminder"`, `body=r.title`) and never touches a model, so a dormant account
    with a recurring assignment costs nothing worth guarding.
  - Any future proactive LLM-backed notification inherits the cap automatically by going through
    the same guard.
- The column is therefore named `llm_sends_since_open`, not `sends_since_open` — the name should
  say what it actually counts, so the next person doesn't wire a template push into it.

### Entitlement gate — must mirror the chat gate, not invent a stricter one
The chat endpoint gates on `settings.agent_require_subscription and not is_active(...)`, and
**`agent_require_subscription` defaults to false**. Gating briefings on `is_active()` alone would
mean every **self-hosted** instance — where nobody is "subscribed" — silently never receives a
briefing. So both surfaces get one shared seam:

```python
# core/entitlements.py
def can_use_agent(conn, account_id, *, require_subscription: bool) -> bool:
    if not has_consent(conn, account_id):
        return False
    if require_subscription and not is_active(conn, account_id):
        return False
    return True          # ← BYO-key becomes ONE added clause here, later
```

`rest/agent.py` and the briefing job both call it. This is the seam that keeps the future
open.

### Designed-for, not built: BYO key + self-hosting
BYO-key is **out of scope now** (decided 2026-08-02) and is expected to arrive
alongside open-source self-hosting. Two things are therefore built so that later slice is
additive rather than a refactor:
1. **Key/model resolution goes through one function**, not scattered `settings.ai_api_key` reads,
   so a per-account key can later resolve ahead of the server-global one.
2. **Metering asks "who pays"** rather than debiting unconditionally — when the key is the user's,
   nothing should touch our budget. `debit_budget` stays behind that seam.

No BYO-key code, storage, or UI ships in this work.

---

## Track 3 — Reaching the assistant by voice and glance (iOS)

### Availability strategy — the key decision
**The deployment target stays low (iOS 17.0) so the app keeps selling to iOS 17/18 users.** Every
new capability is gated with `@available(iOS 26, *)` / `if #available`. The widget-and-control
extension declares its own higher minimum; it simply does not install on older systems. No
pre-iOS-26 fallbacks are written (decided).

### The iOS 27 finding — this changes the headline answer
On **shipping iOS 26**, an app-name-free "remind me to feed
the cats" cannot reach a third-party app. But
**iOS 27 changes exactly this**:

- The new Siri routes no-app-name requests to **schema-adopting** third-party apps via App Intents
  plus **interaction donations** — donate schema-conforming intents when the user acts in the UI,
  and Siri learns to infer the right app.
  [DOC] <https://developer.apple.com/videos/play/wwdc2026/343/>
- `.reminders.createReminder` and the calendar integration guide carry an **"iOS 27.0 Beta"**
  badge — primary availability evidence, not forum hearsay.
  [DOC] <https://developer.apple.com/documentation/appintents/appschema/remindersintent/createreminder>
- **SiriKit was deprecated at WWDC26**; iOS 27 Siri routes exclusively through App Intents.
- Routing is **learned and probabilistic**, not a default-app picker — there is no disambiguation
  UI and no guarantee.
- **Not in the EU at launch** (DMA dispute); EU devices keep legacy Siri and legacy routing.

**Design consequence.** Adopt the assistant schemas behind `@available(iOS 27, *)` and start
donating interactions now, so the app is already a routing candidate the day iOS 27 ships
(~Sept 2026). Do **not** market app-name-free phrasing until it is observed working on a real
device — the routing is probabilistic and EU-excluded.

### What the research settles (shipping iOS 26)
- Saying **"…in Command"** works today. **"remind me to pet my cats"** with no app name cannot be
  claimed automatically — but a **user-created Shortcut can be named anything**, and Apple
  documents that such a shortcut *overrides* the standard Siri command. That is the supported
  route to app-name-free phrasing, plus **Vocal Shortcuts** (iOS 18+).
- **Title + time in one utterance is not reliable** — a phrase interpolates at most one
  parameter. Ship it as a two-turn flow; do not promise one.
- **Max 10 App Shortcuts per app.** Eight exist. Only two slots remain — spend them deliberately.
- The literal "hold the side button → our assistant" API exists (`.assistant.activate` +
  `com.apple.developer.side-button-access.allow`) and is **Japan-only**, verified verbatim
  against Apple's documentation JSON. Not viable here; worth a region adapter only if Japan ships.

### The build
One `StartVoiceConversationIntent` routing to a single voice-capture coordinator, exposed through
every entry point Apple does allow:
1. **Action Button** (iPhone 15 Pro+) — the closest thing to one-gesture voice. Foreground
   listening scene using the existing on-device transcription tiers, streaming to the SSE agent.
2. **Control Center + Lock Screen control** (`ControlWidgetButton` + `OpenIntent`).
3. **Back Tap** — works via the same shortcut, no extra code.
4. `AskCommandIntent` with a required `String` — Siri prompts "What would you like to ask?", the
   dictated prose is forwarded to the agent. Two turns, zero setup.

**Deliberately not built now:** `AudioRecordingIntent` + Live Activity (locked/background
capture). It is the sanctioned rail but mandates a Live Activity for the entire recording and
enlarges the App Review surface (guideline 2.5.14). Revisit once the foreground path is proven.

### Widgets — none exist today
New widget extension: **Home Screen** (small/medium/large — today's agenda, next up, counts),
**Lock Screen** (`accessoryRectangular` / `accessoryCircular` — next item, overdue count),
**StandBy**, and interactive `AppIntent`-backed buttons (capture, mark done) which have been
available since iOS 17.

---

## Track 4 — Assistant everywhere in the app

Contextual entry points so the assistant is not marooned in one tab: "Ask about this" on note,
assignment, goal and person detail, seeding the thread with that entity; and an assistant action
on the capture bar.

---

## Testing

- Server: pytest per tool group, driven through the real `COMMAND_FAKE_NOW_FILE` scenario clock
  for anything time-dependent (as the sliding-session suite does). Budget-guard tests must cover
  the boundary at exactly 30 and the reset-on-open path.
- iOS: unit tests for the gate/coordinator logic; simulator screenshots for the voice scene and
  widgets.
- Verify on the wire before the screen (Hard Rule 5).

## Sequencing

1. Track 1 (tools) — largest capability gain, ships without a build.
2. Track 2 (briefings + budget guard) — ships with it.
3. Track 3 (voice + widgets) — needs the release.
4. Track 4 (in-app entry points) — rides the same release.
