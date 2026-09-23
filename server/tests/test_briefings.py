"""Proactive briefings: preferences, cadence, and the digest itself.

A briefing is only worth sending when it says something. The digest is built
DETERMINISTICALLY from the user's own data (calendar, staleness audit, unprocessed notes) —
no model is involved in deciding *what* is in it. That matters for three reasons: it is
testable without a model, it cannot hallucinate the user's schedule, and an empty day
provably produces no notification rather than a model being paid to say "nothing today".

Preferences default to OFF. Nobody gets an unsolicited push because a release shipped.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import briefings
from command.core import delegatees as D
from command.core import notes as N

T0 = datetime(2026, 8, 3, 8, 0, 0, tzinfo=UTC)  # Monday 08:00 UTC


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


# ---------- preferences ----------

def test_briefings_are_off_by_default(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    prefs = briefings.get_prefs(conn, aid)
    assert prefs.enabled is False, "a release must never start pushing at people unasked"


def test_prefs_round_trip(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 7, "cadence": "weekdays"})
    prefs = briefings.get_prefs(conn, aid)
    assert prefs.enabled is True and prefs.hour_local == 7 and prefs.cadence == "weekdays"


def test_prefs_reject_a_nonsense_hour(conn: sqlite3.Connection) -> None:
    from command.errors import ValidationError

    aid = _acct(conn)
    for bad in (-1, 24, 99):
        try:
            briefings.set_prefs(conn, aid, {"hour_local": bad})
        except ValidationError:
            continue
        raise AssertionError(f"hour_local={bad} should be rejected")


def test_individual_kinds_can_be_switched_off(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "kinds": {"unprocessed_notes": False}})
    prefs = briefings.get_prefs(conn, aid)
    assert prefs.kinds["unprocessed_notes"] is False
    assert prefs.kinds["overdue"] is True, "unlisted kinds keep their default"


# ---------- cadence ----------

def test_disabled_never_sends(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    prefs = briefings.get_prefs(conn, aid)
    assert briefings.is_due(prefs, now=T0, last_sent_at=None, timezone="UTC") is False


def test_due_at_the_configured_hour(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
    prefs = briefings.get_prefs(conn, aid)
    assert briefings.is_due(prefs, now=T0, last_sent_at=None, timezone="UTC") is True


def test_not_due_before_the_configured_hour(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 9})
    prefs = briefings.get_prefs(conn, aid)
    assert briefings.is_due(prefs, now=T0, last_sent_at=None, timezone="UTC") is False


def test_only_one_briefing_per_day(conn: sqlite3.Connection) -> None:
    """The sweep runs every few minutes; without this it would push on every tick."""
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
    prefs = briefings.get_prefs(conn, aid)
    already = T0.replace(hour=8, minute=1).isoformat()
    assert briefings.is_due(prefs, now=T0.replace(hour=8, minute=30),
                            last_sent_at=already, timezone="UTC") is False
    # ...but the next day it is due again.
    assert briefings.is_due(prefs, now=T0.replace(day=4, hour=8),
                            last_sent_at=already, timezone="UTC") is True


def test_weekday_cadence_skips_the_weekend(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8, "cadence": "weekdays"})
    prefs = briefings.get_prefs(conn, aid)
    saturday = datetime(2026, 8, 8, 8, 0, tzinfo=UTC)
    monday = datetime(2026, 8, 10, 8, 0, tzinfo=UTC)
    assert briefings.is_due(prefs, now=saturday, last_sent_at=None, timezone="UTC") is False
    assert briefings.is_due(prefs, now=monday, last_sent_at=None, timezone="UTC") is True


def test_hour_is_interpreted_in_the_users_timezone(conn: sqlite3.Connection) -> None:
    """08:00 local, not 08:00 UTC — a briefing at 4am is a bug, not a feature."""
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
    prefs = briefings.get_prefs(conn, aid)
    # 01:00 UTC is before an 08:00 threshold in UTC, but already 10:00 in Tokyo — inside the
    # catch-up window there, outside the working hours entirely in UTC.
    early_utc = datetime(2026, 8, 3, 1, 0, tzinfo=UTC)
    assert briefings.is_due(prefs, now=early_utc, last_sent_at=None, timezone="UTC") is False
    assert briefings.is_due(prefs, now=early_utc, last_sent_at=None, timezone="Asia/Tokyo") is True
    # And an unknown/absent zone must fall back to UTC rather than blowing up the sweep.
    assert briefings.is_due(prefs, now=early_utc, last_sent_at=None, timezone="Not/AZone") is False
    assert briefings.is_due(prefs, now=early_utc, last_sent_at=None, timezone=None) is False


def test_enabling_a_morning_briefing_at_night_does_not_push_immediately(
    conn: sqlite3.Connection,
) -> None:
    """The failure this guards: someone switches on an 08:00 digest at 22:00, and because
    nothing has ever been sent and 22 >= 8, the next sweep pushes within minutes — at night,
    on the day they opted in. Skipping to tomorrow morning is the only sane reading of
    "send me a briefing at 8am"."""
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
    prefs = briefings.get_prefs(conn, aid)

    night = T0.replace(hour=22, minute=0)
    assert briefings.is_due(prefs, now=night, last_sent_at=None, timezone="UTC") is False
    # Still on time at the hour itself and through the catch-up window...
    assert briefings.is_due(prefs, now=T0.replace(hour=8), last_sent_at=None,
                            timezone="UTC") is True
    assert briefings.is_due(prefs, now=T0.replace(hour=11, minute=59), last_sent_at=None,
                            timezone="UTC") is True
    # ...and stale one hour later, rather than arriving as a stale "morning" briefing.
    assert briefings.is_due(prefs, now=T0.replace(hour=12), last_sent_at=None,
                            timezone="UTC") is False


def test_late_evening_briefing_window_does_not_leak_into_the_next_day(
    conn: sqlite3.Connection,
) -> None:
    """hour_local=22 + a 4h window would run to 02:00 — but that is the NEXT local date, where
    the one-per-day check would count it as tomorrow's briefing. The window must stop at
    midnight, which it does by self-clamping (22 + 4 > 23, so the upper test never fires)."""
    aid = _acct(conn)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 22})
    prefs = briefings.get_prefs(conn, aid)

    assert briefings.is_due(prefs, now=T0.replace(hour=22), last_sent_at=None,
                            timezone="UTC") is True
    assert briefings.is_due(prefs, now=T0.replace(hour=23, minute=59), last_sent_at=None,
                            timezone="UTC") is True
    # 01:00 the next day is before the hour on that day, so it is not due — the evening
    # briefing does not spill over and consume the following day's slot.
    assert briefings.is_due(prefs, now=T0.replace(day=T0.day + 1, hour=1), last_sent_at=None,
                            timezone="UTC") is False


# ---------- the digest ----------

def test_empty_account_produces_nothing_to_say(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.is_empty is True
    assert digest.headline == ""


def test_digest_reports_todays_schedule(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    A.create(conn, aid, title="Dentist",
             scheduled_start="2026-08-03T14:00:00+00:00",
             scheduled_end="2026-08-03T15:00:00+00:00")
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.is_empty is False
    assert [i.title for i in digest.due_today] == ["Dentist"]


def test_due_today_stops_at_the_end_of_the_local_day(conn: sqlite3.Connection) -> None:
    """`due_today` used to be a rolling 24 hours. At an 08:00 briefing that reached 08:00
    tomorrow, so tomorrow's early items were reported as being due today — the field name is
    the promise, and it was not being kept."""
    aid = _acct(conn)
    A.create(conn, aid, title="Tonight", scheduled_start="2026-08-03T23:30:00+00:00")
    A.create(conn, aid, title="Tomorrow early", scheduled_start="2026-08-04T07:00:00+00:00")

    digest = briefings.build_digest(
        conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid), timezone="UTC"
    )
    titles = [i.title for i in digest.due_today]
    assert "Tonight" in titles
    assert "Tomorrow early" not in titles, "a 24h window would have swept this in"


def test_due_today_uses_the_users_local_midnight_not_utc(conn: sqlite3.Connection) -> None:
    """The boundary has to move with the user. At T0 (08:00 UTC) it is already 17:00 in Tokyo,
    so Tokyo's day ends at 15:00 UTC — an item at 20:00 UTC is tomorrow for them even though
    it is still today in UTC."""
    aid = _acct(conn)
    A.create(conn, aid, title="Late UTC evening", scheduled_start="2026-08-03T20:00:00+00:00")

    utc_digest = briefings.build_digest(
        conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid), timezone="UTC"
    )
    tokyo_digest = briefings.build_digest(
        conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid), timezone="Asia/Tokyo"
    )
    assert [i.title for i in utc_digest.due_today] == ["Late UTC evening"]
    assert [i.title for i in tokyo_digest.due_today] == []


def test_digest_reports_overdue_and_blocked_with_the_person(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    sam, _ = D.upsert(conn, aid, name="Sam", kind="human")
    A.create(conn, aid, title="File taxes", assignee_id=sam.id,
             scheduled_start="2026-07-01T09:00:00+00:00")
    A.create(conn, aid, title="Waiting on parts", status="blocked")
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert "File taxes" in [i.title for i in digest.overdue]
    assert "Waiting on parts" in [i.title for i in digest.blocked]
    assert digest.overdue[0].assignee_name == "Sam"


def test_digest_counts_unprocessed_notes(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    N.create(conn, aid, body="idea one")
    N.create(conn, aid, body="idea two")
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.unprocessed_notes == 2


def test_unprocessed_count_is_a_real_count_not_a_page_size(conn: sqlite3.Connection) -> None:
    """Caught on real data: the digest counted `len(search(limit=50))`, so an account with
    200 unprocessed notes was told it had exactly 50. A briefing that states a number has to
    state the true one."""
    aid = _acct(conn)
    for i in range(63):
        N.create(conn, aid, body=f"idea {i}")
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.unprocessed_notes == 63
    assert "63" in digest.headline


def test_unprocessed_count_excludes_hidden_and_archived(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    N.create(conn, aid, body="visible")
    N.create(conn, aid, body="secret", hidden=True)
    archived = N.create(conn, aid, body="old")
    N.set_archived(conn, aid, archived.id, True)
    processed = N.create(conn, aid, body="already handled")
    N.set_processed(conn, aid, processed.id, True)
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.unprocessed_notes == 1


def test_digest_honours_switched_off_kinds(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    N.create(conn, aid, body="idea")
    briefings.set_prefs(conn, aid, {"enabled": True, "kinds": {"unprocessed_notes": False}})
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.unprocessed_notes == 0
    assert digest.is_empty is True, "with its only content switched off there is nothing to send"


def test_digest_excludes_hidden_captures(conn: sqlite3.Connection) -> None:
    """Invisible-ink notes must not leak into a lock-screen notification."""
    aid = _acct(conn)
    N.create(conn, aid, body="secret", hidden=True)
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.unprocessed_notes == 0
    assert digest.is_empty is True


def test_headline_leads_with_the_next_real_thing_not_a_tally(conn: sqlite3.Connection) -> None:
    """A briefing that opens "44 overdue" is a wall, not help. Observed on live data: the
    operator's digest read "1 on today · 44 overdue · 53 notes to triage", which tells you
    you're behind and nothing about what to do. Lead with the concrete next item."""
    aid = _acct(conn)
    A.create(conn, aid, title="Dentist",
             scheduled_start="2026-08-03T14:00:00+00:00",
             scheduled_end="2026-08-03T15:00:00+00:00")
    for i in range(44):
        A.create(conn, aid, title=f"Old thing {i}",
                 scheduled_start="2026-07-01T09:00:00+00:00")
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    # The first thing the user reads is the thing they are about to do.
    assert digest.headline.startswith("Dentist")
    # The backlog is still conveyed, but it does not lead.
    assert "44" in digest.headline


