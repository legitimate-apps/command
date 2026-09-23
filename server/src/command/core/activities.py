"""Activities — the fact log: "X did Y at time T".

The backward-looking counterpart to assignments (the plan). An activity is logged
out-of-the-blue (a spontaneous thing someone did) OR auto-created when a planned
thing is marked done (`log_completion`, deduped). Either way it lands in one log
the operator and the agent can audit: who did what, how often, the shape of a day.

Unlike notes, activities are a log — editable + deletable — but, like everything
else, gated by the settings matrix at the surface. The actor is a delegatee
(including the hidden "Me"); reads denormalize the actor's slug/name for the agent.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime
from typing import Any

from pydantic import BaseModel

from ..db import now_iso
from ..errors import NotFound, ValidationError
from . import _cursor, quotas
from . import delegatees as delegatees_core
from . import goals as goals_core

VALID_SOURCES = {"manual", "mcp", "assignment_completion"}
VALID_GROUP_DIMS = {"actor", "category"}
MAX_LIMIT = 200

_SELECT = (
    "SELECT a.*, d.slug AS actor_slug, d.name AS actor_name "
    "FROM activities a LEFT JOIN delegatees d ON d.id = a.actor_id"
)


class Activity(BaseModel):
    id: int
    account_id: int
    actor_id: int | None
    actor_slug: str | None
    actor_name: str | None
    title: str
    details: str | None
    category: str | None
    occurred_at: str
    duration_minutes: int | None
    goal_id: int | None
    assignment_id: int | None
    occurrence_date: str | None
    source: str
    hidden: bool = False  # invisible-ink veil; excluded from agent reads by default
    created_at: str
    updated_at: str


class ActivitySummaryRow(BaseModel):
    """One audit bucket: a count (+ total minutes) for an actor and/or category."""

    actor_id: int | None = None
    actor_slug: str | None = None
    actor_name: str | None = None
    category: str | None = None
    count: int
    total_minutes: int


def _row(r: sqlite3.Row) -> Activity:
    return Activity(
        id=r["id"],
        account_id=r["account_id"],
        actor_id=r["actor_id"],
        actor_slug=r["actor_slug"],
        actor_name=r["actor_name"],
        title=r["title"],
        details=r["details"],
        category=r["category"],
        occurred_at=r["occurred_at"],
        duration_minutes=r["duration_minutes"],
        goal_id=r["goal_id"],
        assignment_id=r["assignment_id"],
        occurrence_date=r["occurrence_date"],
        source=r["source"],
        hidden=r["hidden"],
        created_at=r["created_at"],
        updated_at=r["updated_at"],
    )


def _validate_dt(value: str, *, field: str) -> str:
    try:
        datetime.fromisoformat(value)
    except (ValueError, TypeError) as exc:
        raise ValidationError(
            f"{field} must be an ISO-8601 datetime.", hint="e.g. '2026-06-16T14:30:00+00:00'"
        ) from exc
    return value


def _resolve_actor(
    conn: sqlite3.Connection,
    account_id: int,
    actor_id: int | None,
    actor_slug: str | None,
) -> int:
    """Return a validated actor delegatee id; default to the account's "Me"."""
    if actor_slug is not None:
        return delegatees_core.get(conn, account_id, slug=actor_slug).id
    if actor_id is not None:
        return delegatees_core.get(conn, account_id, delegatee_id=actor_id).id
    return delegatees_core.ensure_self(conn, account_id).id


def _check_assignment(conn: sqlite3.Connection, account_id: int, assignment_id: int) -> None:
    row = conn.execute(
        "SELECT 1 FROM assignments WHERE id = ? AND account_id = ?", (assignment_id, account_id)
    ).fetchone()
    if row is None:
        raise NotFound(f"No assignment with id {assignment_id}.")


def create(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    title: str,
    actor_id: int | None = None,
    actor_slug: str | None = None,
    details: str | None = None,
    category: str | None = None,
    occurred_at: str | None = None,
    duration_minutes: int | None = None,
    goal_id: int | None = None,
    assignment_id: int | None = None,
    occurrence_date: str | None = None,
    source: str = "manual",
    hidden: bool = False,
) -> Activity:
    title = (title or "").strip()
    if not title:
        raise ValidationError("Activity title is required.", hint="e.g. 'Took out the trash'")
    if source not in VALID_SOURCES:
        raise ValidationError(f"source must be one of {sorted(VALID_SOURCES)}.")
    if duration_minutes is not None and duration_minutes < 0:
        raise ValidationError("duration_minutes cannot be negative.")
    occurred_at = _validate_dt(occurred_at, field="occurred_at") if occurred_at else now_iso()
    resolved_actor = _resolve_actor(conn, account_id, actor_id, actor_slug)
    if goal_id is not None:
        goals_core.get(conn, account_id, goal_id)  # ownership; raises NotFound
    if assignment_id is not None:
        _check_assignment(conn, account_id, assignment_id)
    category = category.strip() if isinstance(category, str) and category.strip() else None
    quotas.check_rows(conn, account_id, "activity")
    ts = now_iso()
    cur = conn.execute(
        "INSERT INTO activities (account_id, actor_id, title, details, category, occurred_at, "
        "duration_minutes, goal_id, assignment_id, occurrence_date, source, hidden, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            account_id,
            resolved_actor,
            title,
            details,
            category,
            occurred_at,
            duration_minutes,
            goal_id,
            assignment_id,
            occurrence_date,
            source,
            1 if hidden else 0,
            ts,
            ts,
        ),
    )
    return get(conn, account_id, int(cur.lastrowid or 0))


