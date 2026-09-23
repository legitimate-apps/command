-- Confirm tokens issued inside an agent CONVERSATION (in-app chat, A2A) are bound to the turn
-- that issued them.
--
-- The in-app agent used to be able to issue a destructive tool's confirm token and consume it
-- in the same model turn — so a prompt injection (a fetched page, a peer's reply) could plan
-- AND execute a delete with no human in between. A token issued in a conversation now records
-- the thread and the user message (turn) it was issued under, and may only be consumed by the
-- user's NEXT message in that same thread. `summary`/`args_json` let the next turn's run
-- context show the model what is awaiting approval (tool calls aren't replayed in history).
--
-- MCP tokens leave all four NULL: the MCP contract is unchanged (plan, show the operator,
-- execute), because MCP's caller is the operator's own agent loop, not a model reading
-- untrusted content on the operator's behalf inside our server.
ALTER TABLE confirm_tokens ADD COLUMN thread_id   INTEGER;
ALTER TABLE confirm_tokens ADD COLUMN issued_turn INTEGER;
ALTER TABLE confirm_tokens ADD COLUMN summary     TEXT;
ALTER TABLE confirm_tokens ADD COLUMN args_json   TEXT;
