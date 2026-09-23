-- APNs push delivery (B4). Two tables:
--   device_tokens  — the APNs device tokens registered by a user's installed apps. Upserted by
--                    token (globally unique per install); env distinguishes sandbox (dev/TestFlight)
--                    from production so the sender picks the right APNs host.
--   sent_reminders — a send-once ledger so the scheduled reminder job never double-pushes the same
--                    occurrence's reminder (keyed by assignment + occurrence day).

CREATE TABLE device_tokens (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id   INTEGER NOT NULL REFERENCES accounts(id),
    token        TEXT    NOT NULL UNIQUE,          -- hex APNs device token
    platform     TEXT    NOT NULL DEFAULT 'ios',
    environment  TEXT    NOT NULL DEFAULT 'production',  -- 'sandbox' | 'production'
    created_at   TEXT    NOT NULL,
    updated_at   TEXT    NOT NULL
);

CREATE INDEX idx_device_tokens_account ON device_tokens(account_id);

CREATE TABLE sent_reminders (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id      INTEGER NOT NULL REFERENCES accounts(id),
    assignment_id   INTEGER NOT NULL,
    occurrence_date TEXT    NOT NULL,   -- the occurrence's calendar day (YYYY-MM-DD)
    remind_at       TEXT    NOT NULL,   -- when the reminder was due
    sent_at         TEXT    NOT NULL,
    UNIQUE (account_id, assignment_id, occurrence_date)
);
