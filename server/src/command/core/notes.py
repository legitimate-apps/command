"""Notes — the raw capture.

Hard Rule 1 lives here in the shape of the module: there is **no** delete or
destructive-rewrite function. Notes can be created, read, searched, edited by
their owner in the app (`update_body`), soft-hidden (`set_archived`), and flagged
processed/unprocessed. They are never hard-deleted by any surface.
"""

from __future__ import annotations

import re
import sqlite3
from typing import Any

from pydantic import BaseModel

from ..db import now_iso
from ..errors import NotFound, ValidationError
from . import _cursor

VALID_SOURCES = {"typed", "voice"}
MAX_LIMIT = 200
MAX_REVISIONS = 5  # newest-N backups kept per note (one snapshot per close)
USER_TITLE = "user"  # title_status meaning "the user set this — never auto-overwrite"
_FTS_TOKEN_RE = re.compile(r"\w+", re.UNICODE)


class Note(BaseModel):
    id: int
    account_id: int
    body: str
    title: str | None = None
    title_status: str | None = None  # None | generating | ai | user | error
    source: str
    engine: str | None
    locale: str | None
    processed_at: str | None
    archived_at: str | None
    hidden: bool = False  # invisible-ink veil in the app; excluded from agent reads by default
    created_at: str
    updated_at: str


class Revision(BaseModel):
    id: int
    note_id: int
    account_id: int
    title: str | None
    body: str
    created_at: str


def _row(r: sqlite3.Row) -> Note:
    return Note(**{k: r[k] for k in r.keys()})


def _rev_row(r: sqlite3.Row) -> Revision:
    return Revision(**{k: r[k] for k in r.keys()})


def create(
    conn: sqlite3.Connection,
    account_id: int,
    body: str,
    *,
    source: str = "typed",
    engine: str | None = None,
    locale: str | None = None,
    title: str | None = None,
    hidden: bool = False,
) -> Note:
    body = (body or "").strip()
    if not body:
        raise ValidationError("Note body cannot be empty.")
    if source not in VALID_SOURCES:
        raise ValidationError(f"source must be one of {sorted(VALID_SOURCES)}.")
    title = (title or "").strip() or None
    title_status = USER_TITLE if title else None  # an explicit title is the user's
    ts = now_iso()
    cur = conn.execute(
        "INSERT INTO notes (account_id, body, source, engine, locale, title, title_status, "
        "hidden, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (account_id, body, source, engine, locale, title, title_status, 1 if hidden else 0, ts, ts),
    )
    return get(conn, account_id, int(cur.lastrowid or 0))


def get(conn: sqlite3.Connection, account_id: int, note_id: int) -> Note:
    r = conn.execute("SELECT * FROM notes WHERE id = ? AND account_id = ?", (note_id, account_id)).fetchone()
    if r is None:
        raise NotFound(f"No note with id {note_id}.")
    return _row(r)


def get_for_agent(
    conn: sqlite3.Connection, account_id: int, note_id: int, *, include_hidden: bool
) -> Note:
    """Read one note on behalf of an agent, honouring the invisible-ink veil.

    `hidden` is documented on the model as "excluded from agent reads by default", and `search`
    honours it — but `get` never did, so an agent could read any hidden note in full simply by
    asking for its id. Note ids are sequential integers, so that is enumeration, not a lucky
    guess. Every agent-facing read-by-id must come through here.

    Raises `NotFound`, not a permission error: telling the caller "that exists but you may not
    see it" leaks the very thing the veil is for. It is deliberately indistinguishable from an
    id that was never there.

    `include_hidden` has **no default** on purpose — a new call site has to state which it wants
    rather than inherit whichever default happened to be safe when it was written.
    """
    note = get(conn, account_id, note_id)
    if note.hidden and not include_hidden:
        raise NotFound(f"No note with id {note_id}.")
    return note


