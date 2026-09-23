-- 0011_agent_budget.sql — real-USD agent budget on the entitlement row (decision 2026-07-06).
--
-- The monetization model (docs/decisions/2026-07-06-credits-usd-model.md): the backend always
-- tracks a REAL-USD agent budget per account; "credits" are a display concept only (the client
-- shows `budget_usd × CREDIT_MULTIPLIER` with a `$`). On each subscription purchase/renewal the
-- budget is *reset* (not accumulated) to `subscription_price / CREDIT_MULTIPLIER`; each agent turn
-- debits its real provider cost; the next turn is gated when the budget is exhausted.
--
-- `budget_period_ref` is the RevenueCat event id that last set the budget — a redelivered renewal
-- webhook (same id) is a no-op, so a period the user has already spent into is never re-granted.
--
-- Entirely inert until COMMAND_CREDITS_ENABLED=true: the gate, debit, and reporting ignore the
-- budget otherwise, and comp/unsubscribed accounts stay governed by the flat monthly cap exactly
-- as before. NOT NULL DEFAULT 0 so every existing entitlement row reads a zero budget safely.

ALTER TABLE entitlements ADD COLUMN ai_budget_usd_remaining REAL NOT NULL DEFAULT 0;
ALTER TABLE entitlements ADD COLUMN budget_period_ref TEXT;
