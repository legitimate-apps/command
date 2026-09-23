"""Calendar expansion: time-ordered truncation, bounded work, and per-occurrence duration.

Regressions from the 2026-09 audit. Each test here failed on the pre-fix code:

- `calendar()` expanded assignment-by-assignment in TABLE order and cut at 1000, so older
  daily routines filled the cap and a newer meeting vanished from the calendar, free-time
  search and the stale scan.
- A FREQ=SECONDLY/MINUTELY rule, or a one-off ending in year 9999, made one row cost millions
  of occurrences; any window width was accepted.
- A routine's `scheduled_end` (the date the RECURRENCE stops) was read as each occurrence's
  duration, so "daily for a week" became week-long busy blocks and 7-day iCal events.
- Garbage start/end reached `datetime.fromisoformat` and 500'd.
- Reminders only looked 14 days ahead, so a longer lead time fired late.
"""

from __future__ import annotations

import json
import sqlite3
import time
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import briefings, calendar_ics, reminders, schedule
from command.core.agent import tools
from command.errors import ValidationError

NOW = datetime(2026, 9, 1, 12, 0, tzinfo=UTC)


def _acct(conn: sqlite3.Connection) -> int:
    return accounts_core.register(conn, "owner", "password1").id


def _iso(dt: datetime) -> str:
    return dt.isoformat()


# ---------- truncation happens in TIME order ----------


def _crowded(conn: sqlite3.Connection, aid: int, routines: int, *, start: datetime) -> None:
    for i in range(routines):
        A.create(conn, aid, title=f"daily{i}", schedule_kind="routine", rrule="FREQ=DAILY",
                 scheduled_start=_iso(start + timedelta(hours=i)))


def test_a_newer_assignment_is_not_dropped_by_older_routines_filling_the_cap(
    conn: sqlite3.Connection,
) -> None:
    aid = _acct(conn)
    _crowded(conn, aid, 3, start=NOW - timedelta(days=10))
    meet = NOW + timedelta(days=5)
    m = A.create(conn, aid, title="meeting", scheduled_start=_iso(meet),
                 scheduled_end=_iso(meet + timedelta(hours=2)))

    occ, truncated = A.calendar_window(conn, aid, _iso(NOW), _iso(NOW + timedelta(days=365)))
    assert truncated is True and len(occ) == A.CALENDAR_MAX_OCCURRENCES
    assert any(o.assignment_id == m.id for o in occ), "the meeting fell off a table-order cap"
    instants = [A._parse_dt(o.occurs_at) for o in occ]
    assert instants == sorted(instants)
    # The kept ones are the EARLIEST: nothing returned is later than anything cut.
    assert instants[-1] < NOW + timedelta(days=365)


