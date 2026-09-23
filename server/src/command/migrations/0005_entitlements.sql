-- 0005_entitlements.sql
-- Subscription entitlements + AI-disclosure consent for the agent (Phase B slice 3).
-- One row per account, mirrored from RevenueCat webhooks so the agent endpoint can
-- gate on a fast local read. Gating is OFF by default (agent_require_subscription)
-- so this never locks anyone out until billing is live. Guarded by schema_migrations.

CREATE TABLE IF NOT EXISTS entitlements (
    account_id   INTEGER PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    product_id   TEXT,
    status       TEXT NOT NULL DEFAULT 'none',   -- none | active | grace | expired | comp
    period_type  TEXT,                            -- trial | intro | normal (from the store)
    store        TEXT,                            -- app_store | revenuecat | comp
    expires_at   TEXT,                            -- ISO-8601; null = no expiry (comp)
    will_renew   INTEGER NOT NULL DEFAULT 0,
    consent_at   TEXT,                            -- AI-disclosure consent timestamp (audit)
    updated_at   TEXT NOT NULL
);
