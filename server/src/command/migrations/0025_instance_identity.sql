-- A per-instance identity, generated once.
--
-- Command is self-hostable, and every instance numbers its accounts from 1. The iOS app
-- identified a RevenueCat customer by the bare account id, so account 1 on every instance was
-- the SAME RevenueCat customer: one person's subscription unlocked, expired or refilled the
-- budget of an unrelated account on someone else's server. The billing identity is now
-- `<instance_id>:<account_id>` (core/entitlements.billing_user_id), unique across instances.
--
-- 32 lowercase hex characters from SQLite's CSPRNG. INSERT OR IGNORE so a re-run can never
-- rotate it: changing it would orphan every existing RevenueCat customer.
CREATE TABLE IF NOT EXISTS instance_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT OR IGNORE INTO instance_meta (key, value) VALUES ('instance_id', lower(hex(randomblob(16))));
