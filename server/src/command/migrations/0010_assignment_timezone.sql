-- Recurring-event DST correctness (B5). An assignment's `scheduled_start` is an absolute instant,
-- and RRULE expansion in UTC increments the same UTC clock-time each period — so "Daily 9 AM" drifts
-- to 10 AM after a DST transition. Store the IANA timezone the assignment was created in (e.g.
-- "America/New_York") so the server can re-anchor recurrence expansion to the local wall-clock,
-- keeping 9 AM at 9 AM across DST. NULL = legacy rows: expand in UTC exactly as before (no change,
-- and no per-occurrence-status key drift for existing data).
ALTER TABLE assignments ADD COLUMN timezone TEXT;
