from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import goals, notes
from command.errors import NotFound, ValidationError


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_crud(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    g = goals.create(conn, aid, title="Ship app", description="desc")
    assert g.status == "open"
    g2 = goals.update(conn, aid, g.id, status="in_progress", title="Ship app v2")
    assert g2.status == "in_progress"
    assert g2.title == "Ship app v2"
    goals.delete(conn, aid, g.id)
    with pytest.raises(NotFound):
        goals.get(conn, aid, g.id)


def test_status_validation(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError):
        goals.create(conn, aid, title="x", status="bogus")
    g = goals.create(conn, aid, title="x")
    with pytest.raises(ValidationError):
        goals.update(conn, aid, g.id, status="nope")


def test_link_notes_idempotent_and_owned(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    g = goals.create(conn, aid, title="g")
    n1 = notes.create(conn, aid, "n1")
    n2 = notes.create(conn, aid, "n2")
    assert goals.link_notes(conn, aid, g.id, [n1.id, n2.id], include_hidden=True) == 2
    assert {n.id for n in goals.list_notes(conn, aid, g.id, include_hidden=True)} == {n1.id, n2.id}
    goals.link_notes(conn, aid, g.id, [n1.id], include_hidden=True)  # re-link is idempotent
    assert len(goals.list_notes(conn, aid, g.id, include_hidden=True)) == 2


def test_link_foreign_note_rejected(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "aaa")
    b = _acct(conn, "bbb")
    g = goals.create(conn, a, title="g")
    nb = notes.create(conn, b, "theirs")
    with pytest.raises(NotFound):
        goals.link_notes(conn, a, g.id, [nb.id], include_hidden=True)


def test_list_and_search(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    goals.create(conn, aid, title="alpha goal")
    goals.create(conn, aid, title="beta goal")
    assert len(goals.list_(conn, aid)[0]) == 2
    assert {g.title for g in goals.search(conn, aid, "alpha")} == {"alpha goal"}
