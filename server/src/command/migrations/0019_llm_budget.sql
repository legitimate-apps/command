-- Proactive-LLM spend guard (spec 2026-08-02-assistant-expansion).
--
-- A user who stops engaging must stop costing money: anything that spends LLM tokens on
-- their behalf WITHOUT them asking is capped at N sends since they last opened the app, and
-- opening it resets the count. The cap itself lives in config (COMMAND_MAX_LLM_SENDS_BEFORE_OPEN)
-- so it can be retuned without a migration or a code change.
--
-- The column is `llm_sends_since_open`, not `sends_since_open`, deliberately: the cap counts
-- only work that costs model tokens. A plain reminder is a template push with no model call,
-- so capping it would silence real reminders and save nothing. The name is the contract.
CREATE TABLE llm_budget (
  account_id           INTEGER PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  llm_sends_since_open INTEGER NOT NULL DEFAULT 0,
  last_send_at         TEXT,
  last_open_at         TEXT
);
