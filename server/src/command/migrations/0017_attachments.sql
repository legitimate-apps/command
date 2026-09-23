-- Attachments: any-file uploads on notes and assignments (spec 2026-07-19-later-bucket).
-- Bytes live on DISK under <db dir>/attachments/<account_id>/<stored_name> — never in
-- SQLite (lean rule) — so every delete path must remove the file too, not just the row.
CREATE TABLE attachments (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  entity_kind TEXT NOT NULL CHECK (entity_kind IN ('note','assignment')),
  entity_id INTEGER NOT NULL,
  filename TEXT NOT NULL,          -- original name: shown in UI, used as the download name
  mime TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  stored_name TEXT NOT NULL,       -- opaque uuid on disk; never the user-supplied filename
  created_at TEXT NOT NULL
);

CREATE INDEX idx_attachments_entity ON attachments(account_id, entity_kind, entity_id);