def test_free_time_sees_a_meeting_created_after_crowding_routines(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    _crowded(conn, aid, 3, start=NOW - timedelta(days=10))
    meet = NOW + timedelta(days=5)
    A.create(conn, aid, title="meeting", scheduled_start=_iso(meet),
             scheduled_end=_iso(meet + timedelta(hours=2)))
    slots = schedule.find_free_time(
        conn, aid, duration_minutes=60, start=_iso(meet - timedelta(minutes=1)),
        end=_iso(NOW + timedelta(days=365)), now=NOW,
    )
    first = datetime.fromisoformat(slots[0].start)
    assert first >= meet + timedelta(hours=2), "offered a slot inside the meeting"


def test_stale_scan_finds_an_overdue_item_behind_crowding_routines(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    _crowded(conn, aid, 6, start=NOW - timedelta(days=400))
    for row in conn.execute("SELECT id FROM assignments").fetchall():
        A.set_status(conn, aid, row["id"], "blocked")   # keep them out of the 'overdue' count
    past = NOW - timedelta(days=200)
    late = A.create(conn, aid, title="file taxes", scheduled_start=_iso(past))
    found = {f.assignment_id: f for f in schedule.find_stale_assignments(conn, aid, now=NOW)}
    assert late.id in found and "overdue" in found[late.id].reasons


# ---------- bounded work ----------


@pytest.mark.parametrize("freq", ["SECONDLY", "MINUTELY"])
def test_sub_hourly_recurrence_is_rejected_on_create_and_update(
    conn: sqlite3.Connection, freq: str
) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError, match=freq):
        A.create(conn, aid, title="x", schedule_kind="routine", rrule=f"FREQ={freq}",
                 scheduled_start=_iso(NOW))
    a = A.create(conn, aid, title="x", schedule_kind="routine", rrule="FREQ=DAILY",
                 scheduled_start=_iso(NOW))
    with pytest.raises(ValidationError, match="too fine-grained"):
        A.update(conn, aid, a.id, rrule=f"FREQ={freq};INTERVAL=5")


def test_legacy_minutely_row_expands_boundedly(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="x", schedule_kind="routine", rrule="FREQ=DAILY",
                 scheduled_start=_iso(NOW))
    # A row written before validation existed.
    conn.execute("UPDATE assignments SET rrule = 'FREQ=MINUTELY' WHERE id = ?", (a.id,))
    t = time.monotonic()
    occ, truncated = A.calendar_window(conn, aid, _iso(NOW), _iso(NOW + timedelta(days=120)))
    assert time.monotonic() - t < 5
    assert len(occ) == A.CALENDAR_MAX_OCCURRENCES and truncated


def test_one_off_span_is_capped_and_a_legacy_endless_span_is_cheap(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError, match="span at most"):
        A.create(conn, aid, title="forever", scheduled_start=_iso(NOW),
                 scheduled_end="9999-01-01T00:00:00+00:00")
    a = A.create(conn, aid, title="trip", scheduled_start=_iso(NOW),
                 scheduled_end=_iso(NOW + timedelta(days=3)))
    conn.execute("UPDATE assignments SET scheduled_end = '9999-01-01T00:00:00+00:00' WHERE id = ?",
                 (a.id,))
    window_start = NOW + timedelta(days=100)
    t = time.monotonic()
    occ = A.calendar(conn, aid, _iso(window_start), _iso(window_start + timedelta(days=1)))
    assert time.monotonic() - t < 1, "expanded the whole span to read one day"
    assert [o.day_index for o in occ] == [101, 102]   # [start, end] is inclusive


def test_calendar_window_width_is_capped(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError, match="at most"):
        A.calendar(conn, aid, "1900-01-01T00:00:00+00:00", "2400-01-01T00:00:00+00:00")


def test_find_conflicts_window_is_capped(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError, match="at most"):
        schedule.find_conflicts(conn, aid, start="1900-01-01T00:00:00+00:00",
                                end="2400-01-01T00:00:00+00:00")


# ---------- malformed windows are validation errors, not 500s ----------


@pytest.mark.parametrize(("start", "end"),[("tomorrow", "2026-09-02T00:00:00Z"),
                                       ("2026-09-02T00:00:00Z", "next week")])
def test_calendar_rejects_unparseable_bounds(conn: sqlite3.Connection, start: str, end: str) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError, match="ISO-8601"):
        A.calendar(conn, aid, start, end)


def test_agent_calendar_tool_returns_an_error_not_a_crash(tmp_path: object) -> None:
    from command.db import connection, init_db

    db = str(tmp_path / "a.db")  # type: ignore[operator]
    init_db(db)
    with connection(db) as c:
        aid = _acct(c)
    ctx = SimpleNamespace(deps=tools.AgentDeps(db_path=db, account_id=aid))
    out = json.loads(tools.get_calendar(ctx, "tomorrow", "next week"))
    assert "ISO-8601" in out["error"]


def test_rest_calendar_422_on_garbage_and_header_on_success(client: TestClient) -> None:
    assert client.post("/api/auth/register",
                       json={"username": "owner", "password": "password1"}).status_code == 200
    r = client.get("/api/assignments/calendar", params={"start": "tomorrow", "end": "next week"})
    assert r.status_code == 422
    r = client.get("/api/assignments/calendar",
                   params={"start": "2026-09-01T00:00:00Z", "end": "2026-09-02T00:00:00Z"})
    assert r.status_code == 200 and r.headers["X-Calendar-Truncated"] == "false"
    r = client.get("/api/assignments/calendar",
                   params={"start": "1900-01-01T00:00:00Z", "end": "2400-01-01T00:00:00Z"})
    assert r.status_code == 422


# ---------- a routine's scheduled_end bounds the SERIES, not each occurrence ----------


def _bounded_daily(conn: sqlite3.Connection, aid: int) -> A.Assignment:
    s = NOW + timedelta(hours=1)
    return A.create(conn, aid, title="meds", schedule_kind="routine", rrule="FREQ=DAILY",
                    scheduled_start=_iso(s), scheduled_end=_iso(s + timedelta(days=7)),
                    timezone="America/New_York")


