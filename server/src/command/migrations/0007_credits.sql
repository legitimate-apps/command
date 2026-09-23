-- 0007_credits.sql — pay-per-token credit ledger (monetization scaffolding).
--
-- The Assistant is gated by: consent AND (active subscription OR credit balance > 0). Credits
-- are bought as consumable IAP packs (App-Store-compliant metered use) and spent per token of
-- agent usage. This is an append-only ledger; the balance is SUM(delta). `ref` is an idempotency
-- key (the store transaction / webhook event id) so a redelivered grant is a no-op. Entirely
-- inert until `COMMAND_CREDITS_ENABLED=true` — the gate and reporting ignore it otherwise, so
-- existing accounts behave exactly as before.

CREATE TABLE credit_ledger (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL REFERENCES accounts(id),
    delta      INTEGER NOT NULL,   -- +grant (purchase), -debit (token usage)
    reason     TEXT    NOT NULL,   -- 'purchase' | 'usage' | 'grant' | 'refund'
    ref        TEXT,               -- idempotency key (store txn / webhook event id)
    created_at TEXT    NOT NULL
);

CREATE INDEX idx_credit_ledger_account ON credit_ledger(account_id, id);
CREATE UNIQUE INDEX idx_credit_ledger_ref ON credit_ledger(ref) WHERE ref IS NOT NULL;
