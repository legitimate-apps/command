"""Nullable fields must be clearable — UNSET = unchanged, None = clear.

Before this, every `update()` skipped `None` fields ("None = leave unchanged"), which
made a nullable column impossible to turn off: an assignment could be linked to a goal
but never unlinked, scheduled but never unscheduled, given a lead time but never reset
to inherit the assignee's. These lock in both halves of the contract — clearing works,
and an omitted field still doesn't get wiped.
"""

from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import delegatees as D
from command.core import goals as G
from command.errors import NotFound


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


# --- assignments: assignee ---------------------------------------------------


def test_assignee_can_be_cleared(conn: sqlite3.Connection) -> None:
    """Nothing could unassign before: assign() requires a delegatee and update() had no
    assignee_id at all, so the app's "Clear assignee" had no endpoint to call."""
    aid = _acct(conn)
    person, _ = D.upsert(conn, aid, name="Dana", kind="human")
    a = A.create(conn, aid, title="Email Dana")
    A.assign(conn, aid, a.id, assignee_id=person.id)
    assert A.get(conn, aid, a.id).assignee_id == person.id

    assert A.update(conn, aid, a.id, assignee_id=None).assignee_id is None


def test_assignee_survives_an_unrelated_update(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    person, _ = D.upsert(conn, aid, name="Dana", kind="human")
    a = A.create(conn, aid, title="Email Dana")
    A.assign(conn, aid, a.id, assignee_id=person.id)
    assert A.update(conn, aid, a.id, status="in_progress").assignee_id == person.id


def test_assigning_another_accounts_delegatee_is_rejected(conn: sqlite3.Connection) -> None:
    mine = _acct(conn, "mine")
    theirs = _acct(conn, "theirs")
    stranger, _ = D.upsert(conn, theirs, name="Stranger", kind="human")
    a = A.create(conn, mine, title="Draft post")
    with pytest.raises(NotFound):
        A.update(conn, mine, a.id, assignee_id=stranger.id)


# --- assignments: goal_id ----------------------------------------------------


def test_goal_link_can_be_cleared(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    goal = G.create(conn, aid, title="Ship it")
    a = A.create(conn, aid, title="Draft post", goal_id=goal.id)
    assert a.goal_id == goal.id

    cleared = A.update(conn, aid, a.id, goal_id=None)
    assert cleared.goal_id is None, "explicit None must unlink the assignment from its goal"


def test_goal_link_survives_an_unrelated_update(conn: sqlite3.Connection) -> None:
    """The regression that matters: a one-field edit must not wipe the rest of the row."""
    aid = _acct(conn)
    goal = G.create(conn, aid, title="Ship it")
    a = A.create(conn, aid, title="Draft post", goal_id=goal.id,
                 scheduled_start="2026-06-20T09:00:00+00:00", lead_time_minutes=120)

    same = A.update(conn, aid, a.id, status="in_progress")
    assert same.goal_id == goal.id
    assert same.scheduled_start == "2026-06-20T09:00:00+00:00"
    assert same.lead_time_minutes == 120
    assert same.status == "in_progress"


def test_goal_link_can_be_moved(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    one = G.create(conn, aid, title="Goal one")
    two = G.create(conn, aid, title="Goal two")
    a = A.create(conn, aid, title="Draft post", goal_id=one.id)
    assert A.update(conn, aid, a.id, goal_id=two.id).goal_id == two.id


def test_linking_to_another_accounts_goal_is_rejected(conn: sqlite3.Connection) -> None:
    mine = _acct(conn, "mine")
    theirs = _acct(conn, "theirs")
    their_goal = G.create(conn, theirs, title="Not yours")
    a = A.create(conn, mine, title="Draft post")
    with pytest.raises(NotFound):
        A.update(conn, mine, a.id, goal_id=their_goal.id)


# --- assignments: lead time + schedule ---------------------------------------


def test_lead_time_can_be_cleared_back_to_inherit(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="Call plumber", lead_time_minutes=1440)
    assert A.update(conn, aid, a.id, lead_time_minutes=None).lead_time_minutes is None


def test_lead_time_zero_is_not_confused_with_clearing(conn: sqlite3.Connection) -> None:
    """0 ('no notice') is a real value and must round-trip, not be treated as absent."""
    aid = _acct(conn)
    a = A.create(conn, aid, title="Call plumber", lead_time_minutes=1440)
    assert A.update(conn, aid, a.id, lead_time_minutes=0).lead_time_minutes == 0


def test_sporadic_assignment_can_be_unscheduled(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="Call plumber", scheduled_start="2026-06-20T09:00:00+00:00")
    assert A.update(conn, aid, a.id, scheduled_start=None).scheduled_start is None


# --- goals: target_date ------------------------------------------------------


def test_goal_target_date_can_be_cleared(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    g = G.create(conn, aid, title="Ship it", target_date="2026-10-21")
    assert G.update(conn, aid, g.id, target_date=None).target_date is None


def test_goal_target_date_survives_an_unrelated_update(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    g = G.create(conn, aid, title="Ship it", target_date="2026-10-21", description="why")
    same = G.update(conn, aid, g.id, status="in_progress")
    assert same.target_date == "2026-10-21"
    assert same.description == "why"
