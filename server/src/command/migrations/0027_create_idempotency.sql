-- Row-local keys survive restarts without a separate store or expiry job.
-- NULL preserves unkeyed creates; keys are opaque and scoped per account/entity.
ALTER TABLE notes ADD COLUMN idempotency_key TEXT;
CREATE UNIQUE INDEX notes_create_key ON notes(account_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

ALTER TABLE activities ADD COLUMN idempotency_key TEXT;
CREATE UNIQUE INDEX activities_create_key ON activities(account_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

ALTER TABLE assignments ADD COLUMN idempotency_key TEXT;
CREATE UNIQUE INDEX assignments_create_key ON assignments(account_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
