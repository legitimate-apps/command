-- Delegatee invites become single-use and expiring.
--
-- An invite code was valid forever and for any number of redemptions, so a code forwarded,
-- screenshotted or left in a message thread was a standing key to the delegatee's view — each
-- redemption minted a fresh 30-day session. Now a code expires (core/delegatee_access
-- INVITE_TTL, 14 days, from `expires_at`; NULL = created_at + INVITE_TTL for legacy rows) and
-- is spent on first redemption (`redeemed_at`).
ALTER TABLE delegatee_invites ADD COLUMN expires_at  TEXT;
ALTER TABLE delegatee_invites ADD COLUMN redeemed_at TEXT;

-- A legacy invite whose delegatee already has (or had) a session was evidently used.
UPDATE delegatee_invites SET redeemed_at = created_at
 WHERE revoked_at IS NULL
   AND EXISTS (SELECT 1 FROM sessions s WHERE s.delegatee_id = delegatee_invites.delegatee_id);
