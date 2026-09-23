"""Delegatees — the roster of people and AI models you assign work to.

`upsert` is the create-or-update-by-slug primitive the MCP surface uses so the
agent never has to do a separate check-before-create: it checks internally and
reports whether it created or updated. `metadata` is a free-form JSON object
(personality, contact, model id, capabilities, ...). `lead_time_minutes` is the
advance notice this delegatee needs — the heart of the planner.
"""

from __future__ import annotations

import json
import re
import sqlite3
from typing import Any

from pydantic import BaseModel

from ..db import now_iso
from ..errors import Conflict, NotFound, ValidationError
from . import _cursor

VALID_KINDS = {"human", "ai_model"}
MAX_LIMIT = 200
_SLUG_RE = re.compile(r"[^a-z0-9]+")


class Delegatee(BaseModel):
    id: int
    account_id: int
    slug: str
    name: str
    kind: str
    lead_time_minutes: int
    metadata: dict[str, Any]
    active: bool
    is_self: bool
    created_at: str
    updated_at: str


def _row(r: sqlite3.Row) -> Delegatee:
    return Delegatee(
        id=r["id"],
        account_id=r["account_id"],
        slug=r["slug"],
        name=r["name"],
        kind=r["kind"],
        lead_time_minutes=r["lead_time_minutes"],
        metadata=json.loads(r["metadata"] or "{}"),
        active=bool(r["active"]),
        is_self=bool(r["is_self"]),
        created_at=r["created_at"],
        updated_at=r["updated_at"],
    )


def slugify(name: str) -> str:
    s = _SLUG_RE.sub("-", name.strip().lower()).strip("-")
    return s or "delegatee"


def _unique_slug(conn: sqlite3.Connection, account_id: int, base: str) -> str:
    slug, n = base, 2
    while conn.execute(
        "SELECT 1 FROM delegatees WHERE account_id = ? AND slug = ?", (account_id, slug)
    ).fetchone():
        slug, n = f"{base}-{n}", n + 1
    return slug


def exists(conn: sqlite3.Connection, account_id: int, slug: str) -> bool:
    return (
        conn.execute(
            "SELECT 1 FROM delegatees WHERE account_id = ? AND slug = ?", (account_id, slug)
        ).fetchone()
        is not None
    )


def get(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    delegatee_id: int | None = None,
    slug: str | None = None,
) -> Delegatee:
    if delegatee_id is not None:
        r = conn.execute(
            "SELECT * FROM delegatees WHERE id = ? AND account_id = ?", (delegatee_id, account_id)
        ).fetchone()
    elif slug is not None:
        r = conn.execute(
            "SELECT * FROM delegatees WHERE slug = ? AND account_id = ?", (slug, account_id)
        ).fetchone()
    else:
        raise ValidationError("Provide delegatee_id or slug.")
    if r is None:
        raise NotFound("No such delegatee.", hint="use delegatees_search to find the right slug")
    return _row(r)


def list_(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    active_only: bool = False,
    include_self: bool = False,
    limit: int = 100,
    cursor: str | None = None,
) -> tuple[list[Delegatee], str | None]:
    limit = max(1, min(limit, MAX_LIMIT))
    where = ["account_id = ?"]
    params: list[Any] = [account_id]
    if active_only:
        where.append("active = 1")
    if not include_self:
        where.append("is_self = 0")  # the "Me" actor is hidden from the delegate-to-others roster
    if cursor:
        where.append("id < ?")
        params.append(_cursor.decode_id(cursor))
    sql = f"SELECT * FROM delegatees WHERE {' AND '.join(where)} ORDER BY id DESC LIMIT ?"
    params.append(limit + 1)
    rows = conn.execute(sql, params).fetchall()
    items = [_row(r) for r in rows[:limit]]
    next_cursor = _cursor.encode({"id": items[-1].id}) if len(rows) > limit else None
    return items, next_cursor


def search(
    conn: sqlite3.Connection,
    account_id: int,
    q: str,
    *,
    include_self: bool = False,
    limit: int = 20,
) -> list[Delegatee]:
    limit = max(1, min(limit, 50))
    like = f"%{q}%"
    self_clause = "" if include_self else "AND is_self = 0 "
    rows = conn.execute(
        f"SELECT * FROM delegatees WHERE account_id = ? AND (name LIKE ? OR slug LIKE ?) {self_clause}"
        "ORDER BY active DESC, name ASC LIMIT ?",
        (account_id, like, like, limit),
    ).fetchall()
    return [_row(r) for r in rows]


