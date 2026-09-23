# Activity Log — design (2026-06-16)

Status: **approved** (operator chose "Me" as a real hidden delegatee — option a).
Builds on `2026-06-16-command-design.md`.

## Problem

Command models the **plan** (assignments: routine/sporadic, with a status + a
per-occurrence status overlay). It has no model of the **fact** — "X *did* Y at
time T" — independent of a plan. The operator wants to:

1. Log things people did **out of the blue** (no assignment behind them), for
   themselves and for delegatees.
2. **Audit** the result over MCP: who does what, who does too much of it, the
   shape of a day.

A plan is intent (forward-looking); a fact is a record (backward-looking).
Conflating them is wrong: a routine assignment yields *many* completion facts
over time, and a spontaneous fact has *no* assignment. So: a new entity.

## Model — `activity`

One row = "a thing that happened."

| field | meaning |
|---|---|
| `actor_id` | who did it — a delegatee (incl. the hidden **"Me"**); nullable |
| `title` / `details` | what they did |
| `category` | free-form bucket, the audit grouping key (autocomplete in app) |
| `occurred_at` | when (defaults to now, **backdatable**) |
| `duration_minutes` | optional time spent |
| `goal_id` | optional link to a goal |
| `assignment_id` + `occurrence_date` | the plan it fulfilled, if any |
| `source` | `manual` \| `mcp` \| `assignment_completion` |

Unlike notes, activities are a **log**: editable + deletable, all gated by the
settings matrix (`activities` row, all default-on; delete needs a confirm-token).

### "Me" — self as a first-class actor (decision a)

Every account auto-provisions one delegatee with `is_self = 1`, slug `me`,
name "Me". So the operator's own activity (and, later, self-scheduling) is
uniform with everyone else's. "Me" is **excluded** from the delegate-to-others
roster (`list_`/`search` gain `include_self=False` default) but resolvable by
slug and offered in the activity actor picker. Provisioned in `register()` for
new accounts and back-filled at startup for existing ones (idempotent,
unique-slug-safe). Migration `0002` adds the `is_self` column + `activities`
table only; the back-fill is Python (consistent timestamps).

### Completing a plan logs a fact

`set_status(...,"done")` and `set_occurrence_status(...,"done")` auto-create a
linked `assignment_completion` activity (actor = assignee, time = now), **deduped**
by `(assignment_id, occurrence_date, source)` so repeated/again-done calls never
double-log. This keeps the audit log *complete* — planned-and-done **and**
out-of-the-blue both land in it. "Didn't do it" stays a status on the plan (the
*absence* of a fact); a new `skipped` status reads more honestly than `cancelled`.

This is a core-level domain rule (it fires on the already-permitted status
change), not a separate `activities.create` permission check.

## Surfaces

- **core/** `activities.py` (create/get/search/update/delete + `summary` +
  `log_completion`); `delegatees.py` gains `is_self`, `ensure_self`,
  `backfill_self`; `assignments.py` gains `skipped` + the auto-log hook;
  `settings.py` gains the `activities` permission row.
- **REST** `GET/POST /api/activities`, `GET /api/activities/summary`,
  `GET/PATCH/DELETE /api/activities/{id}`. The calendar uses
  `GET /api/activities?from&to`; no new calendar endpoint.
- **MCP** `activities_log / search / get / update / delete (confirm) / summary`;
  `command_whoami` surfaces the `me` slug; `assignments_set_status` description
  notes the auto-log. `summary` is the audit tool: counts + total minutes grouped
  by actor and/or category over a window.
- **iOS** a one-tap **Log** capture beside the note box; a **Log** view (filter by
  person/category/date); spontaneous activities as calendar markers (completion
  activities render via the occurrence's done state — no double display); an edit
  sheet with a backdate picker + category autocomplete; mark-done wiring.

## Audit-surfaced follow-ups (deliberately deferred)

- Category vocabulary (free-text fragments; mitigated by app autocomplete + the
  agent normalizing) — a managed vocab is future.
- Self-scheduling (assign work to "Me") — the model now supports it; not wired.
- In-app insight rollups — MCP `summary` is the power path for v1.
