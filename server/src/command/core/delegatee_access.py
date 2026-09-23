"""Invite-backed sessions and the deliberately narrow delegatee data surface."""

from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
from collections.abc import Callable
from datetime import datetime, timedelta

from pydantic import BaseModel

from ..db import now_iso
from ..errors import AuthFailed, NotFound, ValidationError
from . import accounts, clock, push
from . import activities as activities_core
from . import assignments as assignments_core
from . import attachments as attachments_core
from ._wordlist import WORDLIST
from .accounts import Account, _hash_session_token, _row_to_account
from .delegatees import Delegatee

ALLOWED_STATUSES = {"done", "in_progress", "blocked", "skipped"}
# How long an unredeemed invite stays valid. Long enough to cover "I'll set it up at the
# weekend"; short enough that a code sitting in an old message thread is dead.
INVITE_TTL = timedelta(days=14)


class DelegateeSession(BaseModel):
    raw_token: str
    expires_at: str
    account: Account
    delegatee: Delegatee


def _hash_invite_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


# Words per invite. Five rather than four: the wordlist is 1295 entries, so four words is
# ~41 bits and five is ~52. That margin is what actually protects the invite space — the
# per-token rate limiter cannot (an attacker varies the token every guess, so every attempt
# lands on a fresh key; see rest/auth.py). Widening costs nothing: invites are verified by
# hash, never parsed, so every already-issued four-word invite keeps working.
_INVITE_WORDS = 5


def _new_invite_token(conn: sqlite3.Connection) -> str:
    for _ in range(8):
        raw = "inv-" + "-".join(secrets.choice(WORDLIST) for _ in range(_INVITE_WORDS))
        if conn.execute(
            "SELECT 1 FROM delegatee_invites WHERE token_hash = ?", (_hash_invite_token(raw),)
        ).fetchone() is None:
            return raw
    raise RuntimeError("could not generate a unique delegatee invite")  # pragma: no cover


def create_invite(conn: sqlite3.Connection, account_id: int, delegatee_id: int) -> str:
    delegatee = conn.execute(
        "SELECT * FROM delegatees WHERE id = ? AND account_id = ?",
        (delegatee_id, account_id),
    ).fetchone()
    if delegatee is None:
        raise NotFound("No such delegatee.")
    if delegatee["kind"] != "human" or delegatee["is_self"]:
        raise ValidationError("Invites are only available for human delegatees.")
    if not delegatee["active"]:
        raise ValidationError("An inactive delegatee cannot be invited.")

    # Regeneration invalidates every previously issued session (and its device tokens)
    # before replacing the invite.
    push.delete_for_delegatee(conn, account_id, delegatee_id)
    conn.execute(
        "DELETE FROM sessions WHERE account_id = ? AND delegatee_id = ?",
        (account_id, delegatee_id),
    )
    conn.execute("DELETE FROM delegatee_invites WHERE delegatee_id = ?", (delegatee_id,))
    raw = _new_invite_token(conn)
    now = clock.now()
    conn.execute(
        "INSERT INTO delegatee_invites (account_id, delegatee_id, token_hash, created_at, expires_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (account_id, delegatee_id, _hash_invite_token(raw), now.isoformat(),
         (now + INVITE_TTL).isoformat()),
    )
    return raw


def invite_expires_at(conn: sqlite3.Connection, account_id: int, delegatee_id: int) -> str | None:
    """When the delegatee's current invite stops working (None if there is none)."""
    row = conn.execute(
        "SELECT created_at, expires_at FROM delegatee_invites WHERE account_id = ? AND delegatee_id = ?",
        (account_id, delegatee_id),
    ).fetchone()
    return None if row is None else _expiry(row).isoformat()


def _expiry(row: sqlite3.Row) -> datetime:
    if row["expires_at"]:
        return datetime.fromisoformat(row["expires_at"])
    return datetime.fromisoformat(row["created_at"]) + INVITE_TTL   # pre-0024 rows


def revoke_invite(conn: sqlite3.Connection, account_id: int, delegatee_id: int) -> None:
    row = conn.execute(
        "SELECT id FROM delegatees WHERE id = ? AND account_id = ?",
        (delegatee_id, account_id),
    ).fetchone()
    if row is None:
        raise NotFound("No such delegatee.")
    ts = now_iso()
    conn.execute(
        "UPDATE delegatee_invites SET revoked_at = ? WHERE account_id = ? AND delegatee_id = ? "
        "AND revoked_at IS NULL",
        (ts, account_id, delegatee_id),
    )
    conn.execute(
        "DELETE FROM sessions WHERE account_id = ? AND delegatee_id = ?",
        (account_id, delegatee_id),
    )
    # A revoked delegatee must also stop receiving pushes, not just lose API access.
    push.delete_for_delegatee(conn, account_id, delegatee_id)


