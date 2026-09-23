-- 0004_agent.sql
-- The AI agent (Phase B): a per-account usage meter (hard-capped each period) and
-- persisted chat threads. All per-account-scoped; guarded once by schema_migrations.

CREATE TABLE IF NOT EXISTS agent_usage (
    account_id    INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    period        TEXT NOT NULL,                 -- billing period, YYYY-MM for now
    cost_usd      REAL NOT NULL DEFAULT 0,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    runs          INTEGER NOT NULL DEFAULT 0,
    updated_at    TEXT NOT NULL,
    PRIMARY KEY (account_id, period)
);

CREATE TABLE IF NOT EXISTS agent_threads (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    title      TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_threads_account ON agent_threads(account_id, updated_at);

CREATE TABLE IF NOT EXISTS agent_messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id  INTEGER NOT NULL REFERENCES agent_threads(id) ON DELETE CASCADE,
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    role       TEXT NOT NULL,                    -- user | assistant
    content    TEXT NOT NULL,
    model      TEXT,
    cost_usd   REAL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_messages_thread ON agent_messages(thread_id, id);
