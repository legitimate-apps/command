-- 0020_reap_orphaned_account_rows — delete rows left behind by a pre-cascade account delete.
--
-- OBSERVED on the live database 2026-08-05: `PRAGMA foreign_key_check` reported 4 violations —
-- two `settings` rows and two `access_tokens` rows whose `account_id` pointed at an account that
-- no longer exists. Both of those tables declare `ON DELETE CASCADE`, so the rows can only have
-- survived a deletion performed on a connection where `PRAGMA foreign_keys` was OFF (it is set
-- per-connection in `db.py`, so anything touching the file outside the app — an early migration,
-- a manual `sqlite3` session — bypasses it).
--
-- Verified before writing this: today's `delete_account` leaves **zero** violations, so this is
-- historical residue and not an ongoing leak. Verified too that the residue was not dangerous —
-- `account_for_access_token` INNER JOINs `accounts`, so an orphaned token resolves to `None` and
-- cannot authenticate, and `accounts.id` is `AUTOINCREMENT`, so a future account can never be
-- issued a deleted account's id and inherit its orphans. It is corruption, not a hole.
--
-- Written as a migration rather than a one-off `DELETE` on the box so that every deployment
-- (and every restored backup) self-heals exactly once, and the reasoning travels with the fix.
-- Idempotent by construction: on a clean database every statement matches nothing.
--
-- Covers all 24 tables carrying an `account_id`, enumerated from the schema rather than typed
-- from memory. `notes_fts*` are FTS5 shadow tables with no `account_id` and are maintained by
-- triggers on `notes`, so they are correctly absent.

DELETE FROM access_tokens     WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM activities        WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM agent_messages    WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM agent_threads     WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM agent_usage       WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM assignments       WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM attachments       WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM audit_log         WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM confirm_tokens    WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM credit_ledger     WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM delegatee_invites WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM delegatees        WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM device_tokens     WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM entitlements      WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM goals             WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM llm_budget        WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM note_revisions    WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM notes             WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM peer_exchanges    WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM peers             WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM sent_reminders    WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM sessions          WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM settings          WHERE account_id NOT IN (SELECT id FROM accounts);
DELETE FROM task_items        WHERE account_id NOT IN (SELECT id FROM accounts);