def upsert(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    name: str,
    slug: str | None = None,
    kind: str | None = None,
    lead_time_minutes: int | None = None,
    metadata: dict[str, Any] | None = None,
    active: bool | None = None,
) -> tuple[Delegatee, bool]:
    """Create or update a delegatee by slug. Returns (delegatee, created).

    On UPDATE only the fields actually passed change (None = leave as is). This used to write
    every field with its default, so an agent's "add Sam" — which knows only the name — reset
    Sam's lead time to 0, wiped his metadata, and silently RE-ACTIVATED him after the operator
    had switched him off (reviving his old sessions with it). A delegatee is only ever
    reactivated by an explicit `active=True`. On CREATE the defaults are human / 0 / {} /
    active.

    Deactivating (active True -> False) also ends the delegatee's sessions, so a later
    reactivation needs a fresh invite rather than resurrecting old logins.
    """
    name = (name or "").strip()
    if not name:
        raise ValidationError("Delegatee name is required.")
    if kind is not None and kind not in VALID_KINDS:
        raise ValidationError(f"kind must be one of {sorted(VALID_KINDS)}.")
    if lead_time_minutes is not None and lead_time_minutes < 0:
        raise ValidationError("lead_time_minutes cannot be negative.")
    ts = now_iso()

    # Idempotent by canonical slug: an explicit `slug`, else one derived from `name`.
    # If a delegatee with that slug already exists, UPDATE it in place — so calling
    # upsert twice with the same name updates one row instead of creating "sam-2"
    # (honors "see if people exist before doing operations"). A genuinely separate
    # person who shares a name needs an explicit distinct slug.
    lookup_slug = slugify(slug) if slug else slugify(name)
    row = conn.execute(
        "SELECT id, active FROM delegatees WHERE account_id = ? AND slug = ?",
        (account_id, lookup_slug),
    ).fetchone()
    if row is not None:
        sets: list[str] = ["name = ?"]
        params: list[Any] = [name]
        for col, val in (
            ("kind", kind),
            ("lead_time_minutes", lead_time_minutes),
            ("metadata", json.dumps(metadata) if metadata is not None else None),
            ("active", int(active) if active is not None else None),
        ):
            if val is not None:
                sets.append(f"{col} = ?")
                params.append(val)
        conn.execute(
            f"UPDATE delegatees SET {', '.join(sets)}, updated_at = ? WHERE id = ?",
            (*params, ts, row["id"]),
        )
        if active is False and row["active"]:
            conn.execute(
                "DELETE FROM sessions WHERE account_id = ? AND delegatee_id = ?",
                (account_id, row["id"]),
            )
        return get(conn, account_id, delegatee_id=int(row["id"])), False
    new_slug = _unique_slug(conn, account_id, lookup_slug)

    cur = conn.execute(
        "INSERT INTO delegatees (account_id, slug, name, kind, lead_time_minutes, metadata, active, "
        "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            account_id, new_slug, name, kind or "human", lead_time_minutes or 0,
            json.dumps(metadata or {}), 0 if active is False else 1, ts, ts,
        ),
    )
    return get(conn, account_id, delegatee_id=int(cur.lastrowid or 0)), True


def remove(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    delegatee_id: int | None = None,
    slug: str | None = None,
) -> Delegatee:
    """Hard-delete a delegatee. Assignments referencing it have assignee_id set NULL (FK)."""
    target = get(conn, account_id, delegatee_id=delegatee_id, slug=slug)
    if target.is_self:
        # The "Me" self-actor is a structural singleton every account owns; deleting it
        # nulls actor_id on the account's own activity history. Refuse.
        raise Conflict("The 'Me' actor can't be deleted.")
    conn.execute("DELETE FROM delegatees WHERE id = ? AND account_id = ?", (target.id, account_id))
    return target


# ---------- the "Me" self actor ----------
#
# Every account owns exactly one delegatee with is_self=1: the operator themselves.
# It makes the operator's own activity (and, later, self-scheduling) uniform with
# everyone else's, while staying hidden from the delegate-to-others roster
# (list_/search default include_self=False).

SELF_SLUG = "me"
SELF_NAME = "Me"


def get_self(conn: sqlite3.Connection, account_id: int) -> Delegatee | None:
    r = conn.execute(
        "SELECT * FROM delegatees WHERE account_id = ? AND is_self = 1 ORDER BY id LIMIT 1",
        (account_id,),
    ).fetchone()
    return _row(r) if r else None


def ensure_self(conn: sqlite3.Connection, account_id: int) -> Delegatee:
    """Return the account's "Me" delegatee, creating it if absent (idempotent)."""
    existing = get_self(conn, account_id)
    if existing is not None:
        return existing
    slug = _unique_slug(conn, account_id, SELF_SLUG)
    ts = now_iso()
    cur = conn.execute(
        "INSERT INTO delegatees (account_id, slug, name, kind, lead_time_minutes, metadata, active, "
        "is_self, created_at, updated_at) VALUES (?, ?, ?, 'human', 0, '{}', 1, 1, ?, ?)",
        (account_id, slug, SELF_NAME, ts, ts),
    )
    return get(conn, account_id, delegatee_id=int(cur.lastrowid or 0))


def backfill_self(conn: sqlite3.Connection) -> int:
    """Ensure every existing account has a "Me" delegatee. Returns how many were created."""
    created = 0
    for r in conn.execute("SELECT id FROM accounts").fetchall():
        if get_self(conn, int(r["id"])) is None:
            ensure_self(conn, int(r["id"]))
            created += 1
    return created
