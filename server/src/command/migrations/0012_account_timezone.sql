-- 0012_account_timezone.sql — the user's IANA timezone for date interpretation.
-- Nullable keeps existing accounts compatible until the iOS client reports its zone.

ALTER TABLE accounts ADD COLUMN timezone TEXT;
