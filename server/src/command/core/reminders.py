"""Upcoming assignment reminders.

For every scheduled occurrence, this computes `remind_at = occurs_at - lead_time`; a missing
lead defaults to zero so an ordinary self-reminder fires at its scheduled instant.

This is the *computation* + an endpoint the app can poll. Pure over `calendar()`.

Delivery is `core/reminder_job.py`, and it is live: APNs is configured and the sweep pushes
every reminder this function returns with `due` set, gated at-most-once by `push.mark_sent`.
That matters when reading the filter below — anything included here becomes a notification on
someone's lock screen, so an occurrence that should stay silent has to be excluded *here*.
(This docstring previously said push delivery "doesn't exist yet", which stopped being true
several releases ago and made the filter look inconsequential.)
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta

from pydantic import BaseModel

from . import assignments as assignments_core

DEFAULT_WINDOW_DAYS = 14
MAX_WINDOW_DAYS = 90
DELIVERY_LOOKBACK = timedelta(days=1)
# How far ahead expansion may reach to find occurrences whose long lead time makes their
# reminder due now. A lead longer than this fires late, by design, rather than unboundedly.
MAX_LEAD_COVER_DAYS = 365


class Reminder(BaseModel):
    assignment_id: int
    title: str
    occurs_at: str
    remind_at: str
    lead_time_minutes: int
    assignee_id: int | None
    due: bool  # remind_at has already passed (a notification would be overdue)


def _parse(iso: str) -> datetime:
    dt = datetime.fromisoformat(iso)
    return dt.replace(tzinfo=UTC) if dt.tzinfo is None else dt


def upcoming_reminders(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    now: datetime,
    within_days: int = DEFAULT_WINDOW_DAYS,
    include_hidden: bool = False,
) -> list[Reminder]:
    within_days = max(1, min(within_days, MAX_WINDOW_DAYS))
    start = now.astimezone(UTC)
    end = start + timedelta(days=within_days)
    leads = {
        row["id"]: row["lead_time_minutes"]
        for row in conn.execute(
            "SELECT id, lead_time_minutes FROM assignments WHERE account_id = ?", (account_id,)
        ).fetchall()
    }
    # A reminder is "within the window" when it FIRES within it, not only when its occurrence
    # does. With a fixed 14-day expansion, an occurrence 20 days out with a 21-day lead was
    # never selected until it came within 14 days — so it fired a week late. Expand far enough
    # to cover the longest lead on the account, bounded so one absurd lead can't ask for an
    # unbounded expansion (MAX_LEAD_COVER_DAYS, inside the calendar's own window cap).
    longest_lead = max((int(v or 0) for v in leads.values()), default=0)
    cover_days = min(MAX_LEAD_COVER_DAYS, max(within_days, -(-longest_lead // (24 * 60))))
    expand_end = start + timedelta(days=cover_days)
    # Include a bounded lookback so a zero-lead occurrence is still selected by the next poll
    # after its exact timestamp (and after a short server outage). `push.mark_sent` remains the
    # at-most-once gate, so already delivered occurrences do not re-fire during this lookback.
    occurrences = assignments_core.calendar(
        conn,
        account_id,
        (start - DELIVERY_LOOKBACK).isoformat(),
        expand_end.isoformat(),
        include_hidden=include_hidden,
    )
    reminders: list[Reminder] = []
    for o in occurrences:
        # `assignments.INACTIVE_STATUSES`, not a hand-written pair. This used to exclude only
        # done/cancelled, so an occurrence the user had explicitly marked SKIPPED still fired a
        # push at its scheduled instant — the delivery job pushes anything `upcoming_reminders`
        # returns with `due`, and nothing downstream re-checked the status.
        if o.status in assignments_core.INACTIVE_STATUSES:
            continue
        lead = int(leads.get(o.assignment_id) or 0)
        occ_at = _parse(o.occurs_at)
        remind_at = occ_at - timedelta(minutes=lead)
        if occ_at > end and remind_at > end:
            continue   # beyond the window on both counts — only expanded to catch long leads
        reminders.append(
            Reminder(
                assignment_id=o.assignment_id,
                title=o.title,
                occurs_at=o.occurs_at,
                remind_at=remind_at.isoformat(),
                lead_time_minutes=lead,
                assignee_id=o.assignee_id,
                due=remind_at <= start,
            )
        )
    reminders.sort(key=lambda r: r.remind_at)
    return reminders
