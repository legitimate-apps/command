"""Account deletion — required by App Review 5.1.1(v) and promised by our privacy policy.

The interesting part is the FK graph: 15 of the 19 tables referencing `accounts(id)` declare
ON DELETE CASCADE, but `credit_ledger`, `task_items`, `device_tokens`, and `sent_reminders` do
not — and `PRAGMA foreign_keys=ON` means SQLite's default NO ACTION turns a stray row in any of
them into a constraint error instead of a deletion. `test_delete_account_leaves_nothing_behind`
sweeps every account-scoped table so that adding a new one without cascade fails here rather
than in production.
"""

from __future__ import annotations

import sqlite3

import pytest
from fastapi.testclient import TestClient

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import delegatees as D
from command.core import goals as G
from command.core import notes as N
from command.core import push as push_core
from command.core import task_items as items_core
from command.errors import AuthFailed, NotFound


def _populated(conn: sqlite3.Connection, name: str = "owner") -> int:
    """An account with a row in as many child tables as we can reach — including the four that
    do not cascade, which are the ones that would break a naive DELETE."""
    aid = accounts_core.register(conn, name, "password1").id
    note = N.create(conn, aid, body="a thought")
    goal = G.create(conn, aid, title="Ship it", target_date="2026-10-21")
    person, _ = D.upsert(conn, aid, name="Dana", kind="human")
    a = A.create(conn, aid, title="Draft post", goal_id=goal.id,
                 scheduled_start="2026-06-20T09:00:00+00:00")
    A.assign(conn, aid, a.id, assignee_id=person.id)
    items_core.add(conn, aid, parent_type="assignment", parent_id=a.id, text="a checklist item")
    push_core.register(conn, aid, "a" * 64, platform="ios", environment="sandbox")
    accounts_core.get_access_token(conn, aid, words=4)
    assert note and goal
    return aid


def _account_scoped_tables(conn: sqlite3.Connection) -> list[str]:
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    out = []
    for (name,) in [(r[0],) for r in rows]:
        cols = [c[1] for c in conn.execute(f"PRAGMA table_info({name})").fetchall()]
        if "account_id" in cols:
            out.append(name)
    return out


def test_delete_account_leaves_nothing_behind(conn: sqlite3.Connection) -> None:
    aid = _populated(conn)
    tables = _account_scoped_tables(conn)
    assert len(tables) > 5, f"expected many account-scoped tables, found {tables}"

    accounts_core.delete_account(conn, aid, password="password1")

    assert conn.execute("SELECT count(*) FROM accounts WHERE id = ?", (aid,)).fetchone()[0] == 0
    leftovers = {
        t: conn.execute(f"SELECT count(*) FROM {t} WHERE account_id = ?", (aid,)).fetchone()[0]
        for t in tables
    }
    assert not any(leftovers.values()), "rows survived deletion: " \
        "{k: v for k, v in leftovers.items() if v} — give the table ON DELETE CASCADE " \
        "or add it to accounts_core._NON_CASCADING"


def test_delete_requires_the_password(conn: sqlite3.Connection) -> None:
    """A stolen session must not be enough to destroy someone's data."""
    aid = _populated(conn)
    with pytest.raises(AuthFailed):
        accounts_core.delete_account(conn, aid, password="not-the-password")
    assert conn.execute("SELECT count(*) FROM accounts WHERE id = ?", (aid,)).fetchone()[0] == 1


def test_delete_does_not_touch_other_accounts(conn: sqlite3.Connection) -> None:
    mine = _populated(conn, "mine")
    theirs = _populated(conn, "theirs")
    accounts_core.delete_account(conn, mine, password="password1")
    assert conn.execute("SELECT count(*) FROM accounts WHERE id = ?", (theirs,)).fetchone()[0] == 1
    assert conn.execute("SELECT count(*) FROM notes WHERE account_id = ?", (theirs,)).fetchone()[0] == 1


def test_delete_unknown_account(conn: sqlite3.Connection) -> None:
    with pytest.raises(NotFound):
        accounts_core.delete_account(conn, 9999, password="password1")


# --- over the wire -----------------------------------------------------------


def test_rest_delete_account_flow(client: TestClient) -> None:
    assert client.post("/api/auth/register",
                       json={"username": "owner", "password": "password1"}).status_code == 200
    assert client.post("/api/notes", json={"body": "buy milk", "source": "typed"}).status_code == 201

    # Wrong password is rejected...
    assert client.post("/api/account/delete", json={"password": "wrong"}).status_code in (401, 403)
    assert client.get("/api/auth/me").status_code == 200, "a failed delete must not sign me out"

    # ...the right one deletes and ends the session.
    r = client.post("/api/account/delete", json={"password": "password1"})
    assert r.status_code == 204, r.text
    assert client.get("/api/auth/me").status_code == 401

    # And the username is free again — the row really is gone, not flagged.
    assert client.post("/api/auth/register",
                       json={"username": "owner", "password": "password2"}).status_code == 200
