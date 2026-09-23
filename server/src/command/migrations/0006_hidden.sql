-- 0006_hidden.sql — invisible-ink "hidden" veil for captures.
--
-- A hidden note / activity / assignment is created and stored normally, but (a) it
-- renders under an animated invisible-ink veil in the app, and (b) it is excluded
-- from AI-agent reads by default — the core search/list/calendar functions filter
-- `hidden = 0` unless a caller explicitly passes include_hidden=True. It is a
-- reversible privacy veil (like iMessage invisible ink), not deletion or encryption.

ALTER TABLE notes ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
ALTER TABLE activities ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
ALTER TABLE assignments ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
