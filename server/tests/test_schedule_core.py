"""core/schedule.py — free-time search, conflict detection, staleness audit.

Pure computations over assignments_core.calendar(); `now` is always an explicit
parameter (the codebase pattern, see core/reminders.py). Creation timestamps
(updated_at) are driven through the real scenario clock (COMMAND_FAKE_NOW_FILE)
where a test needs to age a row, never a mocked datetime.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime
from pathlib import Path

import pytest

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import delegatees as D
from command.core import schedule as S
from command.errors import ValidationError

T0 = datetime(2026, 8, 3, 9, 0, 0, tzinfo=UTC)   # a Monday


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


# --- find_free_time ----------------------------------------------------------


def test_free_time_empty_calendar_offers_the_window(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    slots = S.find_free_time(
        conn, aid, duration_minutes=60,
        start="2026-08-03T09:00:00+00:00", end="2026-08-03T17:00:00+00:00",
        now=T0,
    )
    assert len(slots) == 1
    assert slots[0].start == "2026-08-03T09:00:00+00:00"
    assert slots[0].end == "2026-08-03T17:00:00+00:00"
    assert slots[0].minutes == 480


def test_free_time_skips_busy_interval(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Dentist",
             scheduled_start="2026-08-03T10:00:00+00:00",
             scheduled_end="2026-08-03T11:00:00+00:00")
    slots = S.find_free_time(
        conn, aid, duration_minutes=30,
        start="2026-08-03T09:00:00+00:00", end="2026-08-03T12:00:00+00:00",
        now=T0,
    )
    assert [(s.start, s.end) for s in slots] == [
        ("2026-08-03T09:00:00+00:00", "2026-08-03T10:00:00+00:00"),
        ("2026-08-03T11:00:00+00:00", "2026-08-03T12:00:00+00:00"),
    ]


def test_free_time_clamps_start_to_now(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    slots = S.find_free_time(
        conn, aid, duration_minutes=60,
        start="2026-08-03T06:00:00+00:00", end="2026-08-03T12:00:00+00:00",
        now=T0,   # 09:00 — the 06:00-09:00 portion is in the past
    )
    assert slots[0].start == "2026-08-03T09:00:00+00:00"


def test_free_time_respects_duration(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Long meeting",
             scheduled_start="2026-08-03T09:30:00+00:00",
             scheduled_end="2026-08-03T17:00:00+00:00")
    slots = S.find_free_time(
        conn, aid, duration_minutes=60,
        start="2026-08-03T09:00:00+00:00", end="2026-08-03T18:00:00+00:00",
        now=T0,
    )
    # Only 09:00-09:30 (30 min) and 17:00-18:00 (60 min) are free.
    assert [(s.start, s.end) for s in slots] == [("2026-08-03T17:00:00+00:00", "2026-08-03T18:00:00+00:00")]


def test_free_time_ignores_zero_duration_reminders(conn: sqlite3.Connection) -> None:
    """A point-in-time reminder (no scheduled_end) doesn't block free time."""
    aid = _acct(conn)
    A.create(conn, aid, title="Take meds", scheduled_start="2026-08-03T10:00:00+00:00")
    A.create(conn, aid, title="Standup", schedule_kind="routine", rrule="FREQ=DAILY",
             scheduled_start="2026-08-03T11:00:00+00:00")
    slots = S.find_free_time(
        conn, aid, duration_minutes=120,
        start="2026-08-03T09:00:00+00:00", end="2026-08-03T12:00:00+00:00",
        now=T0,
    )
    assert len(slots) == 1 and slots[0].minutes == 180


