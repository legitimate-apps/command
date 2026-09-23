"""Proactive briefings: what to say, to whom, and when.

The digest is built **deterministically** from the user's own data — calendar, staleness
audit, unprocessed-note count. No model decides what goes in it. That is a correctness
choice as much as a cost one: a briefing that hallucinated your schedule would be worse than
no briefing, and an empty day provably produces no notification instead of paying a model to
say "nothing today".

A model's only job here is optional polish on the headline (see `reminder_job`), and even
that degrades to the deterministic `headline` below rather than blocking the send.

Preferences default to OFF. Shipping a release must never start pushing at people.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta
from typing import Any

from pydantic import BaseModel

from ..errors import ValidationError
from . import assignments as assignments_core
from . import clock
from . import notes as notes_core
from . import schedule as schedule_core
from . import settings as settings_core

BRIEFINGS_KEY = "agent_briefings"

CADENCES = ("daily", "weekdays")

DEFAULT_KINDS: dict[str, bool] = {
    "due_today": True,
    "overdue": True,
    "blocked": True,
    "unprocessed_notes": True,
}

DEFAULT_PREFS: dict[str, Any] = {
    "enabled": False,   # opt-in, always
    "cadence": "daily",
    "hour_local": 8,
    "kinds": dict(DEFAULT_KINDS),
}

# How long after the configured hour a briefing may still go out. The sweep runs every few
# minutes, so this is slack for downtime — not a delivery window anyone should be relying on.
# See `is_due` for the two failures an unbounded window causes.
CATCHUP_HOURS = 4


class BriefingPrefs(BaseModel):
    enabled: bool = False
    cadence: str = "daily"
    hour_local: int = 8
    kinds: dict[str, bool] = DEFAULT_KINDS


class DigestItem(BaseModel):
    assignment_id: int
    title: str
    when: str | None = None
    assignee_name: str | None = None


class Digest(BaseModel):
    due_today: list[DigestItem] = []
    overdue: list[DigestItem] = []
    blocked: list[DigestItem] = []
    unprocessed_notes: int = 0
    headline: str = ""

    @property
    def is_empty(self) -> bool:
        return not (self.due_today or self.overdue or self.blocked or self.unprocessed_notes)


# ---------- preferences ----------


def get_prefs(conn: sqlite3.Connection, account_id: int) -> BriefingPrefs:
    stored = settings_core.get_value(conn, account_id, BRIEFINGS_KEY) or {}
    merged: dict[str, Any] = {**DEFAULT_PREFS, **stored}
    merged["kinds"] = {**DEFAULT_KINDS, **(stored.get("kinds") or {})}
    return BriefingPrefs(**merged)


def set_prefs(conn: sqlite3.Connection, account_id: int, patch: dict[str, Any]) -> BriefingPrefs:
    """Merge a partial update. Unlisted fields (and unlisted kinds) keep their values."""
    current = get_prefs(conn, account_id).model_dump()
    if "hour_local" in patch:
        hour = patch["hour_local"]
        if not isinstance(hour, int) or isinstance(hour, bool) or not 0 <= hour <= 23:
            raise ValidationError(
                "hour_local must be an hour of the day, 0-23.", hint=f"got {hour!r}"
            )
    if "cadence" in patch and patch["cadence"] not in CADENCES:
        raise ValidationError(
            f"cadence must be one of {', '.join(CADENCES)}.", hint=f"got {patch['cadence']!r}"
        )
    kinds = {**current["kinds"], **(patch.get("kinds") or {})}
    merged = {**current, **{k: v for k, v in patch.items() if k != "kinds"}, "kinds": kinds}
    settings_core.set_value(conn, account_id, BRIEFINGS_KEY, merged)
    return BriefingPrefs(**merged)


# ---------- cadence ----------


_zone = clock.zone_or_utc


def is_due(
    prefs: BriefingPrefs, *, now: datetime, last_sent_at: str | None, timezone: str | None
) -> bool:
    """Whether a briefing should go out at this instant.

    The hour is the user's LOCAL hour — 08:00 means their morning, not 08:00 UTC, or people
    east of Greenwich get woken up. At most one per local day, because the reminder sweep
    runs every few minutes and would otherwise push on every tick. And only within
    ``CATCHUP_HOURS`` of the target hour — see below.
    """
    if not prefs.enabled:
        return False
    zone = _zone(timezone)
    local = now.astimezone(zone)
    if prefs.cadence == "weekdays" and local.weekday() >= 5:
        return False
    if local.hour < prefs.hour_local:
        return False
    # A time-of-day digest is only worth sending near its time. Without an upper bound, two
    # things go wrong: switching on an 08:00 briefing at 22:00 pushes IMMEDIATELY (nothing has
    # been sent, and 22 >= 8), so opting into a morning digest wakes you that night; and a
    # sweep that was down all morning delivers "your briefing" at 23:00. Skipping the day is
    # better than either. The window self-clamps to the end of the local day — for
    # hour_local=22 the sum exceeds 23, the test never fires, and it simply runs to midnight
    # rather than leaking into tomorrow, where it would be mistaken for tomorrow's briefing.
    if local.hour >= prefs.hour_local + CATCHUP_HOURS:
        return False
    if last_sent_at:
        try:
            last_local = datetime.fromisoformat(last_sent_at).astimezone(zone)
        except ValueError:
            return True
        if last_local.date() == local.date():
            return False
    return True


# ---------- the digest ----------


def build_digest(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    now: datetime,
    prefs: BriefingPrefs,
    timezone: str | None = None,
) -> Digest:
    """Everything worth telling the user right now, from their own data only.

    Hidden (invisible-ink) captures are excluded throughout — a briefing surfaces on a lock
    screen, which is precisely where the veil is supposed to hold.

    ``timezone`` is the account's zone, and it decides where "today" ends. It defaults to UTC
    so a caller that omits it degrades to the old behaviour rather than raising.
    """
    kinds = prefs.kinds
    digest = Digest()

    if kinds.get("due_today", True):
        # "Today" means the rest of the user's local day — NOT a rolling 24 hours, which is
        # what this used to do. At an 08:00 briefing a 24h window reaches 08:00 tomorrow and
        # files tomorrow's early items under `due_today`; at hour_local=22 it covered almost
        # all of the following day. The name is the contract, so honour it.
        zone = _zone(timezone)
        local_now = now.astimezone(zone)
        day_start = now.astimezone(UTC)
        local_midnight = (local_now + timedelta(days=1)).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        day_end = local_midnight.astimezone(UTC)
        for occ in assignments_core.calendar(
            conn, account_id, day_start.isoformat(), day_end.isoformat(), include_hidden=False
        ):
            if occ.status in schedule_core.INACTIVE_STATUSES:
                continue
            digest.due_today.append(
                DigestItem(assignment_id=occ.assignment_id, title=occ.title, when=occ.occurs_at)
            )

    if kinds.get("overdue", True) or kinds.get("blocked", True):
        # include_hidden=False, explicitly: these titles land on a LOCK SCREEN. The stale scan
        # used to ignore the veil entirely, so a hidden item's title was pushed to the phone.
        for finding in schedule_core.find_stale_assignments(
            conn, account_id, now=now, include_hidden=False
        ):
            item = DigestItem(
                assignment_id=finding.assignment_id,
                title=finding.title,
                when=finding.overdue_since,
                assignee_name=finding.assignee_name,
            )
            if "overdue" in finding.reasons and kinds.get("overdue", True):
                digest.overdue.append(item)
            elif "blocked" in finding.reasons and kinds.get("blocked", True):
                digest.blocked.append(item)

    if kinds.get("unprocessed_notes", True):
        # A real COUNT. This used to be `len(search(limit=50))`, which reported exactly 50 for
        # any account with more than 50 — observed saying "50 notes to triage" on live data.
        digest.unprocessed_notes = notes_core.count(
            conn, account_id, unprocessed=True, include_hidden=False
        )

    digest.headline = _headline(digest)
    return digest


def _headline(digest: Digest) -> str:
    """A true one-liner, no model involved — the floor a polished version improves on.

    LEADS WITH A CONCRETE ITEM, not a tally. A pure count-of-counts ("1 on today · 44 overdue ·
    53 notes to triage" — the real output on live data) tells someone they are behind and
    nothing about what to do, which is the opposite of useful on a lock screen. So: name the
    next scheduled thing, else the item that has waited longest, and let the totals trail
    behind as context.
    """
    if digest.is_empty:
        return ""

    lead = ""
    if digest.due_today:
        first = min(digest.due_today, key=lambda i: i.when or "")
        lead = first.title if not first.when else f"{first.title} at {_clock_time(first.when)}"
    elif digest.overdue:
        # Oldest first — the thing that has been ignored longest is the one worth naming.
        oldest = min(digest.overdue, key=lambda i: i.when or "")
        who = f" ({oldest.assignee_name})" if oldest.assignee_name else ""
        lead = f"{oldest.title}{who} still open"
    elif digest.blocked:
        lead = f"{digest.blocked[0].title} is blocked"

    tail: list[str] = []
    remaining_today = max(0, len(digest.due_today) - 1)
    if remaining_today:
        tail.append(f"+{remaining_today} more today")
    if digest.overdue and not lead.endswith("still open"):
        tail.append(f"{len(digest.overdue)} overdue")
    elif len(digest.overdue) > 1:
        tail.append(f"{len(digest.overdue) - 1} more overdue")
    if digest.blocked and "blocked" not in lead:
        tail.append(f"{len(digest.blocked)} blocked")
    if digest.unprocessed_notes:
        tail.append(f"{digest.unprocessed_notes} to triage")

    if not lead:
        return " · ".join(tail)
    return lead if not tail else f"{lead} · " + " · ".join(tail)


def _clock_time(iso: str) -> str:
    """"14:00" from an ISO instant; the raw string if it won't parse."""
    try:
        return datetime.fromisoformat(iso).strftime("%H:%M")
    except ValueError:
        return iso