def search(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    query: str | None = None,
    unprocessed: bool | None = None,
    source: str | None = None,
    include_archived: bool = False,
    include_hidden: bool = False,
    limit: int = 50,
    cursor: str | None = None,
) -> tuple[list[Note], str | None]:
    limit = max(1, min(limit, MAX_LIMIT))
    where = ["account_id = ?"]
    params: list[Any] = [account_id]
    fts_query = _fts_query(query) if query else None
    if fts_query:
        where.append("id IN (SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?)")
        params.append(fts_query)
    if unprocessed is True:
        where.append("processed_at IS NULL")
    elif unprocessed is False:
        where.append("processed_at IS NOT NULL")
    if source:
        where.append("source = ?")
        params.append(source)
    if not include_archived:
        where.append("archived_at IS NULL")
    if not include_hidden:
        where.append("hidden = 0")
    if cursor:
        where.append("id < ?")
        params.append(_cursor.decode_id(cursor))
    sql = f"SELECT * FROM notes WHERE {' AND '.join(where)} ORDER BY id DESC LIMIT ?"
    params.append(limit + 1)
    rows = conn.execute(sql, params).fetchall()
    # No silent fallback: a query that matches nothing returns nothing. This used to return the
    # most recent notes INSTEAD, indistinguishable from real matches — so the app's search showed
    # unrelated notes as results, and an agent reported them as hits. Agent surfaces that want
    # the recent notes on a miss fetch them separately and label them (`search_with_fallback`).
    items = [_row(r) for r in rows[:limit]]
    next_cursor = _cursor.encode({"id": items[-1].id}) if len(rows) > limit else None
    return items, next_cursor


class SearchResult(BaseModel):
    """A search that says whether it matched. `recent` is filled only on a miss: the newest
    notes, offered for the agent to inspect itself (lexical search misses paraphrases), and
    clearly NOT presented as matches."""

    items: list[Note]
    next_cursor: str | None = None
    matched: bool
    recent: list[Note] = []


def search_with_fallback(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    query: str | None = None,
    include_hidden: bool = False,
    limit: int = 50,
    **filters: Any,
) -> SearchResult:
    items, nxt = search(
        conn, account_id, query=query, include_hidden=include_hidden, limit=limit, **filters
    )
    if items or not query or filters.get("cursor"):
        return SearchResult(items=items, next_cursor=nxt, matched=bool(items) or not query)
    recent, _ = search(
        conn, account_id, include_hidden=include_hidden, limit=limit,
        **{k: v for k, v in filters.items() if k != "cursor"},
    )
    return SearchResult(items=[], matched=False, recent=recent)


def _fts_query(query: str) -> str | None:
    """Build a safe prefix-OR expression: broad discovery without exposing FTS query syntax."""
    tokens = _FTS_TOKEN_RE.findall(query.casefold())
    return " OR ".join(f'"{token}"*' for token in tokens) or None


def update_body(conn: sqlite3.Connection, account_id: int, note_id: int, body: str) -> Note:
    get(conn, account_id, note_id)  # ownership check
    body = (body or "").strip()
    if not body:
        raise ValidationError("Note body cannot be empty.")
    conn.execute(
        "UPDATE notes SET body = ?, updated_at = ? WHERE id = ? AND account_id = ?",
        (body, now_iso(), note_id, account_id),
    )
    return get(conn, account_id, note_id)


def set_archived(conn: sqlite3.Connection, account_id: int, note_id: int, archived: bool) -> Note:
    get(conn, account_id, note_id)
    conn.execute(
        "UPDATE notes SET archived_at = ?, updated_at = ? WHERE id = ? AND account_id = ?",
        (now_iso() if archived else None, now_iso(), note_id, account_id),
    )
    return get(conn, account_id, note_id)


def set_hidden(conn: sqlite3.Connection, account_id: int, note_id: int, hidden: bool) -> Note:
    """Toggle the invisible-ink veil. Reversible; never deletes (Hard Rule 1)."""
    get(conn, account_id, note_id)  # ownership check
    conn.execute(
        "UPDATE notes SET hidden = ?, updated_at = ? WHERE id = ? AND account_id = ?",
        (1 if hidden else 0, now_iso(), note_id, account_id),
    )
    return get(conn, account_id, note_id)


def count(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    unprocessed: bool | None = None,
    include_archived: bool = False,
    include_hidden: bool = False,
) -> int:
    """How many notes match — a real COUNT, not the length of a page.

    Exists because callers that want a number were doing `len(search(limit=N))`, which silently
    reports N once there are more than N. A digest that tells the user "50 notes to triage"
    when there are 200 is stating a falsehood, so anything displaying a count uses this.
    Mirrors `search`'s filters deliberately — the filters live in one module either way.
    """
    where = ["account_id = ?"]
    params: list[Any] = [account_id]
    if unprocessed is True:
        where.append("processed_at IS NULL")
    elif unprocessed is False:
        where.append("processed_at IS NOT NULL")
    if not include_archived:
        where.append("archived_at IS NULL")
    if not include_hidden:
        where.append("hidden = 0")
    row = conn.execute(
        f"SELECT COUNT(*) FROM notes WHERE {' AND '.join(where)}", params
    ).fetchone()
    return int(row[0])


