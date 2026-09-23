from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import delegatees as D
from command.core import goals
from command.errors import NotFound, ValidationError

NY = ZoneInfo("America/New_York")


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_create_sporadic(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="Call plumber", scheduled_start="2026-06-20T09:00:00+00:00")
    assert a.schedule_kind == "sporadic"
    assert a.status == "todo"


def test_negative_lead_time_is_rejected_at_core_write_boundary(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError, match="cannot be negative"):
        A.create(conn, aid, title="Invalid reminder", lead_time_minutes=-1)

    assignment = A.create(conn, aid, title="Valid reminder", lead_time_minutes=0)
    with pytest.raises(ValidationError, match="cannot be negative"):
        A.update(conn, aid, assignment.id, lead_time_minutes=-1)
    assert A.get(conn, aid, assignment.id).lead_time_minutes == 0


def test_routine_validation(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError):
        A.create(conn, aid, title="x", schedule_kind="routine")  # no rrule
    with pytest.raises(ValidationError):
        A.create(conn, aid, title="x", schedule_kind="routine", rrule="FREQ=WEEKLY")  # no start
    with pytest.raises(ValidationError):
        A.create(
            conn,
            aid,
            title="x",
            schedule_kind="routine",
            rrule="NONSENSE",
            scheduled_start="2026-06-16T08:00:00+00:00",
        )


