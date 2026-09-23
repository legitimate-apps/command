-- 0008_detail_pages.sql — entity detail pages (Assignment / Goal / Log).
--
-- Adds a persistent free-text working area + a shared checklist, plus assignment provenance.
-- Logs reuse activities.details as their free-text area; assignments/goals get a new `notes`
-- field so the short details/description stays a descriptor. `task_items` is the checklist for
-- any of the three parents (mix of user-added and, later, AI-generated items).

ALTER TABLE assignments ADD COLUMN notes TEXT;
ALTER TABLE assignments ADD COLUMN origin TEXT;   -- 'manual' | 'agent' | 'note:<id>' (provenance)
ALTER TABLE goals ADD COLUMN notes TEXT;

CREATE TABLE task_items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id  INTEGER NOT NULL REFERENCES accounts(id),
    parent_type TEXT    NOT NULL,   -- 'assignment' | 'goal' | 'activity'
    parent_id   INTEGER NOT NULL,
    text        TEXT    NOT NULL,
    done        INTEGER NOT NULL DEFAULT 0,
    source      TEXT    NOT NULL DEFAULT 'user',   -- 'user' | 'ai'
    position    INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT    NOT NULL,
    updated_at  TEXT    NOT NULL
);

CREATE INDEX idx_task_items_parent ON task_items(account_id, parent_type, parent_id, position, id);
