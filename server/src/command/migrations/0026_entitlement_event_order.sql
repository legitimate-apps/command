-- Store-event ordering + per-period budget grants for the RevenueCat mirror.
--
-- Webhooks can arrive late, twice, or out of order. The mirror applied whatever came last,
-- so a delayed EXPIRATION could overwrite a newer RENEWAL, and the budget refill deduped only
-- against the single most recent event id — any other redelivery, an UNCANCELLATION, or a
-- PRODUCT_CHANGE refilled a period the user had already spent into.
--
-- `last_event_ms`: RevenueCat `event_timestamp_ms` of the newest event applied; older ones
-- are ignored. `budget_period_start_ms`: `purchased_at_ms` of the paid period the current
-- budget was granted for; a grant for the same or an earlier period is a no-op.
ALTER TABLE entitlements ADD COLUMN last_event_ms          INTEGER;
ALTER TABLE entitlements ADD COLUMN budget_period_start_ms INTEGER;
