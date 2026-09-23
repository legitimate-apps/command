-- Archive for assignments: distinct from the `hidden` redact veil (hidden = veiled but
-- still present/on the calendar; archived = out of every default view, calendar, reminder,
-- and delegatee surface — recoverable from the Archived filter, never auto-deleted).
ALTER TABLE assignments ADD COLUMN archived_at TEXT;
