# Command MCP — Guide for the Invoking Agent

This is the contract for an AI agent (e.g. Claude Code) driving the Command
server over MCP. It is written **for the agent**: read it before you act.

> Status: **verified end-to-end** (2026-06-16) against a real Streamable-HTTP MCP
> client — per-account auth, the 31-tool surface, settings gating, and the
> confirm-token flow all behave as described. A full **planning-workflow dry-run**
> (notes → search → upsert delegatees → goal → link notes → routine+sporadic
> assignments → assign with lead-time warning → calendar expansion → mark
> processed → two-step delete) was driven over the wire; it confirmed the flow and
> hardened two rough edges (idempotent `delegatees_upsert`; all search tools take
> `query`). The **activity-log surface** (`activities_log` / `search` / `summary`,
> auto-log-on-`done` with dedup, and the confirm-token delete) was added and
> **wire-verified the same way** on 2026-06-16. The §9 gotchas reflect
> empirically-confirmed behavior. (`[confirmed]` = grounded in the MCP `2025-11-25`
> spec / SDK; `[verified]` = exercised in test.)

---

## 1. What this server is

Command is one person's planner. Through MCP you can read what they've captured
(**notes**), help them shape it into **goals** and **assignments**, and delegate
each assignment to a **delegatee** (a human or an AI model) on their roster —
**routine** (recurring) or **sporadic** (one-off). Your job is usually:

> Read the unprocessed notes → talk it through with the operator → create goals
> and assignments → assign each to the right delegatee with enough **lead time**
> → mark the notes processed.

You are an assistant to that conversation, not an autonomous actor. Prefer
proposing and confirming over silently mutating.

## 2. Connecting

Add the server to your MCP client config. Transport is **Streamable HTTP**;
auth is a **bearer access token** that the operator copies from the Command app
(Account → Access Token). Example (Claude Code `.mcp.json`):

```json
{
  "mcpServers": {
    "command": {
      "type": "http",
      "url": "https://<command-host>/mcp",
      "headers": { "Authorization": "Bearer cmd_otter-maple-harbor-7421" }
    }
  }
}
```

- The token (`cmd_…`) **scopes you to exactly one account.** Every tool only
  ever sees and touches that account's data. You cannot reach another account.
- If the operator regenerates their token, the old one stops working
  immediately — update the header.
- Auth is rate-limited; don't retry a rejected token in a loop.

## 3. First moves

1. Call **`command_whoami`** first. It returns the account, your capabilities,
   and the **MCP permission matrix** (what you're allowed to read/write/delete
   right now — the operator controls this in server settings). Respect it; if a
   write tool is disabled, don't promise the operator you'll do it. It also
   returns **`self_delegatee`** — the slug for **"Me"** (the operator as an
   actor) — which you use when logging the operator's own activity.
2. Use **`notes_search`** with `unprocessed: true` to see what's waiting to be
   planned. Notes are cursor-paginated — page with `nextCursor`, don't assume a
   page size **[confirmed]**.

## 4. The cardinal rule: notes are sacred

- You may **read** notes (`notes_search`, `notes_get`) and **create** notes
  (`notes_create`) and **mark them processed** (`notes_mark_processed`,
  reversible).
- There is **no tool to delete or destructively edit a note**, by design. The
  server enforces this in its core even if a settings flag says otherwise. Do
  not tell the operator you can delete a note — you can't. If they want a note
  gone, that's an app-side archive they do themselves.

## 4.5 The invisible-ink veil (`hidden`)

Notes, assignments and activities can each be marked **hidden** — the operator's
invisible-ink veil, set in the app. **Hidden items are excluded from everything you
see by default**, and that is deliberate: they are the things the operator chose not
to share with an assistant.

- Ten tools take `include_hidden` (default `false`): `notes_search`, `notes_get`,
  `assignments_search` / `_get` / `_calendar` / `_delete`, `activities_search` /
  `_get` / `_summary` / `_delete`. The two deletes are on the list because their
  confirm summary quotes the target's title back at you. `goals_delete` and
  `delegatees_remove` are not — goals and delegatees carry no veil.
- **Detail inherits its parent's veil.** Attachments and checklist items have no
  `hidden` of their own, so `attachments_list`, `attachments_read` and
  `checklist_list` resolve the parent first and report the same "no such thing" when
  it is veiled. A hidden assignment's filenames and checklist steps are as revealing
  as its title.
- **Writes by id are veiled too.** `notes_mark_processed`, `assignments_update` /
  `_assign` / `_set_status`, `activities_update`, `activities_log` (its
  `assignment_id`), `checklist_add` / `checklist_set_done` and `goals_link_notes`
  treat a hidden target as not found unless you pass `include_hidden: true` — each
  would otherwise echo the hidden row back. `goals_get` leaves hidden notes out of
  `note_ids`, and `schedule_find_conflicts` / `schedule_find_stale` leave hidden
  assignments (and their titles) out, under the same flag.
- A veiled item is **indistinguishable from one that does not exist** — you get the
  same "no such note/assignment/activity" you would for a bad id. This is on
  purpose: "it exists but you may not see it" would leak the thing the veil hides.
