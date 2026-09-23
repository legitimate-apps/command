"""Migration 0020 reaps rows orphaned by a delete that ran without foreign keys on.

OBSERVED on the live database 2026-08-05: `PRAGMA foreign_key_check` reported 4 violations — two
`settings` rows and two `access_tokens` rows pointing at an account that no longer existed. Both
tables declare `ON DELETE CASCADE`, so they can only have survived a deletion on a connection
where `PRAGMA foreign_keys` was OFF (it is set per-connection in `db.py`, so anything touching
the file outside the app bypasses it).

Today's `delete_account` is clean — verified, and asserted below — so this is historical residue.
It was also not dangerous: `account_for_access_token` INNER JOINs `accounts`, so an orphaned
token cannot authenticate, and `accounts.id` is AUTOINCREMENT so a new account can never inherit
a deleted one's id. Corruption, not a hole.
"""

from __future__ import annotations

import pathlib
import sqlite3

from command.core import accounts, notes
from command.db import connect, init_db

MIGRATION = (
    pathlib.Path(__file__).resolve().parents[1]
    / "src" / "command" / "migrations" / "0020_reap_orphaned_account_rows.sql"
)


def _tables_with_account_id(conn: sqlite3.Connection) -> set[str]:
    out = set()
    for row in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ):
        table = row["name"]
        if any(c[1] == "account_id" for c in conn.execute(f"PRAGMA table_info({table})")):
            out.add(table)
    return out


def test_the_migration_covers_every_table_carrying_an_account_id(tmp_path) -> None:
    """The durable half: a table added later must not be silently left out.

    A migration that quietly misses a table looks exactly like one that worked — the orphans it
    should have reaped simply stay, and `foreign_key_check` keeps failing on a surface nobody
    reads. Enumerated from the live schema rather than trusted from the file.
    """
    db = str(tmp_path / "cover.db")
    init_db(db)
    conn = connect(db)
    sql = MIGRATION.read_text()
    missing = sorted(t for t in _tables_with_account_id(conn) if f"FROM {t} " not in sql)
    assert not missing, f"migration 0020 does not reap these account-scoped tables: {missing}"


def test_it_deletes_orphans_and_leaves_live_rows_alone(tmp_path) -> None:
    db = str(tmp_path / "orphans.db")
    init_db(db)
    conn = connect(db)

    keeper = accounts.register(conn, "keeper", "password1")
    doomed = accounts.register(conn, "doomed", "password1")
    accounts.ensure_access_token(conn, doomed.id)
    notes.create(conn, doomed.id, "should not survive its account")
    keeper_note = notes.create(conn, keeper.id, "must survive")
    conn.commit()

    # Reproduce the historical condition: delete the account with FK enforcement OFF, so
    # nothing cascades and the child rows are stranded.
    conn.execute("PRAGMA foreign_keys=OFF")
    conn.execute("DELETE FROM accounts WHERE id = ?", (doomed.id,))
    conn.commit()
    conn.execute("PRAGMA foreign_keys=ON")
    assert conn.execute("PRAGMA foreign_key_check").fetchall(), "precondition: orphans exist"

    conn.executescript(MIGRATION.read_text())
    conn.commit()

    assert conn.execute("PRAGMA foreign_key_check").fetchall() == [], "orphans must be gone"
    assert notes.get(conn, keeper.id, keeper_note.id).body == "must survive"
    assert conn.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 1


def test_it_is_a_no_op_on_a_healthy_database(tmp_path) -> None:
    """Runs on every deployment, so it must not touch a database that was already fine."""
    db = str(tmp_path / "healthy.db")
    init_db(db)
    conn = connect(db)
    acct = accounts.register(conn, "healthy", "password1")
    accounts.ensure_access_token(conn, acct.id)
    notes.create(conn, acct.id, "keep me")
    conn.commit()

    before = {
        t: conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        for t in _tables_with_account_id(conn)
    }
    conn.executescript(MIGRATION.read_text())
    conn.commit()
    after = {
        t: conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        for t in _tables_with_account_id(conn)
    }
    assert before == after


def test_todays_account_delete_leaves_nothing_behind(tmp_path) -> None:
    """The reason this is a one-off cleanup and not a recurring sweep."""
    db = str(tmp_path / "clean.db")
    init_db(db)
    conn = connect(db)
    acct = accounts.register(conn, "modern", "password1")
    accounts.ensure_access_token(conn, acct.id)
    notes.create(conn, acct.id, "note")
    conn.commit()

    accounts.delete_account(conn, acct.id, password="password1")
    conn.commit()
    assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
