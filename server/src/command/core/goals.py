"""Goals — assembled from notes, the parent of assignments.

`update` uses None = "leave unchanged" semantics (simple and type-clean); the
common case never needs to null a field out. `link_notes` records provenance:
which captured notes a goal came from.
"""

from __future__ import annotations

import sqlite3
from typing import Any

from pydantic import BaseModel

from ..db import now_iso
from ..errors import NotFound, ValidationError
from . import _cursor
from . import notes as notes_core
from ._unset import UNSET, Unset

VALID_STATUS = {"open", "in_progress", "done", "dropped"}
MAX_LIMIT = 200


class Goal(BaseModel):
    id: int
    account_id: int
    title: str
    description: str | None
    status: str
    target_date: str | None
    notes: str | None = None    # persistent free-text working area (detail page)
    created_at: str
    updated_at: str


def _row(r: sqlite3.Row) -> Goal:
    return Goal(**{k: r[k] for k in r.keys()})


def _check_status(status: str) -> None:
    if status not in VALID_STATUS:
        raise ValidationError(f"status must be one of {sorted(VALID_STATUS)}.")


def create(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    title: str,
    description: str | None = None,
    status: str = "open",
    target_date: str | None = None,
) -> Goal:
    title = (title or "").strip()
    if not title:
        raise ValidationError("Goal title is required.")
    _check_status(status)
    ts = now_iso()
    cur = conn.execute(
        "INSERT INTO goals (account_id, title, description, status, target_date, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (account_id, title, description, status, target_date, ts, ts),
    )
    return get(conn, account_id, int(cur.lastrowid or 0))


def get(conn: sqlite3.Connection, account_id: int, goal_id: int) -> Goal:
    r = conn.execute("SELECT * FROM goals WHERE id = ? AND account_id = ?", (goal_id, account_id)).fetchone()
    if r is None:
        raise NotFound(f"No goal with id {goal_id}.")
    return _row(r)


def list_(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    status: str | None = None,
    limit: int = 100,
    cursor: str | None = None,
) -> tuple[list[Goal], str | None]:
    limit = max(1, min(limit, MAX_LIMIT))
    where = ["account_id = ?"]
    params: list[Any] = [account_id]
    if status:
        where.append("status = ?")
        params.append(status)
    if cursor:
        where.append("id < ?")
        params.append(_cursor.decode_id(cursor))
    sql = f"SELECT * FROM goals WHERE {' AND '.join(where)} ORDER BY id DESC LIMIT ?"
    params.append(limit + 1)
    rows = conn.execute(sql, params).fetchall()
    items = [_row(r) for r in rows[:limit]]
    next_cursor = _cursor.encode({"id": items[-1].id}) if len(rows) > limit else None
    return items, next_cursor


def search(conn: sqlite3.Connection, account_id: int, q: str, *, limit: int = 20) -> list[Goal]:
    limit = max(1, min(limit, 50))
    like = f"%{q}%"
    rows = conn.execute(
        "SELECT * FROM goals WHERE account_id = ? AND (title LIKE ? OR description LIKE ?) "
        "ORDER BY id DESC LIMIT ?",
        (account_id, like, like, limit),
    ).fetchall()
    return [_row(r) for r in rows]


def update(
    conn: sqlite3.Connection,
    account_id: int,
    goal_id: int,
    *,
    title: str | None = None,
    description: str | None = None,
    status: str | None = None,
    target_date: str | Unset | None = UNSET,
    notes: str | None = None,
) -> Goal:
    """Update a goal.

    `target_date` is nullable: UNSET = unchanged · None = clear · value = set — a
    target you can set but never remove isn't a target. See `core/_unset.py`.
    """
    get(conn, account_id, goal_id)  # ownership
    sets: list[str] = []
    params: list[Any] = []
    if title is not None:
        title = title.strip()
        if not title:
            raise ValidationError("Goal title cannot be empty.")
        sets.append("title = ?")
        params.append(title)
    if description is not None:
        sets.append("description = ?")
        params.append(description)
    if status is not None:
        _check_status(status)
        sets.append("status = ?")
        params.append(status)
    if target_date is not UNSET:
        sets.append("target_date = ?")
        params.append(target_date)
    if notes is not None:
        sets.append("notes = ?")
        params.append(notes)
    if sets:
        sets.append("updated_at = ?")
        params.extend([now_iso(), goal_id, account_id])
        conn.execute(f"UPDATE goals SET {', '.join(sets)} WHERE id = ? AND account_id = ?", params)
    return get(conn, account_id, goal_id)


def delete(conn: sqlite3.Connection, account_id: int, goal_id: int) -> Goal:
    target = get(conn, account_id, goal_id)
    from . import task_items as task_items_core  # lazy: task_items imports this module

    task_items_core.delete_for_parent(conn, account_id, "goal", goal_id)
    conn.execute("DELETE FROM goals WHERE id = ? AND account_id = ?", (goal_id, account_id))
    return target


def link_notes(
    conn: sqlite3.Connection, account_id: int, goal_id: int, note_ids: list[int],
    *, include_hidden: bool,
) -> int:
    """Record provenance. `include_hidden` (no default — say which) is False on agent surfaces:
    a hidden note must read as absent, or "link note 41" succeeding vs failing becomes an oracle
    for which ids exist behind the veil. The app passes True."""
    get(conn, account_id, goal_id)  # ownership
    linked = 0
    for note_id in note_ids:
        # Validates ownership (and the veil); raises NotFound.
        notes_core.get_for_agent(conn, account_id, note_id, include_hidden=include_hidden)
        conn.execute("INSERT OR IGNORE INTO goal_notes (goal_id, note_id) VALUES (?, ?)", (goal_id, note_id))
        linked += 1
    return linked


def list_notes(
    conn: sqlite3.Connection, account_id: int, goal_id: int, *, include_hidden: bool
) -> list[notes_core.Note]:
    """The notes a goal was built from. Goals carry no veil, but their notes do: agent surfaces
    pass `include_hidden=False` so a hidden note's body (or id) never rides out on its goal."""
    get(conn, account_id, goal_id)
    hidden_clause = "" if include_hidden else " AND n.hidden = 0"
    rows = conn.execute(
        "SELECT n.* FROM notes n JOIN goal_notes gn ON gn.note_id = n.id "
        f"WHERE gn.goal_id = ? AND n.account_id = ?{hidden_clause} ORDER BY n.id DESC",
        (goal_id, account_id),
    ).fetchall()
    return [notes_core.Note(**{k: r[k] for k in r.keys()}) for r in rows]