- **So do not conclude an id is invalid.** If the operator insists something is
  there and you cannot find it, say it may be hidden and ask whether to include
  hidden items — don't tell them it doesn't exist.
- Pass `include_hidden: true` **only when the operator has asked for it in this
  conversation.** Never set it to widen a search speculatively, and never repeat a
  hidden item's contents into a summary, title or note that isn't itself hidden.
- **Never send hidden content to a connected agent.** Once the operator has opted
  in, nothing mechanically stops you relaying what you read into `peers_ask` — but
  that pushes it outside their account entirely, to a system they did not veil it
  from. If a peer needs to know about a hidden item, ask the operator first.

## 5. Tool groups

- **`command_whoami`** *(read)* — orient. Capabilities + permission matrix.
- **Notes** — `notes_search` *(read)*, `notes_get` *(read)*, `notes_create`
  *(write, additive)*, `notes_mark_processed` *(write, additive)*.
- **Delegatees** — `delegatees_search` / `delegatees_list` / `delegatees_get`
  *(read)*, `delegatees_upsert` *(write — idempotent create-or-update, keyed by an
  explicit `slug` or one derived from `name`; re-upserting the same name updates
  that delegatee instead of creating a duplicate, so no separate check-before-create
  is needed)*, `delegatees_remove` *(destructive — confirm-token)*.
- **Goals** — `goals_search` / `goals_get` *(read)*, `goals_create` /
  `goals_update` / `goals_link_notes` *(write)*, `goals_delete` *(destructive)*.
- **Assignments** — `assignments_search` / `assignments_get` /
  `assignments_calendar` *(read)*, `assignments_create` / `assignments_update` /
  `assignments_assign` / `assignments_set_status` *(write)*, `assignments_delete`
  *(destructive)*. `assignments_calendar` expands routine RRULEs over a date
  window (at most 400 days; earliest occurrences first, capped at 1000 —
  `truncated: true` means read on from the last `occurs_at`). Recurrences finer
  than hourly (`FREQ=SECONDLY`/`MINUTELY`) are rejected, and a one-off may span at
  most 366 days. `assignments_assign` will **warn** (not block) if you schedule inside
  the assignee's lead-time window. `assignments_set_status` to `done` **auto-logs
  a completion activity** (see Activities); `skipped` records "didn't do it".
- **Activities** — `activities_search` / `activities_get` *(read)*,
  `activities_log` / `activities_update` *(write)*, `activities_delete`
  *(destructive)*, `activities_summary` *(read — the audit rollup)*. The fact log
  (see §6.5). Actor is a delegatee slug (`me` = the operator).
- **Scheduling** *(all read-only)* — `schedule_find_free_time`,
  `schedule_find_conflicts`, `schedule_find_stale`. These answer the questions you
  would otherwise reconstruct by pulling `assignments_calendar` and reasoning over
  it, and they get right two things that are easy to get wrong by hand:
  - a one-off (`sporadic`) assignment with a `scheduled_end` is an **interval** and
    occupies time; one with only a `scheduled_start` is a **point in time** (a
    reminder) and occupies none — so a reminder never eats into free time but *can*
    still collide. A **routine's** `scheduled_end` is the date the *recurrence stops*,
    not each occurrence's length, so routine occurrences are points too;
  - **back-to-back is not a conflict** (one ends exactly as the next begins), but
    two reminders at the *same instant* are.

  Use `schedule_find_free_time` to pick a slot **before** `assignments_create`,
  and `schedule_find_conflicts` afterwards to confirm you didn't double-book.
  `schedule_find_stale` is the follow-through tool — "what needs chasing?", "who
  owes me what?" — and returns `total` alongside the first `limit` findings, so
  quote the total rather than listing everything. A recurring assignment whose
  past occurrences are all done or skipped is **up to date, not overdue**.
- **Attachments** — `attachments_list` / `attachments_read` *(read)*. Check these
  when the operator refers to "the document" or "what I attached"; the detail is
  often in the file rather than the record. **Binary is not decoded** — PDFs and
  images report their type instead of returning bytes, so describe what the file
  is rather than guessing at its contents. Read-only by default: uploading and
  deleting are disabled in the permission matrix (deleting also removes bytes from
  disk, which no confirm-token can undo).
- **Checklists** — `checklist_list` *(read)*, `checklist_add` /
  `checklist_set_done` *(write, additive)*. Steps belonging to one note or
  assignment. Prefer adding checklist items over inventing several assignments
  when a single job has parts — and note that an assignment which looks like one
  job may have outstanding pieces here.
- **Settings** — `settings_get` *(read)*. The permission matrix is **read-only
  over MCP**; the operator changes it in the app (there is no `settings_update` tool).

Identifiers in tool I/O are **mixed**: **delegatees** use a semantic **slug**
(e.g. `roommate-jordan`) you can reason about; **notes, goals, assignments, and
activities** use the **integer `id`** returned by their `*_search` / `*_get`
tools (e.g. `assignment_id`, `goal_id`). Look an id up via search before you use
it — don't fabricate one.