def redeem_invite(conn: sqlite3.Connection, raw_token: str, *, days: int = 30) -> DelegateeSession:
    token = (raw_token or "").strip()
    row = conn.execute(
        "SELECT a.*, i.id AS i_id, i.created_at AS i_created_at, i.expires_at AS i_expires_at, "
        "i.redeemed_at AS i_redeemed_at, "
        "d.id AS d_id, d.account_id AS d_account_id, d.slug AS d_slug, "
        "d.name AS d_name, d.kind AS d_kind, d.lead_time_minutes AS d_lead_time_minutes, "
        "d.metadata AS d_metadata, d.active AS d_active, d.is_self AS d_is_self, "
        "d.created_at AS d_created_at, d.updated_at AS d_updated_at "
        "FROM delegatee_invites i JOIN accounts a ON a.id = i.account_id "
        "JOIN delegatees d ON d.id = i.delegatee_id AND d.account_id = i.account_id "
        "WHERE i.token_hash = ? AND i.revoked_at IS NULL AND d.active = 1 AND d.kind = 'human'",
        (_hash_invite_token(token),),
    ).fetchone()
    if row is None:
        raise AuthFailed("Invalid or revoked invite token.")
    # Distinct messages from here on: the caller already proved they hold a real code, so
    # saying WHY it no longer works leaks nothing and tells them what to do.
    if row["i_redeemed_at"] is not None:
        raise AuthFailed(
            "This invite has already been used. Ask the person who invited you for a new one."
        )
    expiry = datetime.fromisoformat(row["i_expires_at"]) if row["i_expires_at"] else (
        datetime.fromisoformat(row["i_created_at"]) + INVITE_TTL
    )
    if expiry <= clock.now():
        raise AuthFailed(
            "This invite has expired. Ask the person who invited you for a new one."
        )
    spent = conn.execute(
        "UPDATE delegatee_invites SET redeemed_at = ? WHERE id = ? AND redeemed_at IS NULL",
        (now_iso(), row["i_id"]),
    )
    if spent.rowcount != 1:   # a concurrent redemption won the race
        raise AuthFailed(
            "This invite has already been used. Ask the person who invited you for a new one."
        )
    delegatee = Delegatee(
        id=row["d_id"], account_id=row["d_account_id"], slug=row["d_slug"], name=row["d_name"],
        kind=row["d_kind"], lead_time_minutes=row["d_lead_time_minutes"],
        metadata=json.loads(row["d_metadata"] or "{}"), active=bool(row["d_active"]),
        is_self=bool(row["d_is_self"]), created_at=row["d_created_at"], updated_at=row["d_updated_at"],
    )
    raw_session = secrets.token_urlsafe(32)
    ts = now_iso()
    expires_at = (clock.now() + timedelta(days=days)).isoformat()
    conn.execute(
        "INSERT INTO sessions (token_hash, account_id, delegatee_id, created_at, expires_at, last_seen_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (_hash_session_token(raw_session), row["id"], delegatee.id, ts, expires_at, ts),
    )
    return DelegateeSession(
        raw_token=raw_session, expires_at=expires_at, account=_row_to_account(row), delegatee=delegatee
    )


def delegatee_for_session(
    conn: sqlite3.Connection,
    token: str,
    *,
    policy: accounts.SessionPolicy = accounts.DEFAULT_SESSION_POLICY,
    on_renew: Callable[[str], None] | None = None,
) -> tuple[Account, Delegatee] | None:
    """Resolve a delegatee-scoped session, sliding its expiry like an operator session.

    Delegatees are other people, often checking in only when something is assigned to
    them; a silent fixed-window logout is how a delegatee stops using the app entirely.
    """
    if not token:
        return None
    token_hash = _hash_session_token(token)
    row = conn.execute(
        "SELECT s.expires_at AS session_expires_at, s.created_at AS session_created_at, a.*, d.id AS d_id, "
        "d.account_id AS d_account_id, d.slug AS d_slug, d.name AS d_name, d.kind AS d_kind, "
        "d.lead_time_minutes AS d_lead_time_minutes, d.metadata AS d_metadata, "
        "d.active AS d_active, d.is_self AS d_is_self, d.created_at AS d_created_at, "
        "d.updated_at AS d_updated_at FROM sessions s JOIN accounts a ON a.id = s.account_id "
        "JOIN delegatees d ON d.id = s.delegatee_id AND d.account_id = s.account_id "
        "WHERE s.token_hash = ? AND s.delegatee_id IS NOT NULL AND d.active = 1",
        (token_hash,),
    ).fetchone()
    if row is None:
        return None
    if datetime.fromisoformat(
        row["session_expires_at"]
    ) <= clock.now() or accounts.session_is_past_absolute_cap(row["session_created_at"], policy):
        conn.execute("DELETE FROM sessions WHERE token_hash = ?", (token_hash,))
        return None
    renewed = accounts.touch_session(
        conn,
        token_hash,
        created_at=row["session_created_at"],
        expires_at=row["session_expires_at"],
        policy=policy,
    )
    if renewed is not None and on_renew is not None:
        on_renew(renewed)
    delegatee = Delegatee(
        id=row["d_id"], account_id=row["d_account_id"], slug=row["d_slug"], name=row["d_name"],
        kind=row["d_kind"], lead_time_minutes=row["d_lead_time_minutes"],
        metadata=json.loads(row["d_metadata"] or "{}"), active=bool(row["d_active"]),
        is_self=bool(row["d_is_self"]), created_at=row["d_created_at"], updated_at=row["d_updated_at"],
    )
    return _row_to_account(row), delegatee