def test_free_time_excludes_cancelled_and_done(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    cancelled = A.create(conn, aid, title="Off", status="cancelled",
                         scheduled_start="2026-08-03T10:00:00+00:00",
                         scheduled_end="2026-08-03T11:00:00+00:00")
    assert cancelled.status == "cancelled"
    slots = S.find_free_time(
        conn, aid, duration_minutes=60,
        start="2026-08-03T09:00:00+00:00", end="2026-08-03T12:00:00+00:00",
        now=T0,
    )
    assert len(slots) == 1 and slots[0].minutes == 180


def test_free_time_workday_only_skips_weekend(conn: sqlite3.Connection) -> None:
    """2026-08-07 is a Friday, 08-08/08-09 the weekend, 08-10 a Monday."""
    aid = _acct(conn)
    now = datetime(2026, 8, 7, 9, 0, 0, tzinfo=UTC)
    slots = S.find_free_time(
        conn, aid, duration_minutes=240,
        start="2026-08-07T09:00:00+00:00", end="2026-08-11T00:00:00+00:00",
        now=now, workday_only=True,
    )
    assert slots, "expected weekday slots"
    for s in slots:
        day = datetime.fromisoformat(s.start).weekday()
        assert day < 5, f"slot on weekend day {day}: {s}"
    starts = [s.start[:10] for s in slots]
    assert "2026-08-08" not in starts and "2026-08-09" not in starts
    assert "2026-08-07" in starts and "2026-08-10" in starts


def test_workday_only_skips_the_users_own_weekend_not_utcs(conn: sqlite3.Connection) -> None:
    """Whose Saturday is being skipped.

    The day split used to run on whatever tzinfo the datetimes happened to carry — and since
    the window is clamped to `now`, which is UTC, any search starting in the past (i.e. most
    of them) silently computed weekends in UTC. For Los Angeles that is wrong in both
    directions at once: Friday 17:00-24:00 local is already Saturday UTC and was dropped,
    while Sunday 17:00-24:00 local is Monday UTC and was offered as a working day.
    """
    aid = _acct(conn)
    # Friday 2026-08-07, 16:00 in Los Angeles = 23:00 UTC. The window runs into Saturday UTC
    # but is still Friday evening for the user.
    now = datetime(2026, 8, 7, 23, 0, 0, tzinfo=UTC)
    la = S.find_free_time(
        conn, aid, duration_minutes=60,
        start="2026-08-07T23:00:00+00:00", end="2026-08-08T04:00:00+00:00",
        now=now, workday_only=True, timezone="America/Los_Angeles",
    )
    assert la, "Friday evening in LA is a workday and must be offered"

    assert la[0].minutes == 300, "the whole window is one Friday-evening gap in LA"

    # A UTC account sees the same instants split by ITS midnight: the first hour is still
    # Friday, the rest is Saturday and must be dropped.
    utc = S.find_free_time(
        conn, aid, duration_minutes=60,
        start="2026-08-07T23:00:00+00:00", end="2026-08-08T04:00:00+00:00",
        now=now, workday_only=True, timezone="UTC",
    )
    assert [(s.start, s.minutes) for s in utc] == [("2026-08-07T23:00:00+00:00", 60)], (
        "only the pre-midnight hour is a UTC workday; 00:00-04:00 is Saturday"
    )

    # And the mirror image: Sunday evening in LA is Monday UTC, and is NOT a workday there.
    sunday_night = datetime(2026, 8, 10, 1, 0, 0, tzinfo=UTC)   # Sun 18:00 LA
    la_sunday = S.find_free_time(
        conn, aid, duration_minutes=60,
        start="2026-08-10T01:00:00+00:00", end="2026-08-10T05:00:00+00:00",
        now=sunday_night, workday_only=True, timezone="America/Los_Angeles",
    )
    assert la_sunday == [], "Sunday evening in LA is the weekend, however it looks in UTC"


def test_free_time_validates_inputs(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError):
        S.find_free_time(conn, aid, duration_minutes=0,
                         start="2026-08-03T09:00:00+00:00", end="2026-08-03T17:00:00+00:00", now=T0)
    with pytest.raises(ValidationError):
        S.find_free_time(conn, aid, duration_minutes=60,
                         start="2026-08-03T17:00:00+00:00", end="2026-08-03T09:00:00+00:00", now=T0)


def test_free_time_multi_day_event_blocks_each_day(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Offsite",  # Tue 14:00 → Thu 12:00
             scheduled_start="2026-08-04T14:00:00+00:00",
             scheduled_end="2026-08-06T12:00:00+00:00")
    slots = S.find_free_time(
        conn, aid, duration_minutes=60,
        start="2026-08-04T00:00:00+00:00", end="2026-08-07T00:00:00+00:00",
        now=datetime(2026, 8, 4, 0, 0, 0, tzinfo=UTC),
    )
    # Free: Tue before 14:00, Thu after 12:00. Wednesday is entirely busy.
    assert [(s.start, s.end) for s in slots] == [
        ("2026-08-04T00:00:00+00:00", "2026-08-04T14:00:00+00:00"),
        ("2026-08-06T12:00:00+00:00", "2026-08-07T00:00:00+00:00"),
    ]


# --- find_conflicts ----------------------------------------------------------


def test_conflicts_overlapping_events(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="A",
             scheduled_start="2026-08-03T10:00:00+00:00", scheduled_end="2026-08-03T11:00:00+00:00")
    A.create(conn, aid, title="B",
             scheduled_start="2026-08-03T10:30:00+00:00", scheduled_end="2026-08-03T11:30:00+00:00")
    out = S.find_conflicts(conn, aid, start="2026-08-03T00:00:00+00:00", end="2026-08-04T00:00:00+00:00")
    assert len(out) == 1
    c = out[0]
    assert {c.first.title, c.second.title} == {"A", "B"}
    assert c.overlap_start == "2026-08-03T10:30:00+00:00"
    assert c.overlap_end == "2026-08-03T11:00:00+00:00"


def test_conflicts_back_to_back_is_not_a_conflict(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="A",
             scheduled_start="2026-08-03T10:00:00+00:00", scheduled_end="2026-08-03T11:00:00+00:00")
    A.create(conn, aid, title="B",
             scheduled_start="2026-08-03T11:00:00+00:00", scheduled_end="2026-08-03T12:00:00+00:00")
    assert S.find_conflicts(conn, aid, start="2026-08-03T00:00:00+00:00",
                            end="2026-08-04T00:00:00+00:00") == []


def test_conflicts_coincident_reminders(conn: sqlite3.Connection) -> None:
    """Two point-in-time things at the exact same instant collide."""
    aid = _acct(conn)
    A.create(conn, aid, title="Meds", scheduled_start="2026-08-03T09:00:00+00:00")
    A.create(conn, aid, title="Call Mum", scheduled_start="2026-08-03T09:00:00+00:00")
    out = S.find_conflicts(conn, aid, start="2026-08-03T00:00:00+00:00", end="2026-08-04T00:00:00+00:00")
    assert len(out) == 1
    assert out[0].overlap_start == "2026-08-03T09:00:00+00:00"
    assert out[0].overlap_end == "2026-08-03T09:00:00+00:00"


def test_conflicts_reminder_inside_event(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Meeting",
             scheduled_start="2026-08-03T10:00:00+00:00", scheduled_end="2026-08-03T11:00:00+00:00")
    A.create(conn, aid, title="Meds", scheduled_start="2026-08-03T10:15:00+00:00")
    out = S.find_conflicts(conn, aid, start="2026-08-03T00:00:00+00:00", end="2026-08-04T00:00:00+00:00")
    assert len(out) == 1
    assert {out[0].first.title, out[0].second.title} == {"Meeting", "Meds"}


def test_conflicts_an_assignment_never_conflicts_with_itself(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Daily", schedule_kind="routine", rrule="FREQ=DAILY;COUNT=5",
             scheduled_start="2026-08-03T09:00:00+00:00")
    assert S.find_conflicts(conn, aid, start="2026-08-03T00:00:00+00:00",
                            end="2026-08-10T00:00:00+00:00") == []


def test_conflicts_skip_cancelled_and_done(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Gone", status="cancelled",
             scheduled_start="2026-08-03T10:00:00+00:00", scheduled_end="2026-08-03T11:00:00+00:00")
    A.create(conn, aid, title="Real",
             scheduled_start="2026-08-03T10:30:00+00:00", scheduled_end="2026-08-03T11:30:00+00:00")
    assert S.find_conflicts(conn, aid, start="2026-08-03T00:00:00+00:00",
                            end="2026-08-04T00:00:00+00:00") == []


# --- find_stale_assignments --------------------------------------------------


def _age_rows(clock_file: Path, when: datetime) -> None:
    clock_file.write_text(when.isoformat())


def test_stale_overdue_and_untouched_and_blocked(
    conn: sqlite3.Connection, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Rows age through the scenario clock: created at T0, audited at T0+20d."""
    clock_file = tmp_path / "now.txt"
    _age_rows(clock_file, T0)
    monkeypatch.setenv("COMMAND_FAKE_NOW_FILE", str(clock_file))

    aid = _acct(conn)
    sam, _ = D.upsert(conn, aid, name="Sam", kind="human")
    _overdue = A.create(conn, aid, title="File taxes", assignee_id=sam.id,
                       scheduled_start="2026-08-05T09:00:00+00:00")
    _untouched = A.create(conn, aid, title="Learn piano")   # no schedule, never edited
    _blocked = A.create(conn, aid, title="Waiting on parts", status="blocked")
    fine = A.create(conn, aid, title="Done thing", status="done",
                    scheduled_start="2026-08-05T09:00:00+00:00")
    archived = A.create(conn, aid, title="Old", status="blocked")
    A.set_archived(conn, aid, archived.id, True)

    later = T0.replace(day=23)   # 2026-08-23 — 20 days on
    findings = S.find_stale_assignments(conn, aid, threshold_days=7, now=later)
    by_title = {f.title: f for f in findings}

    assert by_title["File taxes"].reasons == ["overdue", "untouched"]
    assert by_title["File taxes"].assignee_slug == "sam" and by_title["File taxes"].assignee_name == "Sam"
    assert by_title["File taxes"].overdue_since is not None
    assert by_title["Learn piano"].reasons == ["untouched"]
    assert by_title["Waiting on parts"].reasons == ["blocked", "untouched"]
    assert "Done thing" not in by_title
    assert "Old" not in by_title  # archived leaves the audit
    assert fine.title not in by_title
    assert all(f.updated_at for f in findings)


def test_stale_threshold_is_respected(conn: sqlite3.Connection, tmp_path: Path,
                                      monkeypatch: pytest.MonkeyPatch) -> None:
    clock_file = tmp_path / "now.txt"
    _age_rows(clock_file, T0)
    monkeypatch.setenv("COMMAND_FAKE_NOW_FILE", str(clock_file))
    aid = _acct(conn)
    A.create(conn, aid, title="Recent")
    findings = S.find_stale_assignments(
        conn, aid, threshold_days=30, now=T0.replace(day=10)  # 7 days on < 30
    )
    assert findings == []


def test_stale_done_occurrence_is_not_overdue(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="Daily dose", schedule_kind="routine", rrule="FREQ=DAILY",
                 scheduled_start="2026-08-01T09:00:00+00:00")
    # Every past occurrence actioned → nothing overdue.
    A.set_occurrence_status(conn, aid, a.id, "2026-08-01", "done")
    A.set_occurrence_status(conn, aid, a.id, "2026-08-02", "skipped")
    findings = S.find_stale_assignments(conn, aid, threshold_days=3650, now=T0)
    assert all(f.reasons != ["overdue"] for f in findings)
    assert not any("overdue" in f.reasons for f in findings)
