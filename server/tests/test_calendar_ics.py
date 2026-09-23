from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import calendar_ics


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_token_round_trip_and_tamper() -> None:
    secret = "s3cret"
    tok = calendar_ics.calendar_token(42, secret)
    assert tok.startswith("42.")
    assert calendar_ics.verify_calendar_token(tok, secret) == 42
    # Wrong secret, tampered id, tampered sig, and garbage all reject.
    assert calendar_ics.verify_calendar_token(tok, "other") is None
    assert calendar_ics.verify_calendar_token("99." + tok.split(".", 1)[1], secret) is None
    assert calendar_ics.verify_calendar_token("42.deadbeef", secret) is None
    assert calendar_ics.verify_calendar_token("nonsense", secret) is None


def test_build_ics_structure_and_escaping() -> None:
    occ = A.Occurrence(
        assignment_id=7,
        title="Pay rent; call landlord, please",
        occurs_at="2026-07-01T09:30:00+00:00",
        status="todo",
        assignee_id=None,
        schedule_kind="sporadic",
    )
    now = datetime(2026, 6, 23, 12, 0, 0, tzinfo=UTC)
    ics = calendar_ics.build_ics([occ], calendar_name="Command", now=now)

    assert ics.startswith("BEGIN:VCALENDAR\r\n")
    assert ics.strip().endswith("END:VCALENDAR")
    assert "\r\n" in ics and ics[-1] == "\n"  # CRLF line endings
    assert "VERSION:2.0" in ics
    assert "BEGIN:VEVENT" in ics and "END:VEVENT" in ics
    assert "DTSTART:20260701T093000Z" in ics
    assert "DTEND:20260701T100000Z" in ics            # +30 min default
    assert "DTSTAMP:20260623T120000Z" in ics
    assert "UID:7-20260701T093000Z@command.legitimateapps.com" in ics
    # RFC 5545 escaping of ; and ,
    assert "SUMMARY:Pay rent\\; call landlord\\, please" in ics


def test_build_ics_marks_cancelled() -> None:
    occ = A.Occurrence(assignment_id=1, title="x", occurs_at="2026-07-01T09:30:00+00:00",
                       status="cancelled", assignee_id=None, schedule_kind="sporadic")
    ics = calendar_ics.build_ics([occ], calendar_name="Command", now=datetime(2026, 6, 23, tzinfo=UTC))
    assert "STATUS:CANCELLED" in ics


def test_hidden_assignments_excluded_from_feed(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Visible", scheduled_start="2026-07-01T09:00:00+00:00")
    A.create(conn, aid, title="Secret", scheduled_start="2026-07-02T09:00:00+00:00", hidden=True)
    occ = A.calendar(conn, aid, "2026-06-30T00:00:00+00:00", "2026-07-10T00:00:00+00:00",
                     include_hidden=False)
    ics = calendar_ics.build_ics(occ, calendar_name="Command", now=datetime(2026, 6, 23, tzinfo=UTC))
    assert "Visible" in ics
    assert "Secret" not in ics


def test_exported_events_use_the_real_duration_not_a_flat_30_minutes(
    conn: sqlite3.Connection,
) -> None:
    """Every exported event used to be exactly 30 minutes long, because an `Occurrence` has no
    duration and nobody went back to the parent for one. A three-hour meeting subscribed as
    half an hour, on every device the user had pointed at the feed."""
    aid = _acct(conn)
    meeting = A.create(
        conn, aid, title="Board meeting",
        scheduled_start="2026-07-01T09:00:00+00:00",
        scheduled_end="2026-07-01T12:00:00+00:00",
    )
    occurrences = A.calendar(
        conn, aid, "2026-07-01T00:00:00+00:00", "2026-07-02T00:00:00+00:00"
    )
    now = datetime(2026, 6, 23, 12, 0, 0, tzinfo=UTC)

    # Without the parents map: the old behaviour, still available as a fallback.
    flat = calendar_ics.build_ics(occurrences, calendar_name="Command", now=now)
    assert "DTEND:20260701T093000Z" in flat

    parents = A.parents_for(conn, aid, [meeting.id])
    real = calendar_ics.build_ics(
        occurrences, calendar_name="Command", now=now, parents=parents
    )
    assert "DTSTART:20260701T090000Z" in real
    assert "DTEND:20260701T120000Z" in real, "the meeting is three hours, not thirty minutes"


def test_a_multi_day_event_exports_as_one_span_not_a_block_per_day(
    conn: sqlite3.Connection,
) -> None:
    """A multi-day assignment expands to one occurrence PER DAY for the app's day columns. A
    calendar subscription must see ONE event covering the range — otherwise a four-day trip
    arrives as four separate half-hour blocks."""
    aid = _acct(conn)
    trip = A.create(
        conn, aid, title="Conference",
        scheduled_start="2026-07-01T08:00:00+00:00",
        scheduled_end="2026-07-04T17:00:00+00:00",
    )
    occurrences = A.calendar(
        conn, aid, "2026-07-01T00:00:00+00:00", "2026-07-05T00:00:00+00:00"
    )
    assert len(occurrences) == 4, "the app still gets one occurrence per day"

    ics = calendar_ics.build_ics(
        occurrences, calendar_name="Command",
        now=datetime(2026, 6, 23, 12, 0, 0, tzinfo=UTC),
        parents=A.parents_for(conn, aid, [trip.id]),
    )
    assert ics.count("BEGIN:VEVENT") == 1, "one calendar event, not one per day"
    assert "DTSTART:20260701T080000Z" in ics
    assert "DTEND:20260704T170000Z" in ics


def test_point_in_time_reminders_keep_the_default_block(conn: sqlite3.Connection) -> None:
    """A bare reminder has no end, so it has no duration to honour — it must still render as a
    visible block rather than a zero-length event a calendar would hide."""
    aid = _acct(conn)
    meds = A.create(conn, aid, title="Take meds", scheduled_start="2026-07-01T09:00:00+00:00")
    occurrences = A.calendar(
        conn, aid, "2026-07-01T00:00:00+00:00", "2026-07-02T00:00:00+00:00"
    )
    ics = calendar_ics.build_ics(
        occurrences, calendar_name="Command",
        now=datetime(2026, 6, 23, 12, 0, 0, tzinfo=UTC),
        parents=A.parents_for(conn, aid, [meds.id]),
    )
    assert "DTSTART:20260701T090000Z" in ics
    assert "DTEND:20260701T093000Z" in ics
