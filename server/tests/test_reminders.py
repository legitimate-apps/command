from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import reminders as R


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_lead_time_drives_remind_at(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    # An assignment 5 days out with a 1-day (1440 min) lead time.
    A.create(conn, aid, title="Submit report",
             scheduled_start="2026-06-28T09:00:00+00:00", lead_time_minutes=1440)
    now = datetime(2026, 6, 23, 12, 0, 0, tzinfo=UTC)
    rems = R.upcoming_reminders(conn, aid, now=now, within_days=14)
    assert len(rems) == 1
    r = rems[0]
    assert r.title == "Submit report"
    assert r.occurs_at.startswith("2026-06-28T09:00:00")
    assert r.remind_at.startswith("2026-06-27T09:00:00")   # 1 day before
    assert r.lead_time_minutes == 1440
    assert r.due is False                                    # remind_at is in the future


def test_assignment_without_lead_time_reminds_at_occurrence(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="No lead", scheduled_start="2026-06-28T09:00:00+00:00")
    now = datetime(2026, 6, 23, 12, 0, 0, tzinfo=UTC)
    reminders = R.upcoming_reminders(conn, aid, now=now, within_days=14)
    assert len(reminders) == 1
    assert reminders[0].lead_time_minutes == 0
    assert reminders[0].remind_at == reminders[0].occurs_at


def test_done_or_cancelled_occurrence_does_not_remind(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    assignment = A.create(
        conn,
        aid,
        title="Daily dose",
        schedule_kind="routine",
        rrule="FREQ=DAILY;COUNT=3",
        scheduled_start="2026-06-23T09:00:00+00:00",
    )
    A.set_occurrence_status(conn, aid, assignment.id, "2026-06-24", "done")
    A.set_occurrence_status(conn, aid, assignment.id, "2026-06-25", "cancelled")
    reminders = R.upcoming_reminders(
        conn, aid, now=datetime(2026, 6, 23, tzinfo=UTC), within_days=3
    )
    assert [r.occurs_at[:10] for r in reminders] == ["2026-06-23"]


def test_window_excludes_far_future(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Soon", scheduled_start="2026-06-25T09:00:00+00:00", lead_time_minutes=60)
    A.create(conn, aid, title="Far", scheduled_start="2026-09-01T09:00:00+00:00", lead_time_minutes=60)
    now = datetime(2026, 6, 23, 12, 0, 0, tzinfo=UTC)
    rems = R.upcoming_reminders(conn, aid, now=now, within_days=7)
    assert [r.title for r in rems] == ["Soon"]


def test_due_flag_when_remind_at_passed(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    # Occurs in 30 min with a 60-min lead → remind_at already passed → due.
    A.create(conn, aid, title="Imminent",
             scheduled_start="2026-06-23T12:30:00+00:00", lead_time_minutes=60)
    now = datetime(2026, 6, 23, 12, 0, 0, tzinfo=UTC)
    rems = R.upcoming_reminders(conn, aid, now=now, within_days=1)
    assert len(rems) == 1
    assert rems[0].due is True


def test_routine_rrule_reminders(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Standup", schedule_kind="routine", rrule="FREQ=DAILY",
             scheduled_start="2026-06-23T09:00:00+00:00", lead_time_minutes=30)
    now = datetime(2026, 6, 23, 0, 0, 0, tzinfo=UTC)
    rems = R.upcoming_reminders(conn, aid, now=now, within_days=3)
    # Daily standups over 3 days → at least 3 reminders, each 30 min before 09:00.
    assert len(rems) >= 3
    assert all(r.title == "Standup" and r.lead_time_minutes == 30 for r in rems)
    assert rems[0].remind_at.startswith("2026-06-23T08:30:00")
