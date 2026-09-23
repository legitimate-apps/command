"""SQLite connection + migrations.

WAL mode, foreign keys on, a generous busy-timeout so the rare concurrent write
waits instead of erroring (this is a low-traffic personal server). A connection
is opened per request / per MCP tool call and used within one thread; that keeps
`core/` functions plain and synchronous (the async MCP path offloads them to a
worker thread).
"""

from __future__ import annotations

import sqlite3
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from .core import clock

MIGRATIONS_DIR = Path(__file__).parent / "migrations"


def now_iso() -> str:
    """Current UTC time as ISO-8601 — the canonical timestamp format in this DB."""
    return clock.now().isoformat()


class CommandConnection(sqlite3.Connection):
    """A connection that can defer side effects until its transaction COMMITS.

    Deleting a row and its file on disk are two different stores. Unlinking the file inline
    meant a transaction that later rolled back (a failed request, a raised error after the
    delete) restored the row but not the bytes — an attachment that lists fine and 404s on
    download. `after_commit` queues the unlink; `commit()` runs the queue, `rollback()`
    discards it.
    """

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._after_commit: list[Callable[[], None]] = []

    def commit(self) -> None:
        super().commit()
        pending, self._after_commit = self._after_commit, []
        for fn in pending:
            fn()

    def rollback(self) -> None:
        super().rollback()
        self._after_commit = []


def after_commit(conn: sqlite3.Connection, fn: Callable[[], None]) -> None:
    """Run `fn` once `conn`'s current transaction commits (dropped on rollback). A plain
    sqlite3 connection (not from `connect`) has no queue, so `fn` runs immediately — the old
    behaviour, and the only safe choice when nothing will ever flush a queue."""
    if isinstance(conn, CommandConnection):
        conn._after_commit.append(fn)
    else:
        fn()


def connect(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, check_same_thread=False, factory=CommandConnection)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


@contextmanager
def connection(db_path: str) -> Iterator[sqlite3.Connection]:
    """Open a connection, commit on success, roll back on error, always close."""
    conn = connect(db_path)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db(db_path: str) -> None:
    """Apply any migration files not yet recorded in `schema_migrations` (idempotent)."""
    p = Path(db_path)
    if p.parent and not p.parent.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
    conn = connect(db_path)
    try:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations "
            "(version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"
        )
        conn.commit()
        applied = {row[0] for row in conn.execute("SELECT version FROM schema_migrations")}
        for sql_file in sorted(MIGRATIONS_DIR.glob("*.sql")):
            version = sql_file.stem
            if version in applied:
                continue
            conn.executescript(sql_file.read_text())
            conn.execute(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                (version, now_iso()),
            )
            conn.commit()
    finally:
        conn.close()