def get(conn: sqlite3.Connection, account_id: int, activity_id: int) -> Activity:
    r = conn.execute(
        f"{_SELECT} WHERE a.id = ? AND a.account_id = ?", (activity_id, account_id)
    ).fetchone()
    if r is None:
        raise NotFound(f"No activity with id {activity_id}.")
    return _row(r)


def get_for_agent(
    conn: sqlite3.Connection, account_id: int, activity_id: int, *, include_hidden: bool
) -> Activity:
    """Read one logged activity on behalf of an agent, honouring the invisible-ink veil.

    See `notes.get_for_agent`. `hidden` is documented on the model as "excluded from agent reads
    by default" and `search`/`summary` honour it, but `get` never did — so a hidden activity
    could be read in full via its id, and ids are sequential. Raises `NotFound` rather than a
    permission error: confirming something exists behind the veil is itself the leak.
    """
    activity = get(conn, account_id, activity_id)
    if activity.hidden and not include_hidden:
        raise NotFound(f"No activity with id {activity_id}.")
    return activity


def search(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    query: str | None = None,
    actor_id: int | None = None,
    actor_slug: str | None = None,
    category: str | None = None,
    goal_id: int | None = None,
    assignment_id: int | None = None,
    source: str | None = None,
    start: str | None = None,
    end: str | None = None,
    include_hidden: bool = False,
    limit: int = 50,
    cursor: str | None = None,
) -> tuple[list[Activity], str | None]:
    """List activities most-recent-first by `occurred_at`. Keyset-paginated on
    (occurred_at, id), so back-dated entries page correctly."""
    limit = max(1, min(limit, MAX_LIMIT))
    if actor_slug is not None and actor_id is None:
        actor_id = delegatees_core.get(conn, account_id, slug=actor_slug).id
    where = ["a.account_id = ?"]
    params: list[Any] = [account_id]
    if query:
        where.append("(a.title LIKE ? OR a.details LIKE ?)")
        params.extend([f"%{query}%", f"%{query}%"])
    if actor_id is not None:
        where.append("a.actor_id = ?")
        params.append(actor_id)
    if category is not None:
        where.append("a.category = ?")
        params.append(category)
    if goal_id is not None:
        where.append("a.goal_id = ?")
        params.append(goal_id)
    if assignment_id is not None:
        where.append("a.assignment_id = ?")
        params.append(assignment_id)
    if source is not None:
        where.append("a.source = ?")
        params.append(source)
    if start is not None:
        _validate_dt(start, field="start")  # else a bad string does a silent lexical SQL compare
        where.append("a.occurred_at >= ?")
        params.append(start)
    if end is not None:
        _validate_dt(end, field="end")
        where.append("a.occurred_at <= ?")
        params.append(end)
    if not include_hidden:
        where.append("a.hidden = 0")
    if cursor:
        c = _cursor.decode(cursor, require=("occurred_at", "id"))
        where.append("(a.occurred_at < ? OR (a.occurred_at = ? AND a.id < ?))")
        params.extend([c["occurred_at"], c["occurred_at"], int(c["id"])])
    sql = f"{_SELECT} WHERE {' AND '.join(where)} ORDER BY a.occurred_at DESC, a.id DESC LIMIT ?"
    params.append(limit + 1)
    rows = conn.execute(sql, params).fetchall()
    items = [_row(r) for r in rows[:limit]]
    next_cursor = (
        _cursor.encode({"occurred_at": items[-1].occurred_at, "id": items[-1].id})
        if len(rows) > limit
        else None
    )
    return items, next_cursor


