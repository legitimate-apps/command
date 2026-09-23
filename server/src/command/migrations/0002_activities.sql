-- 0002_activities — the activity log (facts) + the self ("Me") delegatee flag.
--
-- Activities record "X did Y at time T": logged out-of-the-blue or auto-created
-- when a planned thing is marked done. Distinct from assignments (the plan).
-- Editable + deletable (a log, not raw capture) — gated by the settings matrix,
-- delete behind a confirm-token, like goals/assignments.
--
-- Schema only here. The "Me" delegatee row is provisioned in Python (register()
-- for new accounts; a startup back-fill for existing ones) so timestamps match
-- now_iso() and slug collisions resolve uniquely.

-- The auto-provisioned self actor (the operator). Excluded from the
-- delegate-to-others roster, but usable as an activity actor and (later) a
-- self-scheduling assignee.
ALTER TABLE delegatees ADD COLUMN is_self INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS activities (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id       INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    actor_id         INTEGER REFERENCES delegatees(id) ON DELETE SET NULL,  -- who did it (incl. "Me")
    title            TEXT NOT NULL,
    details          TEXT,
    category         TEXT,                              -- free-form, the audit grouping key
    occurred_at      TEXT NOT NULL,                     -- when it happened (backdatable)
    duration_minutes INTEGER,                           -- optional time spent
    goal_id          INTEGER REFERENCES goals(id) ON DELETE SET NULL,
    assignment_id    INTEGER REFERENCES assignments(id) ON DELETE SET NULL,  -- the plan it fulfilled, if any
    occurrence_date  TEXT,                              -- the specific routine occurrence, if any
    source           TEXT NOT NULL DEFAULT 'manual',    -- manual | mcp | assignment_completion
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_activities_account ON activities(account_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_activities_actor ON activities(actor_id);
CREATE INDEX IF NOT EXISTS idx_activities_assignment ON activities(assignment_id);

-- Auto-logged completions are deduped in core (`log_completion` checks before
-- insert, NULL-safe on occurrence_date) — a partial UNIQUE index can't guard the
-- whole-assignment case because SQLite treats NULL occurrence_dates as distinct.
