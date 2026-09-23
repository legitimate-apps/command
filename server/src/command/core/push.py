"""Device-token registry + a send-once ledger for APNs push reminders (B4).

The iOS app registers its APNs device token here after the user grants notification permission;
a scheduled job (later) walks `reminders.upcoming_reminders` and pushes to these tokens, recording
each send in `sent_reminders` so a given occurrence's reminder is delivered at most once.
Domain logic only — the actual APNs HTTP/2 send lives in `core/apns.py`.
"""

from __future__ import annotations

import sqlite3

from pydantic import BaseModel

from ..db import now_iso
from ..errors import ValidationError

VALID_ENVIRONMENTS = {"sandbox", "production"}


class DeviceToken(BaseModel):
    id: int
    account_id: int
    token: str
    platform: str
    environment: str
    created_at: str
    updated_at: str
    # NULL = an operator device; set = the invited delegatee whose session registered it.
    # The reminder job routes on this: delegatee devices only get their own assignments.
    delegatee_id: int | None = None


def _row(r: sqlite3.Row) -> DeviceToken:
    return DeviceToken(**{k: r[k] for k in r.keys()})


def register(
    conn: sqlite3.Connection,
    account_id: int,
    token: str,
    *,
    environment: str = "production",
    platform: str = "ios",
    delegatee_id: int | None = None,
) -> DeviceToken:
    """Upsert a device token. A token is globally unique per install, so if it re-registers
    (even under a different account after a re-login) we move it to the current account and
    refresh its environment — never leaving a stale mapping that would push to the wrong user.
    The same applies to `delegatee_id`: a device that switches between an operator login and a
    delegatee invite must be re-stamped, or it would keep the other role's reminder routing."""
    token = token.strip()
    if not token:
        raise ValidationError("token is required.")
    if environment not in VALID_ENVIRONMENTS:
        raise ValidationError(f"environment must be one of {sorted(VALID_ENVIRONMENTS)}.")
    ts = now_iso()
    conn.execute(
        "INSERT INTO device_tokens (account_id, token, platform, environment, delegatee_id, "
        "created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(token) DO UPDATE SET account_id=excluded.account_id, "
        "platform=excluded.platform, environment=excluded.environment, "
        "delegatee_id=excluded.delegatee_id, updated_at=excluded.updated_at",
        (account_id, token, platform, environment, delegatee_id, ts, ts),
    )
    r = conn.execute("SELECT * FROM device_tokens WHERE token = ?", (token,)).fetchone()
    return _row(r)


def accounts_with_tokens(conn: sqlite3.Connection) -> list[int]:
    """Account ids that have at least one registered device token (the reminder job iterates these)."""
    rows = conn.execute("SELECT DISTINCT account_id FROM device_tokens ORDER BY account_id").fetchall()
    return [r[0] for r in rows]


def list_tokens(conn: sqlite3.Connection, account_id: int) -> list[DeviceToken]:
    """Every device that may currently be pushed to for this account.

    Tokens belonging to an INACTIVE delegatee are excluded here rather than at each call site.
    Deactivating someone already cuts their API access — `delegatee_for_session` requires
    `d.active = 1` — but nothing cut their push, because tokens are only deleted on invite
    revoke/regenerate and deactivation is a different path entirely (`delegatees.upsert`,
    reachable from both the app and the agent). So a contractor you switched off kept
    receiving the titles of assignments still assigned to them, on their lock screen,
    indefinitely.

    Enforcing it at this choke point rather than by deleting rows means reactivating a
    delegatee resumes delivery immediately — no re-registration needed, and no future
    deactivation path can miss it. Operator devices (`delegatee_id IS NULL`) always qualify.
    """
    rows = conn.execute(
        "SELECT t.* FROM device_tokens t "
        "LEFT JOIN delegatees d ON d.id = t.delegatee_id AND d.account_id = t.account_id "
        "WHERE t.account_id = ? AND (t.delegatee_id IS NULL OR d.active = 1) "
        "ORDER BY t.id",
        (account_id,),
    ).fetchall()
    return [_row(r) for r in rows]


def remove(
    conn: sqlite3.Connection,
    account_id: int,
    token: str,
    *,
    only_delegatee_id: int | None = None,
) -> bool:
    """Unregister a token (e.g. on sign-out or APNs 410 Unregistered). Scoped to the account.

    `only_delegatee_id` narrows the delete to tokens that delegatee registered, and the
    delegatee surface must pass it. `register` stamps `delegatee_id` on the way in, but this
    had no matching filter on the way out — so an invited delegatee presenting someone else's
    token could unregister the OPERATOR's device and silently end their reminders and
    briefings. Operator sign-out passes None, which is correct: every device in the account is
    theirs to remove.
    """
    sql = "DELETE FROM device_tokens WHERE token = ? AND account_id = ?"
    params: list[object] = [token.strip(), account_id]
    if only_delegatee_id is not None:
        sql += " AND delegatee_id = ?"
        params.append(only_delegatee_id)
    cur = conn.execute(sql, params)
    return cur.rowcount > 0


def delete_by_token(conn: sqlite3.Connection, token: str) -> None:
    """Hard-remove a token regardless of account — for APNs 410 (BadDeviceToken/Unregistered)."""
    conn.execute("DELETE FROM device_tokens WHERE token = ?", (token.strip(),))


def delete_for_delegatee(conn: sqlite3.Connection, account_id: int, delegatee_id: int) -> None:
    """Drop every device token a delegatee registered — called on invite revoke so a revoked
    delegatee's phone stops receiving reminders along with losing its sessions."""
    conn.execute(
        "DELETE FROM device_tokens WHERE account_id = ? AND delegatee_id = ?",
        (account_id, delegatee_id),
    )


# --- send-once ledger --------------------------------------------------------

def already_sent(
    conn: sqlite3.Connection, account_id: int, assignment_id: int, occurrence_key: str
) -> bool:
    r = conn.execute(
        "SELECT 1 FROM sent_reminders WHERE account_id = ? AND assignment_id = ? AND occurrence_date = ?",
        (account_id, assignment_id, occurrence_key),
    ).fetchone()
    return r is not None


def mark_sent(
    conn: sqlite3.Connection, account_id: int, assignment_id: int, occurrence_key: str, remind_at: str
) -> bool:
    """Record a delivered occurrence's reminder by its UTC instant. Returns False if it was
    already recorded, True on the first insert."""
    try:
        conn.execute(
            "INSERT INTO sent_reminders (account_id, assignment_id, occurrence_date, remind_at, sent_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (account_id, assignment_id, occurrence_key, remind_at, now_iso()),
        )
        return True
    except sqlite3.IntegrityError:
        return False