def update(
    conn: sqlite3.Connection,
    account_id: int,
    activity_id: int,
    *,
    title: str | None = None,
    actor_id: int | None = None,
    actor_slug: str | None = None,
    details: str | None = None,
    category: str | None = None,
    occurred_at: str | None = None,
    duration_minutes: int | None = None,
    goal_id: int | None = None,
    hidden: bool | None = None,
) -> Activity:
    """Correct a logged activity. None = leave unchanged (the common case)."""
    get(conn, account_id, activity_id)  # ownership
    sets: list[str] = []
    params: list[Any] = []
    if title is not None:
        title = title.strip()
        if not title:
            raise ValidationError("Activity title cannot be empty.")
        sets.append("title = ?")
        params.append(title)
    if actor_id is not None or actor_slug is not None:
        sets.append("actor_id = ?")
        params.append(_resolve_actor(conn, account_id, actor_id, actor_slug))
    if details is not None:
        sets.append("details = ?")
        params.append(details)
    if category is not None:
        sets.append("category = ?")
        params.append(category.strip() or None)
    if occurred_at is not None:
        sets.append("occurred_at = ?")
        params.append(_validate_dt(occurred_at, field="occurred_at"))
    if duration_minutes is not None:
        if duration_minutes < 0:
            raise ValidationError("duration_minutes cannot be negative.")
        sets.append("duration_minutes = ?")
        params.append(duration_minutes)
    if goal_id is not None:
        goals_core.get(conn, account_id, goal_id)  # ownership
        sets.append("goal_id = ?")
        params.append(goal_id)
    if hidden is not None:
        sets.append("hidden = ?")
        params.append(1 if hidden else 0)
    if sets:
        sets.append("updated_at = ?")
        params.extend([now_iso(), activity_id, account_id])
        conn.execute(f"UPDATE activities SET {', '.join(sets)} WHERE id = ? AND account_id = ?", params)
    return get(conn, account_id, activity_id)


def delete(conn: sqlite3.Connection, account_id: int, activity_id: int) -> Activity:
    target = get(conn, account_id, activity_id)
    from . import task_items as task_items_core  # lazy: task_items imports this module

    task_items_core.delete_for_parent(conn, account_id, "activity", activity_id)
    conn.execute("DELETE FROM activities WHERE id = ? AND account_id = ?", (activity_id, account_id))
    return target


def summary(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    start: str | None = None,
    end: str | None = None,
    actor_id: int | None = None,
    include_hidden: bool = False,
    group_by: tuple[str, ...] = ("actor", "category"),
) -> list[ActivitySummaryRow]:
    """Audit rollup: counts + total minutes grouped by actor and/or category over a
    window. This is what answers "what does Jordan do too much of" and "what does a
    day look like." Buckets are ordered by count, busiest first."""
    dims = [g for g in group_by if g in VALID_GROUP_DIMS] or ["actor", "category"]
    select_cols: list[str] = []
    group_cols: list[str] = []
    if "actor" in dims:
        select_cols += ["a.actor_id AS actor_id", "d.slug AS actor_slug", "d.name AS actor_name"]
        group_cols.append("a.actor_id")
    if "category" in dims:
        select_cols.append("a.category AS category")
        group_cols.append("a.category")
    where = ["a.account_id = ?"]
    params: list[Any] = [account_id]
    if start is not None:
        where.append("a.occurred_at >= ?")
        params.append(start)
    if end is not None:
        where.append("a.occurred_at <= ?")
        params.append(end)
    if actor_id is not None:
        where.append("a.actor_id = ?")
        params.append(actor_id)
    if not include_hidden:
        where.append("a.hidden = 0")
    sql = (
        f"SELECT {', '.join(select_cols)}, COUNT(*) AS count, "
        "COALESCE(SUM(a.duration_minutes), 0) AS total_minutes "
        "FROM activities a LEFT JOIN delegatees d ON d.id = a.actor_id "
        f"WHERE {' AND '.join(where)} GROUP BY {', '.join(group_cols)} "
        "ORDER BY count DESC, total_minutes DESC"
    )
    rows = conn.execute(sql, params).fetchall()
    return [
        ActivitySummaryRow(
            actor_id=r["actor_id"] if "actor" in dims else None,
            actor_slug=r["actor_slug"] if "actor" in dims else None,
            actor_name=r["actor_name"] if "actor" in dims else None,
            category=r["category"] if "category" in dims else None,
            count=r["count"],
            total_minutes=r["total_minutes"],
        )
        for r in rows
    ]


def log_completion(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    assignment_id: int,
    title: str,
    assignee_id: int | None,
    goal_id: int | None = None,
    occurrence_date: str | None = None,
) -> Activity:
    """Record (once) that a planned thing was done. Called from assignments when a
    status flips to 'done'. Deduped by (assignment, occurrence) — repeated or
    re-done calls return the existing fact instead of duplicating it. Actor is the
    assignee; an unassigned-but-done task is attributed to "Me"."""
    if occurrence_date is None:
        existing = conn.execute(
            "SELECT id FROM activities WHERE account_id = ? AND assignment_id = ? "
            "AND occurrence_date IS NULL AND source = 'assignment_completion' LIMIT 1",
            (account_id, assignment_id),
        ).fetchone()
    else:
        existing = conn.execute(
            "SELECT id FROM activities WHERE account_id = ? AND assignment_id = ? "
            "AND occurrence_date = ? AND source = 'assignment_completion' LIMIT 1",
            (account_id, assignment_id, occurrence_date),
        ).fetchone()
    if existing is not None:
        return get(conn, account_id, int(existing["id"]))
    return create(
        conn,
        account_id,
        title=title,
        actor_id=assignee_id,
        goal_id=goal_id,
        assignment_id=assignment_id,
        occurrence_date=occurrence_date,
        source="assignment_completion",
    )
