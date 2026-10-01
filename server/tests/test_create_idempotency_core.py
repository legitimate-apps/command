"""Core guarantees independent of auth's incidental SQLite writer lock."""
from __future__ import annotations

import sqlite3
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier

import pytest

from command.core import accounts, activities, assignments, notes
from command.db import connection, init_db


def _create(conn, account_id, entity, key, text="capture"):
    if entity == "notes":
        return notes.create(conn, account_id, text, idempotency_key=key)
    if entity == "activities":
        return activities.create(conn, account_id, title=text, idempotency_key=key)
    return assignments.create(conn, account_id, title=text, idempotency_key=key)


@pytest.mark.parametrize("entity", ["notes", "activities", "assignments"])
def test_core_concurrent_keyed_create_uses_one_row(tmp_path: Path, entity: str) -> None:
    db = str(tmp_path / "race.db")
    init_db(db)
    with connection(db) as conn:
        account = accounts.register(conn, "owner", "password1")
    ready = Barrier(2)

    def create(index: int) -> int:
        with connection(db) as conn:
            ready.wait(timeout=10)
            return _create(conn, account.id, entity, "parallel", f"capture {index}").id

    with ThreadPoolExecutor(max_workers=2) as pool:
        ids = list(pool.map(create, range(2)))
    assert ids[0] == ids[1]
    with connection(db) as conn:
        assert conn.execute(f"SELECT COUNT(*) FROM {entity}").fetchone()[0] == 1


@pytest.mark.parametrize("entity", ["notes", "activities", "assignments"])
def test_core_key_persists_on_reopen_and_is_account_scoped(tmp_path: Path, entity: str) -> None:
    db = str(tmp_path / "persistent.db")
    init_db(db)
    with connection(db) as conn:
        first_account = accounts.register(conn, "one", "password1")
        second_account = accounts.register(conn, "two", "password1")
        first = _create(conn, first_account.id, entity, "shared", "first")
    # Re-run startup migrations and reopen connections: no process-local dedupe.
    init_db(db)
    with connection(db) as conn:
        replay = _create(conn, first_account.id, entity, "shared", "")
        second = _create(conn, second_account.id, entity, "shared", "second")
        assert replay.id == first.id
        assert second.id != first.id
        assert conn.execute(f"SELECT COUNT(*) FROM {entity}").fetchone()[0] == 2


@pytest.mark.parametrize("entity", ["notes", "activities", "assignments"])
def test_core_unique_index_enforces_keys_but_allows_nulls(conn, entity: str) -> None:
    account = accounts.register(conn, "owner", "password1")
    first = _create(conn, account.id, entity, "unique")
    second = _create(conn, account.id, entity, None)
    _create(conn, account.id, entity, None)
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(f"UPDATE {entity} SET idempotency_key = ? WHERE id = ?", ("unique", second.id))
    assert first.id != second.id


def test_rolled_back_create_does_not_reserve_key(tmp_path: Path) -> None:
    db = str(tmp_path / "rollback.db")
    init_db(db)
    with connection(db) as conn:
        account = accounts.register(conn, "owner", "password1")
    def failed_create() -> None:
        with connection(db) as conn:
            notes.create(conn, account.id, "rolled back", idempotency_key="retry")
            raise RuntimeError("lost before commit")

    with pytest.raises(RuntimeError):
        failed_create()
    with connection(db) as conn:
        note = notes.create(conn, account.id, "committed", idempotency_key="retry")
        assert note.body == "committed"
        assert conn.execute("SELECT COUNT(*) FROM notes").fetchone()[0] == 1
