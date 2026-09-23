-- 0001_init — full Command schema.
-- Idempotent: every object is CREATE ... IF NOT EXISTS. PRAGMAs are set per
-- connection in db.py, not here.

-- Accounts: the human login.
CREATE TABLE IF NOT EXISTS accounts (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL UNIQUE,
    display_name  TEXT,
    password_hash TEXT NOT NULL,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

-- Memorable MCP bearer tokens: viewable + regenerable. Stored retrievably so the
-- operator can re-copy them into Claude Code per machine (documented trade-off).
CREATE TABLE IF NOT EXISTS access_tokens (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id   INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    token        TEXT NOT NULL UNIQUE,
    label        TEXT NOT NULL DEFAULT 'default',
    created_at   TEXT NOT NULL,
    last_used_at TEXT,
    revoked_at   TEXT
);
CREATE INDEX IF NOT EXISTS idx_access_tokens_token ON access_tokens(token);
CREATE INDEX IF NOT EXISTS idx_access_tokens_account ON access_tokens(account_id);

-- REST app login sessions. Only sha256(token) is stored; raw token lives on device.
CREATE TABLE IF NOT EXISTS sessions (
    token_hash   TEXT PRIMARY KEY,
    account_id   INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at   TEXT NOT NULL,
    expires_at   TEXT NOT NULL,
    last_seen_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_account ON sessions(account_id);

-- Notes: the raw capture. NEVER hard-deleted via MCP. `archived_at` is an
-- app-only soft hide. `processed_at` marks notes turned into goals.
CREATE TABLE IF NOT EXISTS notes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id   INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    body         TEXT NOT NULL,
    source       TEXT NOT NULL DEFAULT 'typed',   -- typed | voice
    engine       TEXT,                            -- parakeet-v3 | speechtranscriber | sfspeech | NULL
    locale       TEXT,
    processed_at TEXT,
    archived_at  TEXT,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_account ON notes(account_id, created_at);

-- Delegatees: people + AI models you assign work to.
CREATE TABLE IF NOT EXISTS delegatees (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id        INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    slug              TEXT NOT NULL,
    name              TEXT NOT NULL,
    kind              TEXT NOT NULL DEFAULT 'human',   -- human | ai_model
    lead_time_minutes INTEGER NOT NULL DEFAULT 0,
    metadata          TEXT NOT NULL DEFAULT '{}',      -- JSON: personality, contact, model_id, ...
    active            INTEGER NOT NULL DEFAULT 1,
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL,
    UNIQUE(account_id, slug)
);
CREATE INDEX IF NOT EXISTS idx_delegatees_account ON delegatees(account_id);

-- Goals: assembled from notes.
CREATE TABLE IF NOT EXISTS goals (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    description TEXT,
    status      TEXT NOT NULL DEFAULT 'open',   -- open | in_progress | done | dropped
    target_date TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_goals_account ON goals(account_id);

-- Provenance: which notes a goal came from.
CREATE TABLE IF NOT EXISTS goal_notes (
    goal_id INTEGER NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
    note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    PRIMARY KEY (goal_id, note_id)
);

-- Assignments: the planner unit; routine (RRULE) or sporadic. Shown on the calendar.
CREATE TABLE IF NOT EXISTS assignments (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id        INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    goal_id           INTEGER REFERENCES goals(id) ON DELETE SET NULL,
    title             TEXT NOT NULL,
    details           TEXT,
    assignee_id       INTEGER REFERENCES delegatees(id) ON DELETE SET NULL,
    schedule_kind     TEXT NOT NULL DEFAULT 'sporadic',  -- routine | sporadic
    rrule             TEXT,
    scheduled_start   TEXT,
    scheduled_end     TEXT,
    lead_time_minutes INTEGER,
    status            TEXT NOT NULL DEFAULT 'todo',  -- todo|scheduled|in_progress|done|blocked|cancelled
    priority          INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_assignments_account ON assignments(account_id);
CREATE INDEX IF NOT EXISTS idx_assignments_assignee ON assignments(assignee_id);

-- Per-occurrence completion overrides for routine assignments.
CREATE TABLE IF NOT EXISTS occurrence_status (
    assignment_id   INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    occurrence_date TEXT NOT NULL,
    status          TEXT NOT NULL,
    note            TEXT,
    updated_at      TEXT NOT NULL,
    PRIMARY KEY (assignment_id, occurrence_date)
);

-- Per-account settings, incl. the MCP permission matrix (operator-controlled).
CREATE TABLE IF NOT EXISTS settings (
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    key        TEXT NOT NULL,
    value      TEXT NOT NULL,   -- JSON
    updated_at TEXT NOT NULL,
    PRIMARY KEY (account_id, key)
);

-- Audit trail for MCP/REST writes + deletes.
CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    actor      TEXT NOT NULL,   -- mcp | rest
    tool       TEXT,
    action     TEXT NOT NULL,   -- create | update | delete | ...
    entity     TEXT NOT NULL,
    entity_id  INTEGER,
    summary    TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_account ON audit_log(account_id, created_at);

-- Single-use, payload-bound confirm tokens for destructive MCP ops.
CREATE TABLE IF NOT EXISTS confirm_tokens (
    token        TEXT PRIMARY KEY,
    account_id   INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    tool         TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    expires_at   TEXT NOT NULL,
    used_at      TEXT
);
