from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import activities as ACT
from command.core import assignments as A
from command.core import delegatees as D
from command.core import goals as goals_core
from command.errors import NotFound, ValidationError
from command.mcp import permissions as P


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


# ---------- the "Me" self actor ----------


def test_register_provisions_hidden_self(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    me = D.get_self(conn, aid)
    assert me is not None and me.is_self is True and me.slug == "me" and me.name == "Me"
    # Hidden from the delegate-to-others roster, visible when explicitly included.
    assert D.list_(conn, aid)[0] == []
    assert [d.slug for d in D.list_(conn, aid, include_self=True)[0]] == ["me"]


def test_ensure_self_is_idempotent(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    first = D.ensure_self(conn, aid)
    second = D.ensure_self(conn, aid)
    assert first.id == second.id
    assert conn.execute("SELECT COUNT(*) FROM delegatees WHERE is_self = 1").fetchone()[0] == 1


def test_backfill_self_covers_pre_existing_accounts(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    conn.execute("DELETE FROM delegatees WHERE is_self = 1")  # simulate a pre-migration account
    assert D.get_self(conn, aid) is None
    assert D.backfill_self(conn) == 1
    assert D.get_self(conn, aid) is not None
    assert D.backfill_self(conn) == 0  # idempotent second pass


# ---------- logging facts ----------


def test_log_defaults_actor_to_self(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = ACT.create(conn, aid, title="Tidied the kitchen")
    assert a.actor_slug == "me" and a.actor_name == "Me"
    assert a.source == "manual" and a.title == "Tidied the kitchen"


def test_log_with_actor_and_fields(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    D.upsert(conn, aid, name="Jordan")
    a = ACT.create(
        conn,
        aid,
        title="Took out trash",
        actor_slug="jordan",
        category="chores",
        duration_minutes=10,
        occurred_at="2026-06-10T08:00:00+00:00",
    )
    assert a.actor_slug == "jordan" and a.category == "chores" and a.duration_minutes == 10
    assert a.occurred_at == "2026-06-10T08:00:00+00:00"


def test_log_validates(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError):
        ACT.create(conn, aid, title="   ")  # blank
    with pytest.raises(ValidationError):
        ACT.create(conn, aid, title="x", occurred_at="not-a-date")
    with pytest.raises(ValidationError):
        ACT.create(conn, aid, title="x", duration_minutes=-5)
    with pytest.raises(NotFound):
        ACT.create(conn, aid, title="x", actor_slug="ghost")


def test_search_orders_by_occurred_at_not_insertion(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    # Insert a back-dated entry LAST; it must still sort below the recent one.
    ACT.create(conn, aid, title="recent", occurred_at="2026-06-15T09:00:00+00:00")
    ACT.create(conn, aid, title="older-but-logged-later", occurred_at="2026-06-01T09:00:00+00:00")
    items, _ = ACT.search(conn, aid)
    assert [i.title for i in items] == ["recent", "older-but-logged-later"]


def test_search_filters_window_and_actor(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    D.upsert(conn, aid, name="Sam")
    ACT.create(conn, aid, title="me-thing", occurred_at="2026-06-10T09:00:00+00:00")
    ACT.create(conn, aid, title="sam-thing", actor_slug="sam", occurred_at="2026-06-20T09:00:00+00:00")
    win, _ = ACT.search(conn, aid, start="2026-06-15T00:00:00+00:00", end="2026-06-30T00:00:00+00:00")
    assert [i.title for i in win] == ["sam-thing"]
    by_actor, _ = ACT.search(conn, aid, actor_slug="sam")
    assert [i.title for i in by_actor] == ["sam-thing"]


def test_search_keyset_pagination(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    for i in range(5):
        ACT.create(conn, aid, title=f"a{i}", occurred_at=f"2026-06-1{i}T09:00:00+00:00")
    page1, cur = ACT.search(conn, aid, limit=2)
    assert len(page1) == 2 and cur is not None
    page2, cur2 = ACT.search(conn, aid, limit=2, cursor=cur)
    assert len(page2) == 2 and cur2 is not None
    seen = {i.id for i in page1} | {i.id for i in page2}
    assert len(seen) == 4  # no overlap across pages


def test_update_and_delete(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    D.upsert(conn, aid, name="Pat")
    a = ACT.create(conn, aid, title="thing", category="misc")
    upd = ACT.update(conn, aid, a.id, title="renamed", actor_slug="pat", category="errands")
    assert upd.title == "renamed" and upd.actor_slug == "pat" and upd.category == "errands"
    ACT.delete(conn, aid, a.id)
    with pytest.raises(NotFound):
        ACT.get(conn, aid, a.id)


def test_account_isolation(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "aaa")
    b = _acct(conn, "bbb")
    ACT.create(conn, a, title="mine")
    assert ACT.search(conn, b)[0] == []
    gb = goals_core.create(conn, b, title="theirs")
    with pytest.raises(NotFound):
        ACT.create(conn, a, title="x", goal_id=gb.id)  # can't link another account's goal


# ---------- audit summary ----------


def test_summary_groups_and_totals(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    D.upsert(conn, aid, name="Jordan")
    ACT.create(conn, aid, title="dishes", actor_slug="jordan", category="chores", duration_minutes=15)
    ACT.create(conn, aid, title="trash", actor_slug="jordan", category="chores", duration_minutes=5)
    ACT.create(conn, aid, title="email", category="work", duration_minutes=30)  # actor = me
    buckets = ACT.summary(conn, aid)
    # Busiest bucket first: Jordan/chores (count 2, 20 min).
    top = buckets[0]
    assert top.actor_slug == "jordan" and top.category == "chores"
    assert top.count == 2 and top.total_minutes == 20
    # Group by category only collapses actors.
    by_cat = ACT.summary(conn, aid, group_by=("category",))
    chores = next(b for b in by_cat if b.category == "chores")
    assert chores.count == 2 and chores.actor_slug is None


# ---------- completing a plan logs a fact ----------


def test_set_status_done_auto_logs_once(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    d, _ = D.upsert(conn, aid, name="Jordan")
    a = A.create(conn, aid, title="Mow lawn", assignee_id=d.id)
    A.set_status(conn, aid, a.id, "done")
    logged, _ = ACT.search(conn, aid, assignment_id=a.id)
    assert len(logged) == 1
    fact = logged[0]
    assert fact.source == "assignment_completion" and fact.actor_id == d.id and fact.title == "Mow lawn"
    # Re-completing (todo -> done again) must NOT duplicate the fact.
    A.set_status(conn, aid, a.id, "todo")
    A.set_status(conn, aid, a.id, "done")
    assert len(ACT.search(conn, aid, assignment_id=a.id)[0]) == 1


def test_unassigned_done_attributes_to_self(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="Solo task")
    A.set_status(conn, aid, a.id, "done")
    fact = ACT.search(conn, aid, assignment_id=a.id)[0][0]
    assert fact.actor_slug == "me"


def test_occurrence_done_logs_per_date(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(
        conn,
        aid,
        title="Standup",
        schedule_kind="routine",
        rrule="FREQ=DAILY",
        scheduled_start="2026-06-15T09:00:00+00:00",
    )
    A.set_occurrence_status(conn, aid, a.id, "2026-06-16", "done")
    A.set_occurrence_status(conn, aid, a.id, "2026-06-17", "done")
    A.set_occurrence_status(conn, aid, a.id, "2026-06-16", "done")  # repeat — deduped
    facts, _ = ACT.search(conn, aid, assignment_id=a.id)
    assert {f.occurrence_date for f in facts} == {"2026-06-16", "2026-06-17"}
    assert len(facts) == 2


def test_skipped_status_allowed_and_does_not_log(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="Chore")
    A.set_status(conn, aid, a.id, "skipped")  # "didn't do it" — valid, no fact logged
    assert A.get(conn, aid, a.id).status == "skipped"
    assert ACT.search(conn, aid, assignment_id=a.id)[0] == []


# ---------- settings gating ----------


def test_activities_permission_gate(conn: sqlite3.Connection) -> None:
    from command.core import settings as S

    aid = _acct(conn)
    P.require(conn, aid, "activities", "create")  # default on — no raise
    P.require(conn, aid, "activities", "delete")
    S.set_value(conn, aid, S.MCP_PERMISSIONS_KEY, {"activities": {"delete": False}})
    from command.errors import PermissionDenied

    with pytest.raises(PermissionDenied):
        P.require(conn, aid, "activities", "delete")
