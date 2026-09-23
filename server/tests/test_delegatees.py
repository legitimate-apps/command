from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import delegatees as D
from command.errors import NotFound, ValidationError


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_upsert_create_then_update(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    d, created = D.upsert(
        conn, aid, name="Jordan K", kind="human", lead_time_minutes=1440, metadata={"personality": "type_a"}
    )
    assert created is True
    assert d.slug == "jordan-k"
    assert d.lead_time_minutes == 1440
    assert d.metadata["personality"] == "type_a"

    d2, created2 = D.upsert(conn, aid, slug="jordan-k", name="Jordan King", lead_time_minutes=60)
    assert created2 is False
    assert d2.id == d.id and d2.name == "Jordan King" and d2.lead_time_minutes == 60


def test_upsert_idempotent_by_name(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    d1, c1 = D.upsert(conn, aid, name="Sam", lead_time_minutes=60)
    d2, c2 = D.upsert(conn, aid, name="Sam", lead_time_minutes=120)
    # Same name -> the existing delegatee is updated in place, NOT duplicated as "sam-2".
    assert c1 is True and c2 is False
    assert d1.id == d2.id and d2.slug == "sam" and d2.lead_time_minutes == 120
    # A genuinely separate person who shares a name needs an explicit distinct slug.
    d3, c3 = D.upsert(conn, aid, name="Sam", slug="sam-b")
    assert c3 is True and d3.slug == "sam-b" and d3.id != d1.id


def test_get_by_id_and_slug(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    d, _ = D.upsert(conn, aid, name="Casey")
    assert D.get(conn, aid, slug="casey").id == d.id
    assert D.get(conn, aid, delegatee_id=d.id).slug == "casey"
    with pytest.raises(NotFound):
        D.get(conn, aid, slug="nope")
    with pytest.raises(ValidationError):
        D.get(conn, aid)


def test_exists_and_search(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    D.upsert(conn, aid, name="Robin Cooper")
    D.upsert(conn, aid, name="Bo Cooper")
    D.upsert(conn, aid, name="Zed")
    assert D.exists(conn, aid, "robin-cooper") is True
    assert D.exists(conn, aid, "ghost") is False
    assert {d.name for d in D.search(conn, aid, "cooper")} == {"Robin Cooper", "Bo Cooper"}


def test_kind_validation_and_ai_model(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError):
        D.upsert(conn, aid, name="X", kind="robot")
    d, _ = D.upsert(conn, aid, name="Opus", kind="ai_model", metadata={"model_id": "claude-opus-5"})
    assert d.kind == "ai_model"
    assert d.metadata["model_id"] == "claude-opus-5"


def test_remove(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    D.upsert(conn, aid, name="Temp")
    D.remove(conn, aid, slug="temp")
    with pytest.raises(NotFound):
        D.get(conn, aid, slug="temp")
    with pytest.raises(NotFound):
        D.remove(conn, aid, slug="temp")


def test_account_isolation(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "aaa")
    b = _acct(conn, "bbb")
    D.upsert(conn, a, name="Mine")
    assert D.list_(conn, b)[0] == []


def test_cannot_delete_self_actor(conn: sqlite3.Connection) -> None:
    """The 'Me' self-actor is a per-account singleton; deleting it would null actor_id
    on the account's own activity history, so remove() must refuse it (C5)."""
    from command.errors import Conflict

    aid = _acct(conn)
    me = D.ensure_self(conn, aid)
    assert me.is_self
    with pytest.raises(Conflict):
        D.remove(conn, aid, delegatee_id=me.id)
    assert D.get_self(conn, aid) is not None  # still there
