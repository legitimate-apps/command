"""Persisted agent chat threads and their messages.

Light (no pydantic-ai import) so the REST layer can list/read history cheaply.
Every row is scoped to one account; cross-account access raises NotFound. A thread
is a conversation; messages are the visible user/assistant turns (tool calls are
streamed live, not persisted — the slice-1 history is the readable transcript).
"""

from __future__ import annotations

import sqlite3

from pydantic import BaseModel

from ...db import now_iso
from ...errors import NotFound, ValidationError
from .._cursor import decode, encode

ROLE_USER = "user"
ROLE_ASSISTANT = "assistant"
# Who started a thread. Inbound A2A may only continue threads it started itself.
ORIGIN_APP = "app"
ORIGIN_A2A = "a2a"


class Thread(BaseModel):
    id: int
    account_id: int
    title: str | None
    created_at: str
    updated_at: str
    origin: str = ORIGIN_APP   # 'app' | 'a2a'


class Message(BaseModel):
    id: int
    thread_id: int
    account_id: int
    role: str
    content: str
    model: str | None = None
    cost_usd: float | None = None
    created_at: str


def _thread(row: sqlite3.Row) -> Thread:
    return Thread(
        id=row["id"], account_id=row["account_id"], title=row["title"],
        created_at=row["created_at"], updated_at=row["updated_at"], origin=row["origin"],
    )


def _message(row: sqlite3.Row) -> Message:
    return Message(
        id=row["id"], thread_id=row["thread_id"], account_id=row["account_id"],
        role=row["role"], content=row["content"], model=row["model"],
        cost_usd=row["cost_usd"], created_at=row["created_at"],
    )


def create_thread(
    conn: sqlite3.Connection, account_id: int, title: str | None = None,
    *, origin: str = ORIGIN_APP,
) -> Thread:
    ts = now_iso()
    cur = conn.execute(
        "INSERT INTO agent_threads (account_id, title, origin, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (account_id, title, origin, ts, ts),
    )
    return get_thread(conn, account_id, int(cur.lastrowid or 0))


def get_thread(conn: sqlite3.Connection, account_id: int, thread_id: int) -> Thread:
    row = conn.execute(
        "SELECT * FROM agent_threads WHERE id = ? AND account_id = ?", (thread_id, account_id)
    ).fetchone()
    if row is None:
        raise NotFound(f"No thread {thread_id}.", hint="omit thread_id to start a new conversation")
    return _thread(row)


def list_threads(
    conn: sqlite3.Connection, account_id: int, *, limit: int = 50, cursor: str | None = None
) -> tuple[list[Thread], str | None]:
    """Newest-active first, keyset-paginated by updated_at+id."""
    limit = max(1, min(limit, 200))
    params: list[object] = [account_id]
    where = "account_id = ?"
    if cursor:
        c = decode(cursor)
        where += " AND (updated_at, id) < (?, ?)"
        params += [c["updated_at"], c["id"]]
    params.append(limit + 1)
    rows = conn.execute(
        f"SELECT * FROM agent_threads WHERE {where} ORDER BY updated_at DESC, id DESC LIMIT ?",
        params,
    ).fetchall()
    items = [_thread(r) for r in rows[:limit]]
    nxt = None
    if len(rows) > limit and items:
        nxt = encode({"updated_at": items[-1].updated_at, "id": items[-1].id})
    return items, nxt


def add_message(
    conn: sqlite3.Connection, account_id: int, thread_id: int, role: str, content: str,
    *, model: str | None = None, cost_usd: float | None = None,
) -> Message:
    get_thread(conn, account_id, thread_id)  # scope check (raises NotFound)
    ts = now_iso()
    cur = conn.execute(
        "INSERT INTO agent_messages "
        "(thread_id, account_id, role, content, model, cost_usd, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (thread_id, account_id, role, content, model, cost_usd, ts),
    )
    conn.execute("UPDATE agent_threads SET updated_at = ? WHERE id = ?", (ts, thread_id))
    row = conn.execute("SELECT * FROM agent_messages WHERE id = ?", (cur.lastrowid,)).fetchone()
    return _message(row)


def list_messages(
    conn: sqlite3.Connection, account_id: int, thread_id: int, *, limit: int = 200
) -> list[Message]:
    get_thread(conn, account_id, thread_id)  # scope check
    rows = conn.execute(
        "SELECT * FROM agent_messages WHERE thread_id = ? AND account_id = ? ORDER BY id LIMIT ?",
        (thread_id, account_id, max(1, min(limit, 500))),
    ).fetchall()
    return [_message(r) for r in rows]


def set_title(conn: sqlite3.Connection, account_id: int, thread_id: int, title: str) -> Thread:
    get_thread(conn, account_id, thread_id)  # scope check
    conn.execute(
        "UPDATE agent_threads SET title = ?, updated_at = ? WHERE id = ?",
        (title, now_iso(), thread_id),
    )
    return get_thread(conn, account_id, thread_id)


def truncate_after(
    conn: sqlite3.Connection,
    account_id: int,
    thread_id: int,
    after_message_id: int,
    *,
    inclusive: bool = False,
) -> int:
    """Delete every message in the thread newer than `after_message_id`; return how many remain.

    Backs "Edit & resend" / "Regenerate": the client cuts the transcript back to a message and
    sends again, so the next run's history is the kept prefix. Scoped like everything else here
    (another account's thread is NotFound). The anchor must be a message OF THIS THREAD — an id
    from elsewhere is a client bug, not "delete nothing", so it is a validation error.

    Confirm tokens issued by the removed turns go too: their approval question is no longer in
    the conversation, so a later "yes" must not be able to execute them.

    `inclusive` also removes the anchor itself — what "Edit & resend" needs, since the client
    always knows the id of the USER message being replaced but not necessarily of the reply
    before it.
    """
    get_thread(conn, account_id, thread_id)  # scope check (raises NotFound)
    anchor = conn.execute(
        "SELECT 1 FROM agent_messages WHERE id = ? AND thread_id = ? AND account_id = ?",
        (after_message_id, thread_id, account_id),
    ).fetchone()
    if anchor is None:
        raise ValidationError(
            f"Message {after_message_id} is not in thread {thread_id}.",
            hint="pass the id of a message returned by GET /api/agent/threads/{thread_id}",
        )
    op = ">=" if inclusive else ">"  # a fixed operator, never user input
    conn.execute(
        f"DELETE FROM agent_messages WHERE thread_id = ? AND account_id = ? AND id {op} ?",
        (thread_id, account_id, after_message_id),
    )
    conn.execute(
        f"DELETE FROM confirm_tokens WHERE account_id = ? AND thread_id = ? AND issued_turn {op} ?",
        (account_id, thread_id, after_message_id),
    )
    conn.execute("UPDATE agent_threads SET updated_at = ? WHERE id = ?", (now_iso(), thread_id))
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM agent_messages WHERE thread_id = ? AND account_id = ?",
        (thread_id, account_id),
    ).fetchone()
    return int(row["n"])
