from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import activities, assignments, goals, task_items
from command.errors import NotFound, ValidationError


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def _assignment(conn: sqlite3.Connection, aid: int) -> int:
    # Parents are validated on add, so every item needs a real one to hang off.
    return assignments.create(conn, aid, title="parent").id


def test_add_lists_and_positions(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    p = _assignment(conn, aid)
    assert task_items.list_items(conn, aid, "assignment", p) == []
    a = task_items.add(conn, aid, "assignment", p, text="buy cups")
    b = task_items.add(conn, aid, "assignment", p, text="book venue")
    assert a.position == 0 and b.position == 1
    items = task_items.list_items(conn, aid, "assignment", p)
    assert [i.text for i in items] == ["buy cups", "book venue"]
    assert all(i.source == "user" and not i.done for i in items)


def test_update_text_and_done(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    g = goals.create(conn, aid, title="g").id
    it = task_items.add(conn, aid, "goal", g, text="draft outline")
    done = task_items.update(conn, aid, it.id, done=True)
    assert done.done is True
    renamed = task_items.update(conn, aid, it.id, text="draft full outline")
    assert renamed.text == "draft full outline" and renamed.done is True


def test_delete(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    act = activities.create(conn, aid, title="called").id
    it = task_items.add(conn, aid, "activity", act, text="follow up")
    task_items.delete(conn, aid, it.id)
    assert task_items.list_items(conn, aid, "activity", act) == []
    with pytest.raises(NotFound):
        task_items.delete(conn, aid, it.id)


def test_reorder(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    p = _assignment(conn, aid)
    a = task_items.add(conn, aid, "assignment", p, text="a")
    b = task_items.add(conn, aid, "assignment", p, text="b")
    c = task_items.add(conn, aid, "assignment", p, text="c")
    out = task_items.reorder(conn, aid, "assignment", p, [c.id, a.id, b.id])
    assert [i.text for i in out] == ["c", "a", "b"]
    assert [i.position for i in out] == [0, 1, 2]


def test_scoped_per_account_and_parent(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "owner_a")
    b = _acct(conn, "owner_b")
    p1, p2 = _assignment(conn, a), _assignment(conn, a)
    task_items.add(conn, a, "assignment", p1, text="mine")
    with pytest.raises(NotFound):                                     # other account: no such parent
        task_items.list_items(conn, b, "assignment", p1)
    assert task_items.list_items(conn, a, "assignment", p2) == []     # other parent sees nothing
    # An item can't be touched cross-account.
    it = task_items.add(conn, a, "assignment", p1, text="secret")
    with pytest.raises(NotFound):
        task_items.update(conn, b, it.id, done=True)
    # ...nor attached to another account's parent.
    with pytest.raises(NotFound):
        task_items.add(conn, b, "assignment", p1, text="intrude")


def test_validation(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    p = _assignment(conn, aid)
    with pytest.raises(ValidationError):
        task_items.add(conn, aid, "assignment", p, text="   ")
    with pytest.raises(ValidationError):
        task_items.add(conn, aid, "bogus", p, text="x")
