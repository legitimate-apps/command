# Entity detail pages — Assignment / Goal / Log

Dated 2026-06-26. Branch: main, behind feature flag `detailPages` (default OFF). **Status: in progress.**

Operator ask: tapping an Assignment, Goal, or Log opens a detail page that *assists completion* — the
context around its creation, a big persistent free-text working area, and a checklist that mixes
user-added items (now) with AI-generated sub-steps (later). Decisions locked 2026-06-26:
**build all three at once**; **v1 = user items + notes + context, AI-assist is a follow-up**.

---

## Data model (server)

Migration `0008_detail_pages.sql`:
- `ALTER TABLE assignments ADD COLUMN notes TEXT;`   — the big persistent working area.
- `ALTER TABLE goals ADD COLUMN notes TEXT;`         — same for goals.
- `ALTER TABLE assignments ADD COLUMN origin TEXT;`  — provenance: 'manual' | 'agent' | 'note:<id>'
  (nullable; closes the gap that only goals link to notes). Set on create; null for existing rows.
- `CREATE TABLE task_items (...)` — the checklist, shared by all three parents:
  - `id, account_id, parent_type TEXT ('assignment'|'goal'|'activity'), parent_id INTEGER,`
    `text TEXT, done INTEGER DEFAULT 0, source TEXT ('user'|'ai') DEFAULT 'user',`
    `position INTEGER, created_at, updated_at`.
  - Index `(account_id, parent_type, parent_id, position)`.

Logs (`activities`) reuse the existing `details` field as their free-text area; assignments/goals get
the new `notes` field so the short `details`/`description` stays a descriptor.

## Core + REST

- `core/task_items.py`: `list(parent_type, parent_id)`, `add`, `update` (text/done), `delete`,
  `reorder`. Account-scoped; parent ownership checked. No commit (request-scoped connection).
- Extend `assignments.update` / `goals.update` to accept `notes`; `assignments.create` to set `origin`.
- REST: `/api/assignments/{id}/items` (GET/POST), `/api/.../items/{itemId}` (PATCH/DELETE), same under
  `/api/goals/{id}/items` and `/api/activities/{id}/items`; `notes` rides the existing PATCH bodies.
- Hidden rule unchanged: a hidden parent's items inherit the veil in the app; the agent never reads them.
- Tests: task_items CRUD + scoping + reorder; notes round-trip; origin on create.

## iOS

- Flag `detailPages` (FeatureFlags). OFF ⇒ today's behaviour (inline status menu / read-only rows /
  ActivityEditSheet). ON ⇒ tapping a row pushes a detail page.
- `EntityDetailView` (generic over a small `DetailSubject` enum) with sections:
  1. Header — editable title + status control (assignment: todo→in_progress→done, done still auto-logs).
  2. Context panel — per type (assignment: due/lead/schedule/assignee/goal; goal: target + source notes
     via existing `goal_notes` + child assignments; log: occurred_at/actor/category/duration + completion
     backlink).
  3. Persistent notes — a `TextEditor` bound to `notes` (assignment/goal) or `details` (log), debounced save.
  4. Checklist — `ChecklistView` over `task_items`: add, toggle, edit, delete, drag-reorder. `source` badge
     distinguishes ai vs user items (ai unused in v1).
- Models: `TaskItem`; APIClient item endpoints; `TasksStore`/`LogStore` wiring; navigation from
  `AssignmentRow`/`GoalRow`/`ActivityRow` when the flag is on.
- Veil: a hidden parent's detail page is veiled/read-only like the list row (reuse the invisible-ink path).

## Verification ledger

| Piece | Built | Tests | Sim |
|-------|-------|-------|-----|
| Migration + core/task_items | ✅ | ✅ 6 | n/a |
| REST (notes/origin + items) | ✅ | ✅ 4 | n/a |
| iOS models + APIClient + DetailStore | ✅ | ✅ 27 iOS green | — |
| EntityDetailView (context + notes + checklist) | ✅ | n/a | ✅ render-verified |
| Navigation from Tasks/Log/Calendar (flag-gated, non-hidden → detail) | ✅ | n/a | build green |

**v1 done** (2026-06-26): full server suite 140 green, ruff+mypy clean; iOS build + 27 tests green;
detail page render-verified on sim. Behind `detailPages` flag (OFF = today's behaviour). Hidden items
keep their existing surfaces (no leak). AI-assist ("break this down") + per-type title/status editing +
goal↔note provenance view + veiled detail for hidden items are tracked follow-ups, not v1.