def test_headline_names_the_oldest_overdue_when_nothing_is_scheduled(
    conn: sqlite3.Connection,
) -> None:
    """With an empty day, the most useful thing is the item that has waited longest."""
    aid = _acct(conn)
    A.create(conn, aid, title="File the return", scheduled_start="2026-06-01T09:00:00+00:00")
    A.create(conn, aid, title="Newer thing", scheduled_start="2026-07-25T09:00:00+00:00")
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.headline.startswith("File the return")


def test_headline_falls_back_to_triage_when_there_is_only_a_note_pile(
    conn: sqlite3.Connection,
) -> None:
    aid = _acct(conn)
    for i in range(7):
        N.create(conn, aid, body=f"idea {i}")
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert "7" in digest.headline and "triage" in digest.headline.lower()


def test_digest_produces_a_headline_without_a_model(conn: sqlite3.Connection) -> None:
    """The fallback must stand on its own — if the model is unavailable or the budget is
    spent, the user still gets something true rather than nothing."""
    aid = _acct(conn)
    A.create(conn, aid, title="Dentist", scheduled_start="2026-08-03T14:00:00+00:00",
             scheduled_end="2026-08-03T15:00:00+00:00")
    digest = briefings.build_digest(conn, aid, now=T0, prefs=briefings.get_prefs(conn, aid))
    assert digest.headline
    assert "1" in digest.headline or "Dentist" in digest.headline