## 6. Lead time (why this app exists)

Each delegatee has a `lead_time_minutes` — how much advance notice they need to
actually do a thing (some people are type-A and won't act on same-day asks).
When you create/assign work, **respect it**: schedule far enough ahead, and if
the operator asks for something sooner, surface the conflict ("Jordan needs ~1
day; this is in 3 hours") rather than silently scheduling it.

## 6.5 The activity log — facts vs. the plan

Assignments are the **plan** ("X *should* do Y"). Activities are the **fact**
("X *did* Y at time T") — the backward-looking record you audit. Two ways facts
get logged:

1. **Spontaneous** — `activities_log` for something done out of the blue, no
   assignment behind it. Set `actor` (delegatee slug; `me` = the operator),
   `occurred_at` (defaults to now; back-date for past events), and optionally
   `category` (the audit grouping key — keep it consistent), `duration_minutes`,
   `goal_id`, `assignment_id`.
2. **Completion** — marking an assignment `done` (`assignments_set_status`, or a
   per-occurrence done) **auto-logs** an `assignment_completion` activity for you,
   attributed to the assignee (or `me` if unassigned). It's **deduped** per
   (assignment, occurrence), so re-completing never double-logs. Don't *also*
   `activities_log` a completion — it's already recorded.

So the log is *complete*: planned-and-done **and** out-of-the-blue both land in it.
"Didn't do it" is the **absence** of an activity — record it on the plan with the
`skipped` status, not as an activity.

**Auditing is the point.** `activities_summary` returns counts (+ total minutes)
grouped by actor and/or category over an optional window, busiest bucket first —
that's how you answer "what does Jordan do too much of" or "what does a typical
week look like". For row-level detail use `activities_search` (filter by actor,
category, window, linked assignment).

Activities are **editable and deletable** (a log, not raw capture — contrast §4),
but every write is settings-gated (`activities` in the matrix) and delete needs
the confirm-token handshake (§7).

## 7. Destructive operations & confirm-tokens

`*_remove` / `*_delete` are destructive and **gated twice**: by the settings
permission matrix, and by a **confirm-token** handshake.

1. Call the tool with **no `confirm_token`**. It returns a **normal (non-error)
   result** — a plan dict with `needs_confirm: true`, a single-use
   **`confirm_token`**, and a human `summary` of exactly what will be deleted.
   (An `isError: true` here means something else went wrong — e.g. the target
   wasn't found or the delete is disabled in settings.)
2. Show the operator that summary, get a yes, then call the tool again with the
   `confirm_token`. The token is payload-bound and single-use; a wrong/stale one
   comes back as `isError: true` ("Confirm token is unknown, already used, or
   expired"). The token expires **[verify: expiry window set in Phase 3]**.

If a delete is disabled by settings, you'll get a `PermissionDenied` result —
tell the operator to enable it in the app if they want it.

## 8. Errors

Business/validation problems come back as **results with `isError: true`** and
an actionable message — read it and self-correct (e.g. "delegatee slug already
exists; use delegatees_upsert to update"). Only malformed/unknown-tool calls are
protocol-level JSON-RPC errors. Don't treat an `isError` result as a crash;
it's feedback.

## 9. Known gotchas & caveats

- **Per-account scoping is absolute** — you can't see other accounts; don't try.
- **`command_whoami` before promising writes** — settings may have a capability
  off.
- **Notes can't be deleted** — see §4; don't design a flow that assumes it.
- **Confirm-tokens are single-use & payload-bound** — re-fetch if you changed
  the target between calls.
- **Pagination cursors are opaque** — never parse or fabricate them; a missing
  `nextCursor` means end-of-results **[confirmed]**.
- **Lead-time warnings are advisory** — the server won't stop a too-soon
  assignment; you and the operator are responsible for honoring it.

### Empirically confirmed in Phase-3 testing

- **An invalid/expired bearer fails at connect** `[verified]` — `initialize`
  raises (the transport rejects before any tool runs), not a tool `isError`.
  Don't retry a rejected token; fix the header.
- **Tool results are JSON** `[verified]` — a result's content is the tool's
  return object serialized as JSON text (plus `structuredContent`). Parse it;
  don't expect prose.
- **The two-step delete is enforced** `[verified]` — a `*_remove` / `*_delete`
  with a wrong or stale `confirm_token` returns `isError: "Confirm token is
  unknown, already used, or expired"`. Use the exact token from the immediately
  preceding plan call; it is single-use and payload-bound.
- **`notes_mark_processed` is allowed even though notes can't be edited** — it is
  a reversible workflow flag (`processed_at`), not a content edit, so it sits
  outside the forbidden notes `update`/`delete` actions. It has its own settings
  permission **`notes.process`** (default on; the operator can disable it), so
  every MCP write — this one included — is governed by settings. Use it to keep
  `unprocessed` searches meaningful.
- **Transport is stateless** `[verified]` — each call is independent; don't rely
  on session state between calls.
- **Rate limiting is not yet enforced** — planned at the tunnel/edge in a later
  phase. For now, still avoid hammering auth in a loop.