def set_processed(conn: sqlite3.Connection, account_id: int, note_id: int, processed: bool) -> Note:
    get(conn, account_id, note_id)
    conn.execute(
        "UPDATE notes SET processed_at = ?, updated_at = ? WHERE id = ? AND account_id = ?",
        (now_iso() if processed else None, now_iso(), note_id, account_id),
    )
    return get(conn, account_id, note_id)


# --- Titles (AI-generated on close, or user-set) -----------------------------


def set_title(
    conn: sqlite3.Connection, account_id: int, note_id: int, title: str | None, *, status: str
) -> Note:
    """Set the note's title and its provenance (`ai` | `user` | `error`)."""
    get(conn, account_id, note_id)  # ownership check
    title = (title or "").strip() or None
    conn.execute(
        "UPDATE notes SET title = ?, title_status = ?, updated_at = ? WHERE id = ? AND account_id = ?",
        (title, status, now_iso(), note_id, account_id),
    )
    return get(conn, account_id, note_id)


def mark_title_generating(conn: sqlite3.Connection, account_id: int, note_id: int) -> Note:
    get(conn, account_id, note_id)
    conn.execute(
        "UPDATE notes SET title_status = 'generating' WHERE id = ? AND account_id = ?",
        (note_id, account_id),
    )
    return get(conn, account_id, note_id)


def mark_title_error(conn: sqlite3.Connection, account_id: int, note_id: int) -> Note:
    get(conn, account_id, note_id)
    conn.execute(
        "UPDATE notes SET title_status = 'error' WHERE id = ? AND account_id = ?",
        (note_id, account_id),
    )
    return get(conn, account_id, note_id)


def wants_auto_title(note: Note) -> bool:
    """Auto-title unless the user titled the note themselves."""
    return note.title_status != USER_TITLE


# --- Revisions (capped backup history) ---------------------------------------


def snapshot(conn: sqlite3.Connection, account_id: int, note_id: int) -> Revision | None:
    """Capture the note's current {title, body} as a backup, unless it is identical
    to the most recent one. Keeps only the newest MAX_REVISIONS per note.

    Returns the new Revision, or None when nothing changed since the last snapshot.
    """
    note = get(conn, account_id, note_id)
    latest = conn.execute(
        "SELECT title, body FROM note_revisions WHERE note_id = ? AND account_id = ? "
        "ORDER BY id DESC LIMIT 1",
        (note_id, account_id),
    ).fetchone()
    if latest is not None and latest["title"] == note.title and latest["body"] == note.body:
        return None  # unchanged since the last backup — don't pile up duplicates
    cur = conn.execute(
        "INSERT INTO note_revisions (note_id, account_id, title, body, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (note_id, account_id, note.title, note.body, now_iso()),
    )
    conn.execute(
        "DELETE FROM note_revisions WHERE note_id = ? AND account_id = ? AND id NOT IN "
        "(SELECT id FROM note_revisions WHERE note_id = ? AND account_id = ? ORDER BY id DESC LIMIT ?)",
        (note_id, account_id, note_id, account_id, MAX_REVISIONS),
    )
    r = conn.execute(
        "SELECT * FROM note_revisions WHERE id = ?", (int(cur.lastrowid or 0),)
    ).fetchone()
    return _rev_row(r)


def list_revisions(conn: sqlite3.Connection, account_id: int, note_id: int) -> list[Revision]:
    get(conn, account_id, note_id)  # ownership check
    rows = conn.execute(
        "SELECT * FROM note_revisions WHERE note_id = ? AND account_id = ? ORDER BY id DESC",
        (note_id, account_id),
    ).fetchall()
    return [_rev_row(r) for r in rows]


def restore_revision(
    conn: sqlite3.Connection, account_id: int, note_id: int, revision_id: int
) -> Note:
    """Roll the note's body+title back to a saved revision. The current state is
    snapshotted first, so a restore is itself undoable."""
    get(conn, account_id, note_id)  # ownership check
    r = conn.execute(
        "SELECT * FROM note_revisions WHERE id = ? AND note_id = ? AND account_id = ?",
        (revision_id, note_id, account_id),
    ).fetchone()
    if r is None:
        raise NotFound(f"No revision {revision_id} for note {note_id}.")
    snapshot(conn, account_id, note_id)  # back up the about-to-be-overwritten state
    status = USER_TITLE if r["title"] else None
    conn.execute(
        "UPDATE notes SET body = ?, title = ?, title_status = ?, updated_at = ? "
        "WHERE id = ? AND account_id = ?",
        (r["body"], r["title"], status, now_iso(), note_id, account_id),
    )
    return get(conn, account_id, note_id)
