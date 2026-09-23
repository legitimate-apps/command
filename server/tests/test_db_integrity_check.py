"""The integrity checker must be able to FAIL.

It passed against production on its first run, which is exactly the situation where a checker
that silently matches nothing is indistinguishable from a healthy database. Every check below is
fed real corruption and must report it.

The checker lives in `scripts/` (it is an operational tool, run against a live box), so it is
imported by path rather than as a package module.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sqlite3
import sys

import pytest

from command.core import accounts, assignments, notes
from command.db import connect, init_db

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "db_integrity_check.py"


def _checker():
    spec = importlib.util.spec_from_file_location("db_integrity_check", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["db_integrity_check"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def db(tmp_path) -> sqlite3.Connection:
    path = str(tmp_path / "check.db")
    init_db(path)
    conn = connect(path)
    acct = accounts.register(conn, "checked", "password1")
    notes.create(conn, acct.id, "a note")
    assignments.create(conn, acct.id, title="a task")
    conn.commit()
    return conn


def test_a_healthy_database_reports_nothing(db: sqlite3.Connection) -> None:
    mod = _checker()
    for _name, check in mod.CHECKS:
        if check is mod.check_attachment_files:
            continue  # needs the configured storage root; covered separately below
        assert check(db) == [], f"{check.__name__} fired on a healthy database"


def test_orphaned_rows_are_caught(db: sqlite3.Connection) -> None:
    """The real production finding: rows whose account is gone."""
    mod = _checker()
    db.execute("PRAGMA foreign_keys=OFF")
    db.execute("DELETE FROM accounts")
    db.commit()
    problems = mod.check_orphans(db)
    assert problems, "orphaned rows must be reported"
    assert any("notes" in detail for _kind, detail in problems)


def test_sqlite_level_violations_are_caught(db: sqlite3.Connection) -> None:
    mod = _checker()
    db.execute("PRAGMA foreign_keys=OFF")
    db.execute("DELETE FROM accounts")
    db.commit()
    assert any(kind == "foreign_key_check" for kind, _ in mod.check_sqlite_level(db))


def test_a_dangling_reference_is_caught(db: sqlite3.Connection) -> None:
    """Point an assignment at a delegatee id that does not exist.

    Deleting a real delegatee does NOT produce this state — the foreign key resolves it — which
    is the point: these references only dangle when something bypassed the database's own rules,
    and that is precisely what `foreign_key_check` alone won't tell you about non-FK columns.
    Note `PRAGMA foreign_keys` is a no-op inside a transaction, hence the commit first.
    """
    mod = _checker()
    db.commit()
    db.execute("PRAGMA foreign_keys=OFF")
    db.execute("UPDATE assignments SET assignee_id = 999999")
    db.commit()
    problems = mod.check_dangling_references(db)
    assert any("assignee" in detail for _kind, detail in problems), problems


def test_domain_invariant_breaches_are_caught(db: sqlite3.Connection) -> None:
    """Each of these means some write path skipped its own validation."""
    mod = _checker()
    db.execute("UPDATE assignments SET status = 'banana'")
    db.commit()
    assert any("status outside" in detail for _kind, detail in mod.check_domain_invariants(db))

    db.execute("UPDATE assignments SET status = 'todo', schedule_kind = 'routine', rrule = NULL")
    db.commit()
    assert any("no rrule" in detail for _kind, detail in mod.check_domain_invariants(db))


def test_a_negative_credit_balance_is_caught(db: sqlite3.Connection) -> None:
    """This one is money — a negative balance means a debit skipped its guard."""
    mod = _checker()
    acct = db.execute("SELECT id FROM accounts LIMIT 1").fetchone()["id"]
    db.execute(
        "INSERT INTO credit_ledger (account_id, delta, reason, ref, created_at) "
        "VALUES (?, -100, 'usage', NULL, '2026-08-05T00:00:00+00:00')",
        (acct,),
    )
    db.commit()
    assert any("negative credit" in detail for _kind, detail in mod.check_domain_invariants(db))