def test_calendar_expands_routine(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    # 2026-06-15 is a Monday. Weekly Mon/Wed/Fri → Mon15, Wed17, Fri19.
    A.create(
        conn,
        aid,
        title="Standup",
        schedule_kind="routine",
        rrule="FREQ=WEEKLY;BYDAY=MO,WE,FR",
        scheduled_start="2026-06-15T09:00:00+00:00",
    )
    occ = A.calendar(conn, aid, "2026-06-15T00:00:00+00:00", "2026-06-21T23:59:59+00:00")
    assert [o.occurs_at[:10] for o in occ] == ["2026-06-15", "2026-06-17", "2026-06-19"]


def test_routine_preserves_wall_clock_across_dst(conn: sqlite3.Connection) -> None:
    """B5: a timezone-anchored 'Daily 9 AM' stays 9 AM local across a DST transition (US spring-
    forward is 2026-03-08). Without the anchor it would drift to 10 AM after the change."""
    aid = _acct(conn)
    # 2026-03-01 09:00 America/New_York (EST, UTC-5) == 14:00Z.
    A.create(
        conn, aid, title="Standup", schedule_kind="routine", rrule="FREQ=DAILY",
        scheduled_start="2026-03-01T09:00:00-05:00", timezone="America/New_York",
    )
    occ = A.calendar(conn, aid, "2026-03-01T00:00:00+00:00", "2026-03-15T23:59:59+00:00")
    # Every occurrence is 9 AM LOCAL, though the UTC offset flips -05:00 → -04:00 across 03-08.
    local_hours = {datetime.fromisoformat(o.occurs_at).astimezone(NY).hour for o in occ}
    assert local_hours == {9}
    by_day = {o.occurs_at[:10]: datetime.fromisoformat(o.occurs_at).astimezone(UTC).hour for o in occ}
    assert by_day["2026-03-01"] == 14  # 9 AM EST
    assert by_day["2026-03-10"] == 13  # 9 AM EDT (post-DST) — UTC hour shifted, wall-clock kept


def test_routine_without_timezone_keeps_legacy_utc_behavior(conn: sqlite3.Connection) -> None:
    """Legacy rows (timezone NULL) still expand on a fixed UTC clock-time — unchanged, so existing
    data and per-occurrence-status keys don't shift."""
    aid = _acct(conn)
    A.create(
        conn, aid, title="Standup", schedule_kind="routine", rrule="FREQ=DAILY",
        scheduled_start="2026-03-01T14:00:00+00:00",  # 14:00Z, no timezone
    )
    occ = A.calendar(conn, aid, "2026-03-01T00:00:00+00:00", "2026-03-15T23:59:59+00:00")
    utc_hours = {datetime.fromisoformat(o.occurs_at).astimezone(UTC).hour for o in occ}
    assert utc_hours == {14}  # fixed UTC clock-time, the old (drifting) behavior — deliberately kept


def test_routine_monthly_clamps_short_months(conn: sqlite3.Connection) -> None:
    """B16: 'Monthly on the 31st' fires on the last day of short months instead of skipping them."""
    aid = _acct(conn)
    A.create(
        conn, aid, title="Rent", schedule_kind="routine", rrule="FREQ=MONTHLY",
        scheduled_start="2026-01-31T12:00:00+00:00",
    )
    occ = A.calendar(conn, aid, "2026-01-01T00:00:00+00:00", "2026-06-30T23:59:59+00:00")
    assert [o.occurs_at[:10] for o in occ] == [
        "2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31", "2026-06-30",
    ]


def test_routine_yearly_clamps_leap_day(conn: sqlite3.Connection) -> None:
    """B16: a Feb-29 'Yearly' clamps to Feb 28 in non-leap years (rather than only firing on leaps)."""
    aid = _acct(conn)
    A.create(
        conn, aid, title="Leapiversary", schedule_kind="routine", rrule="FREQ=YEARLY",
        scheduled_start="2024-02-29T12:00:00+00:00",
    )
    # Read year by year: a calendar window may span at most CALENDAR_MAX_WINDOW_DAYS.
    occ = [
        o
        for year in (2024, 2025, 2026, 2027)
        for o in A.calendar(conn, aid, f"{year}-01-01T00:00:00+00:00", f"{year}-12-31T23:59:59+00:00")
    ]
    assert [o.occurs_at[:10] for o in occ] == [
        "2024-02-29", "2025-02-28", "2026-02-28", "2027-02-28",
    ]


def test_multiday_span_measured_in_local_days_not_utc(conn: sqlite3.Connection) -> None:
    """B18: a short evening event that only crosses midnight in UTC is a single occurrence when the
    assignment's timezone is set — not mislabeled 'Day 1 of 2'."""
    aid = _acct(conn)
    # 2026-07-10 18:00-22:00 America/New_York (a 4-hour event), i.e. 22:00Z-02:00Z(+1) in UTC.
    A.create(
        conn, aid, title="Dinner", scheduled_start="2026-07-10T22:00:00+00:00",
        scheduled_end="2026-07-11T02:00:00+00:00", timezone="America/New_York",
    )
    occ = A.calendar(conn, aid, "2026-07-09T00:00:00+00:00", "2026-07-13T00:00:00+00:00")
    assert len(occ) == 1
    assert occ[0].day_count is None  # single day, not a multi-day span
    assert datetime.fromisoformat(occ[0].occurs_at).astimezone(NY).date().isoformat() == "2026-07-10"


def test_create_rejects_unknown_timezone(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError):
        A.create(conn, aid, title="x", scheduled_start="2026-06-20T09:00:00+00:00", timezone="Mars/Olympus")


def test_calendar_routine_respects_scheduled_end(conn: sqlite3.Connection) -> None:
    """A routine's scheduled_end is an upper bound on the recurrence even when the rrule
    itself carries no UNTIL — a bounded 'daily for a week' must stop after a week rather
    than paint an occurrence on every day forever (the Hackathon-reminder bug)."""
    aid = _acct(conn)
    A.create(
        conn, aid, title="Work on submission",
        schedule_kind="routine", rrule="FREQ=DAILY",
        scheduled_start="2026-06-15T09:00:00+00:00",
        scheduled_end="2026-06-21T09:00:00+00:00",  # one week
    )
    # Query a month-wide window; occurrences must stop at 2026-06-21, not run to month end.
    occ = A.calendar(conn, aid, "2026-06-01T00:00:00+00:00", "2026-06-30T23:59:59+00:00")
    days = [o.occurs_at[:10] for o in occ]
    assert days == [f"2026-06-{d:02d}" for d in range(15, 22)]  # 15..21 inclusive, then stops
    # An unbounded routine (scheduled_end=None) still recurs across the whole window.
    A.create(
        conn, aid, title="Standing daily",
        schedule_kind="routine", rrule="FREQ=DAILY",
        scheduled_start="2026-06-15T09:00:00+00:00",
    )
    occ2 = A.calendar(conn, aid, "2026-06-15T00:00:00+00:00", "2026-06-30T23:59:59+00:00")
    assert len([o for o in occ2 if o.title == "Standing daily"]) == 16  # 15..30, unbounded


def test_calendar_includes_sporadic_within_window(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Dentist", scheduled_start="2026-06-18T14:00:00+00:00")
    occ = A.calendar(conn, aid, "2026-06-15T00:00:00+00:00", "2026-06-21T00:00:00+00:00")
    assert len(occ) == 1 and occ[0].title == "Dentist"
    assert occ[0].day_index is None and occ[0].day_count is None  # single-day carries no span
    assert A.calendar(conn, aid, "2026-07-01T00:00:00+00:00", "2026-07-02T00:00:00+00:00") == []


def test_calendar_expands_multiday_sporadic_span(conn: sqlite3.Connection) -> None:
    """B3: a sporadic event with scheduled_end on a later day is a first-class multi-day event —
    one occurrence per day, tagged Day i of N, and clamped to the query window."""
    aid = _acct(conn)
    A.create(
        conn, aid, title="Conference",
        scheduled_start="2026-06-16T09:00:00+00:00", scheduled_end="2026-06-19T17:00:00+00:00",
    )
    occ = A.calendar(conn, aid, "2026-06-15T00:00:00+00:00", "2026-06-21T00:00:00+00:00")
    assert [o.day_index for o in occ] == [1, 2, 3, 4]        # 16,17,18,19
    assert all(o.day_count == 4 and o.title == "Conference" for o in occ)
    # Window clamp: only the middle two days fall inside this narrower window.
    mid = A.calendar(conn, aid, "2026-06-17T00:00:00+00:00", "2026-06-18T23:59:59+00:00")
    assert [o.day_index for o in mid] == [2, 3]


def test_occurrence_status_override(conn: sqlite3.Connection) -> None:
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
    occ = A.calendar(conn, aid, "2026-06-15T00:00:00+00:00", "2026-06-17T00:00:00+00:00")
    by_date = {o.occurs_at[:10]: o.status for o in occ}
    assert by_date["2026-06-16"] == "done"  # overridden
    assert by_date["2026-06-15"] == "todo"  # falls back to assignment status


def test_assign_defaults_lead_time_and_warns(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    d, _ = D.upsert(conn, aid, name="Roommate", lead_time_minutes=1440)  # needs ~1 day
    soon = (datetime.now(UTC) + timedelta(hours=2)).isoformat()
    a = A.create(conn, aid, title="Take out trash", scheduled_start=soon)
    updated, warning = A.assign(conn, aid, a.id, assignee_slug="roommate")
    assert updated.assignee_id == d.id
    assert updated.lead_time_minutes == 1440  # defaulted from the delegatee
    assert warning is not None and "lead time" in warning


def test_assign_no_warning_when_far_enough(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    D.upsert(conn, aid, name="Planner", lead_time_minutes=60)
    far = (datetime.now(UTC) + timedelta(days=3)).isoformat()
    a = A.create(conn, aid, title="x", scheduled_start=far)
    _, warning = A.assign(conn, aid, a.id, assignee_slug="planner")
    assert warning is None


def test_set_status_and_delete(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="x")
    A.set_status(conn, aid, a.id, "done")
    assert A.get(conn, aid, a.id).status == "done"
    with pytest.raises(ValidationError):
        A.set_status(conn, aid, a.id, "bogus")
    A.delete(conn, aid, a.id)
    with pytest.raises(NotFound):
        A.get(conn, aid, a.id)


def test_create_validates_goal_ownership(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "aaa")
    b = _acct(conn, "bbb")
    gb = goals.create(conn, b, title="theirs")
    with pytest.raises(NotFound):
        A.create(conn, a, title="x", goal_id=gb.id)


# --- quality-pass fixes: schedule datetime validation (C1) + empty-title update (C4) ---

def test_sporadic_start_must_be_valid_datetime(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError):
        A.create(conn, aid, title="x", scheduled_start="not-a-date")
    with pytest.raises(ValidationError):
        A.create(conn, aid, title="x", scheduled_start="2026-06-20T09:00:00Z", scheduled_end="garbage")


def test_calendar_survives_legacy_bad_row(conn: sqlite3.Connection) -> None:
    """A pre-validation row with a malformed scheduled_start must not 500 the whole
    account's calendar — it's skipped, and the good rows still expand."""
    aid = _acct(conn)
    good = A.create(conn, aid, title="Good", scheduled_start="2026-06-20T09:00:00+00:00")
    # Insert a garbage row directly, bypassing validation (simulates a legacy row).
    conn.execute(
        "INSERT INTO assignments (account_id, title, schedule_kind, scheduled_start, status, "
        "priority, hidden, created_at, updated_at) "
        "VALUES (?, 'Bad', 'sporadic', 'not-a-date', 'todo', 0, 0, ?, ?)",
        (aid, "2026-06-01T00:00:00+00:00", "2026-06-01T00:00:00+00:00"),
    )
    occ = A.calendar(conn, aid, "2026-06-01T00:00:00+00:00", "2026-06-30T00:00:00+00:00")
    titles = {o.title for o in occ}
    assert good.title in titles and "Bad" not in titles


def test_update_rejects_empty_title(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="Real title", scheduled_start="2026-06-20T09:00:00+00:00")
    with pytest.raises(ValidationError):
        A.update(conn, aid, a.id, title="   ")
    assert A.get(conn, aid, a.id).title == "Real title"  # unchanged


# --- archive (distinct from the hidden veil) ---------------------------------

def test_archive_leaves_default_views_and_restores(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    now = datetime(2026, 7, 20, 9, 0, tzinfo=UTC)
    a = A.create(
        conn, aid, title="Old project standup",
        scheduled_start=(now + timedelta(hours=2)).isoformat(),
    )
    keep = A.create(conn, aid, title="Still active")

    archived = A.set_archived(conn, aid, a.id, True)
    assert archived.archived_at is not None

    live, _ = A.list_(conn, aid, include_hidden=True)
    assert [x.id for x in live] == [keep.id]
    only_archived, _ = A.list_(conn, aid, include_hidden=True, archived=True)
    assert [x.id for x in only_archived] == [a.id]

    assert all(x.id != a.id for x in A.search(conn, aid, "standup", include_hidden=True))
    cal = A.calendar(conn, aid, now.isoformat(), (now + timedelta(days=1)).isoformat(),
                     include_hidden=True)
    assert all(o.assignment_id != a.id for o in cal)

    # Archiving twice keeps the original timestamp; unarchive restores everywhere.
    again = A.set_archived(conn, aid, a.id, True)
    assert again.archived_at == archived.archived_at
    restored = A.set_archived(conn, aid, a.id, False)
    assert restored.archived_at is None
    live, _ = A.list_(conn, aid, include_hidden=True)
    assert {x.id for x in live} == {a.id, keep.id}


def test_archived_assignment_sends_no_reminder(conn: sqlite3.Connection) -> None:
    from command.core import push, reminder_job

    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    a = A.create(
        conn, aid, title="Archived errand",
        scheduled_start=(now + timedelta(minutes=30)).isoformat(),
        lead_time_minutes=60,
    )
    A.set_archived(conn, aid, a.id, True)
    push.register(conn, aid, "TOKEN_ARC", environment="sandbox")
    calls: list[str] = []

    def sender(token, *, title, body, environment="production"):
        calls.append(body)
        from command.core import apns
        return apns.PushResult(ok=True, status=200)

    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=sender) == 0
    assert calls == []


def test_archived_assignment_hidden_from_delegatee(conn: sqlite3.Connection) -> None:
    from command.core import delegatee_access

    aid = _acct(conn)
    helper, _ = D.upsert(conn, aid, name="Helper")
    a = A.create(conn, aid, title="Was theirs", assignee_id=helper.id)
    assert [x.id for x in delegatee_access.my_assignments(conn, aid, helper.id)] == [a.id]
    A.set_archived(conn, aid, a.id, True)
    assert delegatee_access.my_assignments(conn, aid, helper.id) == []
