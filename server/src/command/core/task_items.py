"""Checklist items for the entity detail pages (assignment / goal / activity).

A flat, ordered list per parent. One table serves all three detail pages via (parent_type,
parent_id), account-scoped. v1 items are user-added (`source='user'`); the agent will add
`source='ai'` sub-steps in a follow-up. Per the codebase convention these functions don't commit
— the request-scoped `connection()` context manager commits on exit.
"""

from __future__ import annotations

import sqlite3

from pydantic import BaseModel

from ..errors import NotFound, ValidationError
from . import clock

VALID_PARENTS = {"assignment", "goal", "activity"}
VALID_SOURCES = {"user", "ai"}


class TaskItem(BaseModel):
    id: int
    parent_type: str
    parent_id: int
    text: str
    done: bool
    source: str
    position: int
    created_at: str
    updated_at: str


def _row(r: sqlite3.Row) -> TaskItem:
    return TaskItem(
        id=r["id"], parent_type=r["parent_type"], parent_id=r["parent_id"], text=r["text"],
        done=bool(r["done"]), source=r["source"], position=r["position"],
        created_at=r["created_at"], updated_at=r["updated_at"],
    )


def _now() -> str:
    return clock.now().isoformat()


def _check_parent(parent_type: str) -> None:
    if parent_type not in VALID_PARENTS:
        raise ValidationError(f"parent_type must be one of {sorted(VALID_PARENTS)}.")


def _get(conn: sqlite3.Connection, account_id: int, item_id: int) -> TaskItem:
    r = conn.execute(
        "SELECT * FROM task_items WHERE id = ? AND account_id = ?", (item_id, account_id)
    ).fetchone()
    if r is None:
        raise NotFound("Checklist item not found.")
    return _row(r)


def get(conn: sqlite3.Connection, account_id: int, item_id: int) -> TaskItem:
    """One item by id, account-scoped (callers resolve its parent's veil from it)."""
    return _get(conn, account_id, item_id)


def _validate_parent(
    conn: sqlite3.Connection, account_id: int, parent_type: str, parent_id: int
) -> None:
    """Raise NotFound unless the parent exists and belongs to the account. Without this an item
    could be attached to a parent id that never existed (or another account's), and would sit
    orphaned forever. Lazy imports: those modules import this one (to delete their items)."""
    if parent_type == "assignment":
        from . import assignments as assignments_core

        assignments_core.get(conn, account_id, parent_id)
    elif parent_type == "goal":
        from . import goals as goals_core

        goals_core.get(conn, account_id, parent_id)
    else:
        from . import activities as activities_core

        activities_core.get(conn, account_id, parent_id)


def delete_for_parent(
    conn: sqlite3.Connection, account_id: int, parent_type: str, parent_id: int
) -> None:
    """Remove a parent's checklist. `parent_id` is polymorphic, so there is no FK to cascade —
    every parent delete path calls this."""
    conn.execute(
        "DELETE FROM task_items WHERE account_id = ? AND parent_type = ? AND parent_id = ?",
        (account_id, parent_type, parent_id),
    )


def list_items(conn: sqlite3.Connection, account_id: int, parent_type: str,
               parent_id: int) -> list[TaskItem]:
    _check_parent(parent_type)
    # Another account's parent (or none at all) is "not found", exactly as it is for `add` —
    # an empty list would still confirm nothing, but every other surface answers 404 here.
    _validate_parent(conn, account_id, parent_type, parent_id)
    rows = conn.execute(
        "SELECT * FROM task_items WHERE account_id = ? AND parent_type = ? AND parent_id = ? "
        "ORDER BY position, id",
        (account_id, parent_type, parent_id),
    ).fetchall()
    return [_row(r) for r in rows]


def add(conn: sqlite3.Connection, account_id: int, parent_type: str, parent_id: int, *,
        text: str, source: str = "user") -> TaskItem:
    _check_parent(parent_type)
    _validate_parent(conn, account_id, parent_type, parent_id)
    text = (text or "").strip()
    if not text:
        raise ValidationError("Item text is required.")
    if source not in VALID_SOURCES:
        source = "user"
    nxt = conn.execute(
        "SELECT COALESCE(MAX(position), -1) + 1 AS p FROM task_items "
        "WHERE account_id = ? AND parent_type = ? AND parent_id = ?",
        (account_id, parent_type, parent_id),
    ).fetchone()
    now = _now()
    cur = conn.execute(
        "INSERT INTO task_items (account_id, parent_type, parent_id, text, done, source, "
        "position, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)",
        (account_id, parent_type, parent_id, text, source, int(nxt["p"]), now, now),
    )
    return _get(conn, account_id, int(cur.lastrowid or 0))


def update(conn: sqlite3.Connection, account_id: int, item_id: int, *,
           text: str | None = None, done: bool | None = None) -> TaskItem:
    sets: list[str] = []
    params: list[object] = []
    if text is not None:
        t = text.strip()
        if not t:
            raise ValidationError("Item text cannot be empty.")
        sets.append("text = ?")
        params.append(t)
    if done is not None:
        sets.append("done = ?")
        params.append(1 if done else 0)
    if not sets:
        return _get(conn, account_id, item_id)
    sets.append("updated_at = ?")
    params.append(_now())
    params += [item_id, account_id]
    cur = conn.execute(f"UPDATE task_items SET {', '.join(sets)} WHERE id = ? AND account_id = ?", params)
    if cur.rowcount == 0:
        raise NotFound("Checklist item not found.")
    return _get(conn, account_id, item_id)


def delete(conn: sqlite3.Connection, account_id: int, item_id: int) -> None:
    cur = conn.execute("DELETE FROM task_items WHERE id = ? AND account_id = ?", (item_id, account_id))
    if cur.rowcount == 0:
        raise NotFound("Checklist item not found.")


def reorder(conn: sqlite3.Connection, account_id: int, parent_type: str, parent_id: int,
            ordered_ids: list[int]) -> list[TaskItem]:
    _check_parent(parent_type)
    _validate_parent(conn, account_id, parent_type, parent_id)
    now = _now()
    for pos, iid in enumerate(ordered_ids):
        conn.execute(
            "UPDATE task_items SET position = ?, updated_at = ? "
            "WHERE id = ? AND account_id = ? AND parent_type = ? AND parent_id = ?",
            (pos, now, iid, account_id, parent_type, parent_id),
        )
    return list_items(conn, account_id, parent_type, parent_id)
