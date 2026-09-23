# Later-bucket trio: attachments · per-occurrence reschedule · sync niceties

Scope (2026-07-19):
attachments = **any file type, notes + assignments**; calendar drag on a recurring
occurrence = **moves just that occurrence** (override layer); sync = **foreground +
post-mutation refresh, pull-to-refresh with proper animations**. Agentic auto-run
remains deferred (`docs/decisions/2026-07-19-agentic-auto-run-deferred.md`) and is untouched by this work.

## 1 — Attachments

**Server.** Migration `0017_attachments.sql`:

```sql
CREATE TABLE attachments (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  entity_kind TEXT NOT NULL CHECK (entity_kind IN ('note','assignment')),
  entity_id INTEGER NOT NULL,
  filename TEXT NOT NULL,          -- original name, shown in UI, download name
  mime TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  stored_name TEXT NOT NULL,       -- opaque uuid on disk; never the user filename
  created_at TEXT NOT NULL
);
CREATE INDEX idx_attachments_entity ON attachments(account_id, entity_kind, entity_id);
```

Bytes live on disk (never in SQLite): `<db dir>/attachments/<account_id>/<stored_name>`
(config `attachments_dir` overrides; default derives from `db_path`). The data dir is
already restic-backed. Caps: `max_attachment_bytes` (default 25 MB) and
`max_attachments_per_entity` (default 20) — enforced in `core/`, actionable errors.

`core/attachments.py`: `save` (validates entity ownership via notes/assignments core,
caps, atomic write tmp→rename, row insert), `list_for(entity)`, `get`, `file_path`,
`delete` (row + file), `delete_for_entity`, `delete_for_account`. Hooks:
`assignments.delete` and `accounts.delete_account` remove attachment rows **and files**
(notes have no delete — Hard Rule 1 — so no note hook exists to miss).

REST (operator session): `POST /api/attachments` (multipart: `entity_kind`,
`entity_id`, `file`; needs `python-multipart`), `GET /api/attachments?entity_kind&entity_id`,
`GET /api/attachments/{id}/download` (FileResponse, original filename + mime),
`DELETE /api/attachments/{id}`. Delegatee surface (`/api/my`): **read-only**
list + download for attachments on assignments assigned to that delegatee.

**MCP: none in v1** (deliberate). Note attachments are part of the raw-input record;
exposing writes/deletes there needs the permissions-table design pass first.

**iOS.** `Attachment` model + APIClient multipart upload / list / download / delete.
Note detail + assignment detail gain an Attachments section: image thumbnails,
doc icon + filename for other types, add via PhotosPicker **and** `fileImporter`,
tap → QuickLook preview (downloaded to a temp file), swipe/context-menu delete.

## 2 — Per-occurrence reschedule (week/day calendar + drag)

**Server.** Migration `0018_occurrence_overrides.sql`:

```sql
CREATE TABLE occurrence_overrides (
  assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  occurrence_date TEXT NOT NULL,   -- ORIGINAL expansion date key (same key as occurrence_status)
  occurs_at TEXT NOT NULL,         -- the new ISO instant
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (assignment_id, occurrence_date)
);
```

The occurrence's identity **stays the original date key** — status, notes, and the
override itself all key on it. `Occurrence` gains `occurrence_date` (the key) so
clients stop deriving it from `occurs_at` (which the override now changes).

`calendar()` applies overrides in both directions: (a) an expanded occurrence whose
override moves it **out** of the query window is dropped; (b) overrides whose new
instant falls **in** the window but whose original date expanded outside it are
synthesized in (validated: the original date must be a genuine expansion date and the
assignment live/unarchived). Reminders, iCal, and delegatee calendars all flow through
`calendar()` and inherit effective times automatically.

Core: `reschedule_occurrence(conn, account, assignment_id, occurrence_date, occurs_at)`
(routine assignments only — sporadic drags edit the assignment itself) and
`clear_occurrence_override(...)`. REST:
`POST /api/assignments/{id}/occurrences/{date}/reschedule` `{occurs_at}` and
`DELETE .../reschedule` (reset to series time).

**iOS.** Calendar gains **Day** and **Week** time-grid views beside Month (picker in
the header). Occurrence blocks laid out on an hour grid; drag a block to a new slot →
sporadic: `updateAssignment(scheduledStart:)`; routine: `rescheduleOccurrence` (just
that one; a moved occurrence shows a small "modified" glyph; its context menu offers
"Reset to series time"). Works iPhone/iPad/Mac (drag via `LongPressGesture`+`DragGesture`
on touch, plain drag on Mac).

## 3 — Sync niceties (iOS-only)

- `scenePhase → .active`: silently refresh the stores backing the visible tab
  (notes/tasks/calendar/people/my-work) — no spinners, animated diff apply.
- After any mutation the owning store already refetches; audit the stragglers.
- `.refreshable` pull-to-refresh on Notes, Tasks (both segments), People, My Work,
  and the calendar agenda list — native spinner, `withAnimation` list application.

## Verification

Server: pytest per slice (upload caps, ownership 404s, delegatee scoping, override
in/out-of-window both directions, reminder honors the effective time, ruff clean).
Wire: curl multipart upload → download bytes match sha256; reschedule → /calendar
shows the moved instant with the original key. iOS: suite + sim (attach/preview/delete;
drag in day view on iPhone + iPad; pull-to-refresh). Ship = build 55 assigned Internal.