def test_bounded_routine_occurrences_are_points_not_week_long_blocks(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    _bounded_daily(conn, aid)
    meet = NOW + timedelta(days=1, hours=5)   # not at a meds instant
    A.create(conn, aid, title="meeting", scheduled_start=_iso(meet),
             scheduled_end=_iso(meet + timedelta(hours=1)))
    window = (_iso(NOW), _iso(NOW + timedelta(days=10)))
    assert schedule.find_conflicts(conn, aid, start=window[0], end=window[1]) == []
    slots = schedule.find_free_time(conn, aid, duration_minutes=60, start=window[0],
                                    end=_iso(NOW + timedelta(days=3)), now=NOW)
    # Free until the meeting, not blocked for a week by the reminder series.
    assert datetime.fromisoformat(slots[0].end) == meet


def test_bounded_routine_exports_short_ical_events(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    _bounded_daily(conn, aid)
    occ = A.calendar(conn, aid, _iso(NOW), _iso(NOW + timedelta(days=10)))
    assert len(occ) == 8
    parents = A.parents_for(conn, aid, [o.assignment_id for o in occ])
    ics = calendar_ics.build_ics(occ, calendar_name="x", now=NOW, parents=parents)
    starts = [ln for ln in ics.split("\r\n") if ln.startswith("DTSTART")]
    ends = [ln for ln in ics.split("\r\n") if ln.startswith("DTEND")]
    s0 = datetime.strptime(starts[0], "DTSTART:%Y%m%dT%H%M%SZ")
    e0 = datetime.strptime(ends[0], "DTEND:%Y%m%dT%H%M%SZ")
    assert e0 - s0 == timedelta(minutes=30)


def test_one_off_interval_still_has_its_real_duration(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="x", scheduled_start=_iso(NOW),
                 scheduled_end=_iso(NOW + timedelta(hours=3)))
    assert A.occurrence_duration(a) == timedelta(hours=3)


# ---------- reminders reach as far as the longest lead ----------


def test_long_lead_reminder_fires_on_time(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="passport renewal", scheduled_start=_iso(NOW + timedelta(days=20)),
                 lead_time_minutes=21 * 24 * 60)
    due = [r for r in reminders.upcoming_reminders(conn, aid, now=NOW) if r.due]
    assert [r.assignment_id for r in due] == [a.id]


def test_far_occurrence_with_short_lead_stays_out_of_the_window(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="long lead", scheduled_start=_iso(NOW + timedelta(days=60)),
             lead_time_minutes=61 * 24 * 60)
    b = A.create(conn, aid, title="far", scheduled_start=_iso(NOW + timedelta(days=30)))
    got = {r.assignment_id for r in reminders.upcoming_reminders(conn, aid, now=NOW)}
    assert b.id not in got


# ---------- stale scan: settled and hidden work ----------


def test_skipped_assignment_is_not_flagged_untouched(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="skipped thing")
    A.set_status(conn, aid, a.id, "skipped")
    later = datetime.now(UTC) + timedelta(days=30)
    assert schedule.find_stale_assignments(conn, aid, now=later) == []


def test_hidden_titles_stay_out_of_stale_conflicts_and_the_briefing(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    at = NOW + timedelta(days=1)
    A.create(conn, aid, title="SECRET", scheduled_start=_iso(at),
             scheduled_end=_iso(at + timedelta(hours=1)), hidden=True)
    A.create(conn, aid, title="visible", scheduled_start=_iso(at),
             scheduled_end=_iso(at + timedelta(hours=1)))
    A.create(conn, aid, title="SECRET overdue", scheduled_start=_iso(NOW - timedelta(days=3)),
             hidden=True)
    window = {"start": _iso(NOW), "end": _iso(NOW + timedelta(days=2))}
    assert schedule.find_conflicts(conn, aid, **window) == []
    assert len(schedule.find_conflicts(conn, aid, **window, include_hidden=True)) == 1
    stale = schedule.find_stale_assignments(conn, aid, now=NOW)
    assert not any("SECRET" in s.title for s in stale)
    digest = briefings.build_digest(conn, aid, now=NOW, prefs=briefings.get_prefs(conn, aid))
    assert "SECRET" not in digest.headline
    assert not any("SECRET" in i.title for i in digest.overdue + digest.blocked)