def my_assignments(
    conn: sqlite3.Connection, account_id: int, delegatee_id: int
) -> list[assignments_core.Assignment]:
    rows = conn.execute(
        "SELECT * FROM assignments WHERE account_id = ? AND assignee_id = ? AND hidden = 0 "
        "AND archived_at IS NULL "
        "AND status NOT IN ('done', 'cancelled', 'skipped') ORDER BY id DESC",
        (account_id, delegatee_id),
    ).fetchall()
    return [assignments_core._row(row) for row in rows]


def my_calendar(
    conn: sqlite3.Connection, account_id: int, delegatee_id: int, start: str, end: str
) -> tuple[list[assignments_core.Occurrence], bool]:
    """(occurrences, truncated) — see `assignments.calendar_window`."""
    return assignments_core.calendar_window(
        conn, account_id, start, end, include_hidden=False, assignee_id=delegatee_id
    )


def _scoped_assignment(
    conn: sqlite3.Connection, account_id: int, delegatee_id: int, assignment_id: int
) -> assignments_core.Assignment:
    row = conn.execute(
        "SELECT * FROM assignments WHERE id = ? AND account_id = ? AND assignee_id = ? "
        "AND hidden = 0 AND archived_at IS NULL",
        (assignment_id, account_id, delegatee_id),
    ).fetchone()
    if row is None:
        raise NotFound("No such assignment.")
    return assignments_core._row(row)


def _validate_status(status: str) -> None:
    if status not in ALLOWED_STATUSES:
        raise ValidationError(f"status must be one of {sorted(ALLOWED_STATUSES)}.")


def set_my_assignment_status(
    conn: sqlite3.Connection, account_id: int, delegatee_id: int, assignment_id: int, status: str
) -> assignments_core.Assignment:
    current = _scoped_assignment(conn, account_id, delegatee_id, assignment_id)
    _validate_status(status)
    updated = assignments_core.set_status(conn, account_id, assignment_id, status)
    if status != "done" and status != current.status:
        activities_core.create(
            conn, account_id, title=f"Marked {current.title} {status}", actor_id=delegatee_id,
            assignment_id=assignment_id, source="manual",
        )
    return updated


def set_my_occurrence_status(
    conn: sqlite3.Connection, account_id: int, delegatee_id: int, assignment_id: int,
    occurrence_date: str, status: str,
) -> None:
    current = _scoped_assignment(conn, account_id, delegatee_id, assignment_id)
    _validate_status(status)
    prior = conn.execute(
        "SELECT status FROM occurrence_status WHERE assignment_id = ? AND occurrence_date = ?",
        (assignment_id, occurrence_date),
    ).fetchone()
    assignments_core.set_occurrence_status(
        conn, account_id, assignment_id, occurrence_date, status
    )
    if status != "done" and (prior is None or prior["status"] != status):
        activities_core.create(
            conn, account_id, title=f"Marked {current.title} {status}", actor_id=delegatee_id,
            assignment_id=assignment_id, occurrence_date=occurrence_date, source="manual",
        )


def my_assignment_attachments(
    conn: sqlite3.Connection, account_id: int, delegatee_id: int, assignment_id: int
) -> list[attachments_core.Attachment]:
    """Read-only: attachments on ONE of the delegatee's own assignments (else NotFound)."""
    _scoped_assignment(conn, account_id, delegatee_id, assignment_id)
    return attachments_core.list_for(conn, account_id, "assignment", assignment_id)


def my_attachment_for_download(
    conn: sqlite3.Connection, account_id: int, delegatee_id: int, attachment_id: int
) -> attachments_core.Attachment:
    """Resolve an attachment for download iff it hangs off an assignment assigned to this
    delegatee. Note attachments are invisible here by design (default-closed surface)."""
    meta = attachments_core.get(conn, account_id, attachment_id)
    if meta.entity_kind != "assignment":
        raise NotFound("No such attachment.")
    _scoped_assignment(conn, account_id, delegatee_id, meta.entity_id)
    return meta
