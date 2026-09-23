-- 0003_note_revisions.sql
-- Notes gain an optional title (AI-generated on close, or user-set) and a small
-- capped backup history. A revision snapshots {title, body} when the user closes
-- a note; core.notes.snapshot keeps at most the newest 5 per note. Guarded once
-- by schema_migrations, so the bare ALTERs run exactly once.

ALTER TABLE notes ADD COLUMN title TEXT;
ALTER TABLE notes ADD COLUMN title_status TEXT;   -- NULL | generating | ai | user | error

CREATE TABLE IF NOT EXISTS note_revisions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id     INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    title       TEXT,
    body        TEXT NOT NULL,
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_note_revisions_note ON note_revisions(note_id, id);
