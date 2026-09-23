"""Per-occurrence reschedule (occurrence_overrides): both window directions, identity-key
stability, reminder timing, and the REST surface."""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import reminders
from command.errors import NotFound, ValidationError


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def _daily(conn: sqlite3.Connection, aid: int, title: str = "Standup") -> A.Assignment:
    return A.create(
        conn, aid, title=title, schedule_kind="routine", rrule="FREQ=DAILY",
        scheduled_start="2026-08-03T09:00:00+00:00",
    )


def _cal(conn: sqlite3.Connection, aid: int, start: str, end: str) -> list[A.Occurrence]:
    return A.calendar(conn, aid, start, end)


def test_reschedule_moves_one_occurrence_only(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = _daily(conn, aid)
    A.reschedule_occurrence(conn, aid, a.id, "2026-08-05", "2026-08-05T14:30:00+00:00")

    occs = _cal(conn, aid, "2026-08-03T00:00:00+00:00", "2026-08-07T23:59:59+00:00")
    by_key = {o.occurrence_date: o for o in occs}
    assert by_key["2026-08-05"].occurs_at == "2026-08-05T14:30:00+00:00"
    assert by_key["2026-08-05"].rescheduled is True
    # neighbors untouched, at series time
    assert by_key["2026-08-04"].occurs_at.startswith("2026-08-04T09:00")
    assert by_key["2026-08-04"].rescheduled is False
    assert by_key["2026-08-06"].occurs_at.startswith("2026-08-06T09:00")


def test_override_moved_out_of_window_disappears_and_appears_at_target(
    conn: sqlite3.Connection,
) -> None:
    aid = _acct(conn)
    a = _daily(conn, aid)
    # move Aug 5 into next week
    A.reschedule_occurrence(conn, aid, a.id, "2026-08-05", "2026-08-12T10:00:00+00:00")

    # the original day's window no longer contains it
    day5 = _cal(conn, aid, "2026-08-05T00:00:00+00:00", "2026-08-05T23:59:59+00:00")
    assert [o for o in day5 if o.assignment_id == a.id] == []

    # the TARGET day's window synthesizes it in — with the ORIGINAL identity key
    day12 = _cal(conn, aid, "2026-08-12T00:00:00+00:00", "2026-08-12T23:59:59+00:00")
    moved = [o for o in day12 if o.rescheduled]
    assert len(moved) == 1
    assert moved[0].occurrence_date == "2026-08-05"
    assert moved[0].occurs_at == "2026-08-12T10:00:00+00:00"
    # Aug 12 also keeps its own series occurrence
    assert any(o.occurrence_date == "2026-08-12" and not o.rescheduled for o in day12)


def test_status_keys_on_original_date_and_survives_reschedule(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = _daily(conn, aid)
    A.set_occurrence_status(conn, aid, a.id, "2026-08-05", "done")
    A.reschedule_occurrence(conn, aid, a.id, "2026-08-05", "2026-08-05T18:00:00+00:00")
    occs = _cal(conn, aid, "2026-08-05T00:00:00+00:00", "2026-08-05T23:59:59+00:00")
    target = next(o for o in occs if o.occurrence_date == "2026-08-05")
    assert target.status == "done"
    assert target.occurs_at == "2026-08-05T18:00:00+00:00"


def test_clear_override_resets_to_series_time(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = _daily(conn, aid)
    A.reschedule_occurrence(conn, aid, a.id, "2026-08-05", "2026-08-05T14:30:00+00:00")
    assert A.clear_occurrence_override(conn, aid, a.id, "2026-08-05") is True
    assert A.clear_occurrence_override(conn, aid, a.id, "2026-08-05") is False
    occs = _cal(conn, aid, "2026-08-05T00:00:00+00:00", "2026-08-05T23:59:59+00:00")
    target = next(o for o in occs if o.occurrence_date == "2026-08-05")
    assert target.occurs_at.startswith("2026-08-05T09:00")
    assert target.rescheduled is False


def test_sporadic_and_bogus_inputs_rejected(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    sporadic = A.create(conn, aid, title="One-off", scheduled_start="2026-08-05T09:00:00+00:00")
    with pytest.raises(ValidationError, match="routine"):
        A.reschedule_occurrence(conn, aid, sporadic.id, "2026-08-05", "2026-08-05T10:00:00+00:00")
    routine = _daily(conn, aid)
    with pytest.raises(ValidationError, match="ISO-8601"):
        A.reschedule_occurrence(conn, aid, routine.id, "2026-08-05", "not-a-time")
    with pytest.raises(NotFound, match="No occurrence"):
        A.reschedule_occurrence(conn, aid, routine.id, "2026-08-02", "2026-08-02T10:00:00+00:00")
    with pytest.raises(NotFound):
        A.reschedule_occurrence(conn, _acct(conn, "other"), routine.id, "2026-08-05",
                                "2026-08-05T10:00:00+00:00")


def test_stale_override_does_not_resurrect(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(
        conn, aid, title="Weekly", schedule_kind="routine", rrule="FREQ=WEEKLY",
        scheduled_start="2026-08-03T09:00:00+00:00",   # Mondays
    )
    # Simulate a stale row (e.g. left behind by an rrule edit): a date the series never hits.
    conn.execute(
        "INSERT INTO occurrence_overrides (assignment_id, occurrence_date, occurs_at,"
        " created_at, updated_at) VALUES (?, '2026-08-06', '2026-08-07T10:00:00+00:00', '', '')",
        (a.id,),
    )
    week = _cal(conn, aid, "2026-08-03T00:00:00+00:00", "2026-08-09T23:59:59+00:00")
    mine = [o for o in week if o.assignment_id == a.id]
    assert len(mine) == 1                       # only the genuine Monday occurrence
    assert mine[0].occurrence_date == "2026-08-03"


def test_reminder_uses_effective_time(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(
        conn, aid, title="Water plants", schedule_kind="routine", rrule="FREQ=DAILY",
        scheduled_start="2026-08-03T09:00:00+00:00", lead_time_minutes=60,
    )
    A.reschedule_occurrence(conn, aid, a.id, "2026-08-04", "2026-08-04T17:00:00+00:00")
    now = datetime(2026, 8, 4, 0, 0, tzinfo=UTC)
    upcoming = reminders.upcoming_reminders(conn, aid, now=now, within_days=1)
    # (the delivery lookback legitimately also selects Aug 3's occurrence — key on the day)
    mine = [r for r in upcoming
            if r.assignment_id == a.id and r.occurs_at.startswith("2026-08-04")]
    assert len(mine) == 1
    assert mine[0].occurs_at == "2026-08-04T17:00:00+00:00"
    assert mine[0].remind_at == "2026-08-04T16:00:00+00:00"


def test_rest_reschedule_roundtrip(client: TestClient) -> None:
    r = client.post("/api/auth/register", json={"username": "owner", "password": "password1"})
    assert r.status_code == 200
    token = client.cookies.get("command_session") or ""
    auth = {"Authorization": f"Bearer {token}"}
    a = client.post(
        "/api/assignments",
        json={"title": "Daily walk", "schedule_kind": "routine", "rrule": "FREQ=DAILY",
              "scheduled_start": "2026-08-03T09:00:00+00:00"},
        headers=auth,
    ).json()
    up = client.post(
        f"/api/assignments/{a['id']}/occurrences/2026-08-05/reschedule",
        json={"occurs_at": "2026-08-05T15:00:00+00:00"},
        headers=auth,
    )
    assert up.status_code == 200, up.text
    cal = client.get(
        "/api/assignments/calendar",
        params={"start": "2026-08-05T00:00:00+00:00", "end": "2026-08-05T23:59:59+00:00"},
        headers=auth,
    ).json()
    target = next(o for o in cal if o["occurrence_date"] == "2026-08-05")
    assert target["occurs_at"] == "2026-08-05T15:00:00+00:00"
    assert target["rescheduled"] is True

    reset = client.delete(
        f"/api/assignments/{a['id']}/occurrences/2026-08-05/reschedule", headers=auth
    )
    assert reset.status_code == 200
    assert reset.json() == {"removed": True}
    cal2 = client.get(
        "/api/assignments/calendar",
        params={"start": "2026-08-05T00:00:00+00:00", "end": "2026-08-05T23:59:59+00:00"},
        headers=auth,
    ).json()
    target2 = next(o for o in cal2 if o["occurrence_date"] == "2026-08-05")
    assert target2["occurs_at"].startswith("2026-08-05T09:00")
    assert target2["rescheduled"] is False
