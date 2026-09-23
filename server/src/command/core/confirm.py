"""Per-account confirm tokens for destructive MCP operations.

A payload-bound, single-use, TTL'd confirm-token pattern, applied to
a per-account SQLite table. A destructive tool issues a token on the first call
(returning a plan) and consumes it on the second — the token is bound to the
account, the tool, and a fingerprint of the payload, so it can't be replayed
against a different target.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
from datetime import datetime, timedelta
from typing import Any

from pydantic import BaseModel

from ..db import now_iso
from ..errors import ConfirmRequired
from . import clock

DEFAULT_TTL_SECONDS = 300


def fingerprint(payload: object) -> str:
    """Stable, non-cryptographic fingerprint binding a confirm token to its plan."""
    blob = json.dumps(payload, sort_keys=True, default=str).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()[:16]


def issue(
    conn: sqlite3.Connection,
    account_id: int,
    tool: str,
    payload: object,
    *,
    ttl_seconds: int = DEFAULT_TTL_SECONDS,
    thread_id: int | None = None,
    turn_id: int | None = None,
    summary: str | None = None,
) -> tuple[str, int]:
    """Issue a single-use confirm token. Returns (token, ttl_seconds).

    `thread_id`/`turn_id` bind a token issued inside an agent conversation to the user message
    that started the issuing turn; such a token is consumable only via `consume_next_turn`, by
    the NEXT user message in that thread. MCP issues unbound tokens (both None)."""
    sweep(conn)
    token = secrets.token_urlsafe(12)
    now = clock.now()
    expires_at = (now + timedelta(seconds=ttl_seconds)).isoformat()
    conn.execute(
        "INSERT INTO confirm_tokens (token, account_id, tool, payload_hash, created_at, expires_at,"
        " thread_id, issued_turn, summary, args_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            token, account_id, tool, fingerprint(payload), now.isoformat(), expires_at,
            thread_id, turn_id, summary, json.dumps(payload, sort_keys=True, default=str),
        ),
    )
    return token, ttl_seconds


def consume(
    conn: sqlite3.Connection,
    account_id: int,
    tool: str,
    confirm_token: str | None,
    payload: object,
) -> None:
    """Validate + consume a confirm token. Raises ConfirmRequired on any mismatch.

    The token is deleted regardless of outcome (single-use): a failed retry sees
    the same "unknown / used / expired" path as a never-issued token.
    """
    if not confirm_token:
        raise ConfirmRequired(
            f"{tool} is destructive — call once without confirm_token to get a plan + token, "
            "then call again with that token to execute.",
            hint="show the returned summary to the user and get a yes before the second call",
        )
    row = conn.execute(
        "SELECT account_id, tool, payload_hash, expires_at, issued_turn FROM confirm_tokens"
        " WHERE token = ?",
        (confirm_token,),
    ).fetchone()
    if row is not None:
        conn.execute("DELETE FROM confirm_tokens WHERE token = ?", (confirm_token,))
    if row is None:
        raise ConfirmRequired("Confirm token is unknown, already used, or expired — re-issue the plan.")
    if row["issued_turn"] is not None:
        # Issued inside an agent conversation; only that conversation's next turn may use it.
        raise ConfirmRequired("Confirm token is unknown, already used, or expired — re-issue the plan.")
    _check(row, account_id, tool, payload)


def _check(row: sqlite3.Row, account_id: int, tool: str, payload: object) -> None:
    if row["account_id"] != account_id:
        raise ConfirmRequired("Confirm token belongs to a different account.")
    if datetime.fromisoformat(row["expires_at"]) < clock.now():
        raise ConfirmRequired("Confirm token expired — re-issue the plan.")
    if row["tool"] != tool:
        raise ConfirmRequired(f"Confirm token was issued for a different tool ({row['tool']}).")
    if row["payload_hash"] != fingerprint(payload):
        raise ConfirmRequired("The target changed since the plan was issued — re-issue and re-confirm.")


def _user_turns_between(
    conn: sqlite3.Connection, thread_id: int, after: int, before: int
) -> int:
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM agent_messages WHERE thread_id = ? AND role = 'user'"
        " AND id > ? AND id < ?",
        (thread_id, after, before),
    ).fetchone()
    return int(row["n"])


def consume_next_turn(
    conn: sqlite3.Connection,
    account_id: int,
    tool: str,
    confirm_token: str | None,
    payload: object,
    *,
    thread_id: int | None,
    turn_id: int | None,
) -> None:
    """Consume a token issued inside an agent conversation — only from the user's NEXT message.

    The threat is a model that plans AND executes a destructive call in one turn: a prompt
    injection in a fetched page or a peer's reply can drive both halves, and the "approval" is
    then the model's own. Binding consumption to a later user turn puts a real message from the
    conversation's principal between issue and execute. It must be the IMMEDIATELY following
    turn, so a stale plan the user ignored can't be executed by a later injection either.

    A token presented in the SAME turn is refused without being burned: the legitimate flow is
    to show the summary and wait, and the token has to survive for the reply. Every other
    failure consumes it, like `consume`.
    """
    if not confirm_token:
        consume(conn, account_id, tool, confirm_token, payload)   # raises the "call twice" hint
        return
    row = conn.execute(
        "SELECT account_id, tool, payload_hash, expires_at, thread_id, issued_turn"
        " FROM confirm_tokens WHERE token = ?",
        (confirm_token,),
    ).fetchone()
    if row is None:
        raise ConfirmRequired("Confirm token is unknown, already used, or expired — re-issue the plan.")
    same_conversation = (
        row["issued_turn"] is not None
        and thread_id is not None
        and turn_id is not None
        and row["thread_id"] == thread_id
        and row["account_id"] == account_id
    )
    if same_conversation and turn_id <= row["issued_turn"]:
        raise ConfirmRequired(
            "This deletion needs the user's approval in their NEXT message — you can't confirm "
            "it in the same turn you planned it. Show the user the summary and stop; if they "
            "approve, the token is offered back to you on their next message.",
        )
    conn.execute("DELETE FROM confirm_tokens WHERE token = ?", (confirm_token,))
    if not same_conversation:
        raise ConfirmRequired("Confirm token is unknown, already used, or expired — re-issue the plan.")
    if _user_turns_between(conn, int(thread_id or 0), row["issued_turn"], int(turn_id or 0)):
        raise ConfirmRequired(
            "That plan was not approved in the user's very next message, so it lapsed — "
            "re-issue it and ask again."
        )
    _check(row, account_id, tool, payload)


class Pending(BaseModel):
    tool: str
    args: dict[str, Any]
    summary: str | None
    confirm_token: str
    expires_at: str


def pending_for_turn(
    conn: sqlite3.Connection, account_id: int, thread_id: int, turn_id: int
) -> list[Pending]:
    """Unexpired plans issued by the turn immediately before `turn_id` in this thread — the
    ones the user's message `turn_id` may be approving. Fed to that turn's run context, since
    the tool call that returned the token is not replayed in history."""
    prev = conn.execute(
        "SELECT MAX(id) AS id FROM agent_messages WHERE thread_id = ? AND account_id = ?"
        " AND role = 'user' AND id < ?",
        (thread_id, account_id, turn_id),
    ).fetchone()
    if prev is None or prev["id"] is None:
        return []
    rows = conn.execute(
        "SELECT token, tool, summary, args_json, expires_at FROM confirm_tokens"
        " WHERE account_id = ? AND thread_id = ? AND issued_turn = ? AND expires_at >= ?"
        " ORDER BY created_at",
        (account_id, thread_id, prev["id"], now_iso()),
    ).fetchall()
    return [
        Pending(
            tool=r["tool"], args=json.loads(r["args_json"] or "{}"), summary=r["summary"],
            confirm_token=r["token"], expires_at=r["expires_at"],
        )
        for r in rows
    ]


def sweep(conn: sqlite3.Connection) -> None:
    conn.execute("DELETE FROM confirm_tokens WHERE expires_at < ?", (now_iso(),))
