CREATE TABLE delegatee_invites (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id    INTEGER NOT NULL REFERENCES accounts(id)   ON DELETE CASCADE,
    delegatee_id  INTEGER NOT NULL REFERENCES delegatees(id) ON DELETE CASCADE,
    token_hash    TEXT NOT NULL UNIQUE,
    created_at    TEXT NOT NULL,
    revoked_at    TEXT,
    UNIQUE(delegatee_id)
);

ALTER TABLE sessions ADD COLUMN delegatee_id INTEGER REFERENCES delegatees(id) ON DELETE CASCADE;
ALTER TABLE device_tokens ADD COLUMN delegatee_id INTEGER REFERENCES delegatees(id) ON DELETE CASCADE;
