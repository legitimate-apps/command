"""Assignments — the planner unit: routine (RRULE) or sporadic (one-off).

`calendar()` is the heart: it expands routine RRULEs over a window and overlays
per-occurrence status, returning a flat, time-sorted list the app plots and the
agent reads. `assign()` respects each delegatee's lead time — the reason this app
exists — defaulting an assignment's lead time from its assignee and warning (not
blocking) when work is scheduled inside that window.
"""

from __future__ import annotations

import calendar as _calendar
import heapq
import itertools
import re
import sqlite3
from collections.abc import Iterable, Iterator
from datetime import UTC, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from dateutil.rrule import rrulestr
from pydantic import BaseModel

from ..db import now_iso
from ..errors import NotFound, ValidationError
from . import _cursor, clock
from . import activities as activities_core
from . import delegatees as delegatees_core
from . import goals as goals_core
from ._unset import UNSET, Unset

VALID_KIND = {"routine", "sporadic"}
# `skipped` = a planned thing the assignee didn't do (honest; distinct from
# `cancelled` = we called it off). "Didn't do it" is the absence of an activity.
VALID_STATUS = {"todo", "scheduled", "in_progress", "done", "blocked", "cancelled", "skipped"}
# Statuses where the occurrence is settled and needs nothing further from anyone: it no longer
# occupies the calendar, does not deserve chasing, and must not fire a reminder. `skipped` is in
# here precisely because the user already decided about it — pushing "Reminder: Standup" for an
# occurrence they marked skipped is arguing with them. `blocked` is deliberately NOT here: a
# blocked item is unresolved, and being reminded of it is the point.
INACTIVE_STATUSES = frozenset({"cancelled", "done", "skipped"})
MAX_LIMIT = 200
CALENDAR_MAX_OCCURRENCES = 1000
# Widest [start, end] a calendar read may ask for. Just over a year so the iCal feed's
# 30-days-back + 365-ahead window fits; anything wider is a request for unbounded work.
CALENDAR_MAX_WINDOW_DAYS = 400
# Longest single one-off span (it expands to one occurrence per day).
MAX_SPAN_DAYS = 366
# Upper bound on recurrence instants examined for ONE assignment in ONE expansion, including
# the ones skipped before the window opens. An hourly rule started ten years ago is ~88k; a
# pre-validation legacy MINUTELY row would otherwise be unbounded.
MAX_EXPANSION_STEPS = 100_000
_FREQ_RE = re.compile(r"FREQ=([A-Z]+)")
_REJECTED_FREQS = frozenset({"SECONDLY", "MINUTELY"})


class Assignment(BaseModel):
    id: int
    account_id: int
    goal_id: int | None
    title: str
    details: str | None
    assignee_id: int | None
    schedule_kind: str
    rrule: str | None
    scheduled_start: str | None
    scheduled_end: str | None
    # IANA timezone the assignment was scheduled in (e.g. "America/New_York"). Anchors recurrence
    # expansion to local wall-clock so it survives DST; None = expand in UTC (legacy rows).
    timezone: str | None = None
    lead_time_minutes: int | None
    status: str
    priority: int
    hidden: bool = False  # invisible-ink veil; excluded from agent reads by default
    # Archive is NOT the veil: an archived assignment leaves every default list, the calendar,
    # reminders, iCal, and delegatee views entirely (recoverable via the Archived filter).
    archived_at: str | None = None
    notes: str | None = None    # persistent free-text working area (detail page)
    origin: str | None = None   # provenance: 'manual' | 'agent' | 'note:<id>'
    created_at: str
    updated_at: str


class Occurrence(BaseModel):
    assignment_id: int
    title: str
    occurs_at: str
    status: str
    assignee_id: int | None
    schedule_kind: str
    hidden: bool = False
    # Multi-day span context (a sporadic event whose scheduled_end lands on a later day expands to
    # one occurrence per day). day_index is 1-based; both nil for single-day/recurring occurrences.
    day_index: int | None = None
    day_count: int | None = None
    # The occurrence's identity key — the ORIGINAL expansion date, which status/override/
    # reschedule calls all key on. With an override in play this differs from occurs_at's date,
    # so clients must use THIS, never re-derive the key from occurs_at.
    occurrence_date: str | None = None
    # True when an occurrence_override moved this occurrence off its series time.
    rescheduled: bool = False


def _row(r: sqlite3.Row) -> Assignment:
    return Assignment(**{k: r[k] for k in r.keys()})


def _parse_dt(s: str) -> datetime:
    dt = datetime.fromisoformat(s)
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=UTC)


def _validate_timezone(tz: str | None) -> str | None:
    """Accept a valid IANA zone name (round-tripped through ZoneInfo) or None. Reject garbage early
    so a bad tz can't silently poison every future calendar expansion for the account."""
    if tz is None or tz == "":
        return None
    try:
        ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise ValidationError(
            f"Unknown timezone: {tz!r}.", hint="Use an IANA name, e.g. 'America/New_York'."
        ) from exc
    return tz


def _validate_lead_time(lead_time_minutes: int | None) -> None:
    if lead_time_minutes is not None and lead_time_minutes < 0:
        raise ValidationError("lead_time_minutes cannot be negative.")


def _zone(tz: str | None) -> ZoneInfo | None:
    """The assignment's ZoneInfo, or None to fall back to UTC expansion (legacy rows)."""
    if not tz:
        return None
    try:
        return ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError):
        return None   # tz went missing on the host → degrade to UTC rather than 500


def _anchor(dt: datetime, zone: ZoneInfo | None) -> datetime:
    """Re-express an absolute instant in the assignment's local zone (so recurrence steps preserve
    wall-clock across DST). No zone → leave the instant as-is (UTC-anchored, legacy behavior)."""
    return dt.astimezone(zone) if zone is not None else dt


def _bare_freq(rrule: str, freqs: set[str]) -> bool:
    """True for a plain 'FREQ=MONTHLY'/'FREQ=YEARLY' with no BY*/UNTIL/COUNT/INTERVAL>1 — i.e. the
    app's own recurrence output, where the user means "every month/year" and expects short months
    handled by clamping to month-end, not the RFC-5545 default of silently skipping them."""
    parts = dict(
        p.split("=", 1) for p in rrule.upper().replace(" ", "").split(";") if "=" in p
    )
    if parts.get("FREQ") not in freqs:
        return False
    if parts.get("INTERVAL", "1") != "1":
        return False
    disallowed = {"BYMONTHDAY", "BYDAY", "BYSETPOS", "BYMONTH", "BYYEARDAY", "BYWEEKNO", "COUNT", "UNTIL"}
    return not any(k in parts for k in disallowed)


def _expand_clamped(
    freq: str, dtstart: datetime, window_start: datetime, window_end: datetime,
) -> Iterator[datetime]:
    """Monthly/yearly recurrence that clamps an overflow day (29-31) to the month's last day instead
    of skipping the month — so "monthly on the 31st" fires on Feb 28/29, Apr 30, etc. `dtstart` is
    already anchored in its zone; stepping the wall-clock keeps the local time-of-day across DST.
    A generator, bounded by `guard`: a caller that stops early never pays for the rest."""
    target_day = dtstart.day
    year, month, cur = dtstart.year, dtstart.month, dtstart
    guard = 0
    while cur <= window_end and guard < 4000:
        guard += 1
        if cur >= window_start:
            yield cur
        if freq == "MONTHLY":
            month += 1
            if month > 12:
                month, year = 1, year + 1
        else:  # YEARLY
            year += 1
        day = min(target_day, _calendar.monthrange(year, month)[1])
        cur = cur.replace(year=year, month=month, day=day)


def _validate_rrule(rrule: str, dtstart: str) -> None:
    freq = _FREQ_RE.search(rrule.upper())
    if freq is not None and freq.group(1) in _REJECTED_FREQS:
        # Not a planner cadence, and the one way to make a single row cost millions of
        # occurrences: FREQ=SECONDLY over a four-day window is 345,600 of them.
        raise ValidationError(
            f"FREQ={freq.group(1)} is too fine-grained for a planner recurrence.",
            hint="Use FREQ=HOURLY or coarser (DAILY, WEEKLY, ...), e.g. 'FREQ=HOURLY;INTERVAL=2'.",
        )
    try:
        rrulestr(rrule, dtstart=_parse_dt(dtstart))
    except (ValueError, TypeError) as exc:
        raise ValidationError(f"Invalid rrule: {exc}", hint="e.g. 'FREQ=WEEKLY;BYDAY=MO,WE,FR'") from exc


def _validate_dt(value: str, field: str) -> None:
    """Reject a non-ISO-8601 datetime at the write boundary. Without this a bad
    `scheduled_start`/`scheduled_end` is stored, then `calendar()`'s `_parse_dt` raises
    an uncaught ValueError → 500 that breaks the WHOLE account's calendar until the row
    is deleted (a self-inflicted DoS)."""
    try:
        _parse_dt(value)
    except (ValueError, TypeError) as exc:
        raise ValidationError(
            f"{field} must be an ISO-8601 datetime.", hint="e.g. '2026-07-04T18:00:00Z'."
        ) from exc


def _validate_schedule(
    schedule_kind: str, rrule: str | None, scheduled_start: str | None,
    scheduled_end: str | None = None,
) -> None:
    if schedule_kind not in VALID_KIND:
        raise ValidationError(f"schedule_kind must be one of {sorted(VALID_KIND)}.")
    if schedule_kind == "routine":
        if not rrule:
            raise ValidationError("A routine assignment requires an rrule.")
        if not scheduled_start:
            raise ValidationError("A routine assignment requires scheduled_start (the recurrence start).")
        _validate_rrule(rrule, scheduled_start)  # also parses/validates the start instant
    elif scheduled_start:
        _validate_dt(scheduled_start, "scheduled_start")
    if scheduled_end:
        _validate_dt(scheduled_end, "scheduled_end")
    if schedule_kind == "sporadic" and scheduled_start and scheduled_end:
        # A one-off's span becomes one occurrence per day, so an end in year 9999 is ~2.9M
        # calendar rows for a single assignment. A year covers every real multi-day event.
        span = _parse_dt(scheduled_end) - _parse_dt(scheduled_start)
        if span > timedelta(days=MAX_SPAN_DAYS):
            raise ValidationError(
                f"A one-off assignment may span at most {MAX_SPAN_DAYS} days.",
                hint="For something ongoing, make it a routine with an rrule and use "
                "scheduled_end as the date the recurrence stops.",
            )


def create(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    title: str,
    details: str | None = None,
    goal_id: int | None = None,
    assignee_id: int | None = None,
    schedule_kind: str = "sporadic",
    rrule: str | None = None,
    scheduled_start: str | None = None,
    scheduled_end: str | None = None,
    timezone: str | None = None,
    lead_time_minutes: int | None = None,
    status: str = "todo",
    priority: int = 0,
    hidden: bool = False,
    origin: str | None = "manual",
) -> Assignment:
    title = (title or "").strip()
    if not title:
        raise ValidationError("Assignment title is required.")
    if status not in VALID_STATUS:
        raise ValidationError(f"status must be one of {sorted(VALID_STATUS)}.")
    _validate_schedule(schedule_kind, rrule, scheduled_start, scheduled_end)
    _validate_lead_time(lead_time_minutes)
    timezone = _validate_timezone(timezone)
    if goal_id is not None:
        goals_core.get(conn, account_id, goal_id)
    if assignee_id is not None:
        delegatees_core.get(conn, account_id, delegatee_id=assignee_id)
    ts = now_iso()
    cur = conn.execute(
        "INSERT INTO assignments (account_id, goal_id, title, details, assignee_id, schedule_kind, "
        "rrule, scheduled_start, scheduled_end, timezone, lead_time_minutes, status, priority, "
        "hidden, origin, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            account_id,
            goal_id,
            title,
            details,
            assignee_id,
            schedule_kind,
            rrule,
            scheduled_start,
            scheduled_end,
            timezone,
            lead_time_minutes,
            status,
            priority,
            1 if hidden else 0,
            origin,
            ts,
            ts,
        ),
    )
    return get(conn, account_id, int(cur.lastrowid or 0))


def get(conn: sqlite3.Connection, account_id: int, assignment_id: int) -> Assignment:
    r = conn.execute(
        "SELECT * FROM assignments WHERE id = ? AND account_id = ?", (assignment_id, account_id)
    ).fetchone()
    if r is None:
        raise NotFound(f"No assignment with id {assignment_id}.")
    return _row(r)


def get_for_agent(
    conn: sqlite3.Connection, account_id: int, assignment_id: int, *, include_hidden: bool
) -> Assignment:
    """Read one assignment on behalf of an agent, honouring the invisible-ink veil.

    See `notes.get_for_agent` for the full reasoning. In short: `hidden` is documented on the
    model as "excluded from agent reads by default" and `search`/`calendar` honour it, but `get`
    never did — so a hidden assignment could be read in full by asking for its id, and ids are
    sequential integers. Raises `NotFound` rather than a permission error, because confirming
    that something exists behind the veil is itself the leak.
    """
    assignment = get(conn, account_id, assignment_id)
    if assignment.hidden and not include_hidden:
        raise NotFound(f"No assignment with id {assignment_id}.")
    return assignment


def list_(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    status: str | None = None,
    assignee_id: int | None = None,
    schedule_kind: str | None = None,
    include_hidden: bool = False,
    archived: bool = False,
    limit: int = 100,
    cursor: str | None = None,
) -> tuple[list[Assignment], str | None]:
    """`archived=False` (default) lists live assignments; `archived=True` lists ONLY the
    archive — the two views never mix, matching the iOS Archived filter."""
    limit = max(1, min(limit, MAX_LIMIT))
    where = ["account_id = ?", "archived_at IS NULL" if not archived else "archived_at IS NOT NULL"]
    params: list[Any] = [account_id]
    if status:
        where.append("status = ?")
        params.append(status)
    if assignee_id is not None:
        where.append("assignee_id = ?")
        params.append(assignee_id)
    if schedule_kind:
        where.append("schedule_kind = ?")
        params.append(schedule_kind)
    if not include_hidden:
        where.append("hidden = 0")
    if cursor:
        where.append("id < ?")
        params.append(_cursor.decode_id(cursor))
    sql = f"SELECT * FROM assignments WHERE {' AND '.join(where)} ORDER BY id DESC LIMIT ?"
    params.append(limit + 1)
    rows = conn.execute(sql, params).fetchall()
    items = [_row(r) for r in rows[:limit]]
    next_cursor = _cursor.encode({"id": items[-1].id}) if len(rows) > limit else None
    return items, next_cursor


def search(
    conn: sqlite3.Connection, account_id: int, q: str, *, include_hidden: bool = False, limit: int = 20
) -> list[Assignment]:
    limit = max(1, min(limit, 50))
    like = f"%{q}%"
    hidden_clause = "" if include_hidden else " AND hidden = 0"
    rows = conn.execute(
        "SELECT * FROM assignments WHERE account_id = ? AND (title LIKE ? OR details LIKE ?)"
        f" AND archived_at IS NULL{hidden_clause} ORDER BY id DESC LIMIT ?",
        (account_id, like, like, limit),
    ).fetchall()
    return [_row(r) for r in rows]


def update(
    conn: sqlite3.Connection,
    account_id: int,
    assignment_id: int,
    *,
    title: str | None = None,
    details: str | None = None,
    goal_id: int | Unset | None = UNSET,
    assignee_id: int | Unset | None = UNSET,
    schedule_kind: str | None = None,
    rrule: str | Unset | None = UNSET,
    scheduled_start: str | Unset | None = UNSET,
    scheduled_end: str | Unset | None = UNSET,
    timezone: str | None = None,
    lead_time_minutes: int | Unset | None = UNSET,
    status: str | None = None,
    priority: int | None = None,
    hidden: bool | None = None,
    notes: str | None = None,
) -> Assignment:
    """Update an assignment.

    Nullable columns (`goal_id`, `assignee_id`, `rrule`, `scheduled_start`,
    `scheduled_end`, `lead_time_minutes`) take UNSET = unchanged · None = clear · value =
    set, so they can actually be turned off (unlink from a goal, unassign, unschedule,
    stop repeating, fall back to the assignee's lead time). Everything else keeps
    `None = unchanged`. See `core/_unset.py`.

    `assign()` remains the way to *give* work to someone — it also defaults the lead time
    from the delegatee and returns the lead-time warning. This is the plain field setter,
    and the only way to take an assignee back off (assign() requires a delegatee).
    """
    current = get(conn, account_id, assignment_id)
    # Validate the resulting schedule against the merged state.
    merged_kind = schedule_kind if schedule_kind is not None else current.schedule_kind
    merged_rrule = current.rrule if rrule is UNSET else rrule
    merged_start = current.scheduled_start if scheduled_start is UNSET else scheduled_start
    merged_end = current.scheduled_end if scheduled_end is UNSET else scheduled_end
    _validate_schedule(merged_kind, merged_rrule, merged_start, merged_end)
    if lead_time_minutes is not UNSET:
        _validate_lead_time(lead_time_minutes)
    if status is not None and status not in VALID_STATUS:
        raise ValidationError(f"status must be one of {sorted(VALID_STATUS)}.")
    if isinstance(title, str) and not title.strip():
        raise ValidationError("Assignment title cannot be empty.")
    if timezone is not None:
        timezone = _validate_timezone(timezone)
    if goal_id is not UNSET and goal_id is not None:
        goals_core.get(conn, account_id, goal_id)   # ownership + existence
    if assignee_id is not UNSET and assignee_id is not None:
        delegatees_core.get(conn, account_id, delegatee_id=assignee_id)   # ownership + existence

    sets: list[str] = []
    params: list[Any] = []
    # Non-null columns: None = unchanged.
    fields: dict[str, Any] = {
        "title": title.strip() if isinstance(title, str) else None,
        "details": details,
        "schedule_kind": schedule_kind,
        "timezone": timezone,
        "status": status,
        "priority": priority,
        "hidden": (1 if hidden else 0) if hidden is not None else None,
        "notes": notes,
    }
    for col, val in fields.items():
        if val is not None:
            sets.append(f"{col} = ?")
            params.append(val)
    # Nullable columns: UNSET = unchanged, None = SQL NULL.
    nullable: dict[str, Any] = {
        "goal_id": goal_id,
        "assignee_id": assignee_id,
        "rrule": rrule,
        "scheduled_start": scheduled_start,
        "scheduled_end": scheduled_end,
        "lead_time_minutes": lead_time_minutes,
    }
    for col, val in nullable.items():
        if val is not UNSET:
            sets.append(f"{col} = ?")
            params.append(val)
    if sets:
        sets.append("updated_at = ?")
        params.extend([now_iso(), assignment_id, account_id])
        conn.execute(f"UPDATE assignments SET {', '.join(sets)} WHERE id = ? AND account_id = ?", params)
    return get(conn, account_id, assignment_id)


def assign(
    conn: sqlite3.Connection,
    account_id: int,
    assignment_id: int,
    *,
    assignee_id: int | None = None,
    assignee_slug: str | None = None,
) -> tuple[Assignment, str | None]:
    """Set the assignee. Defaults the assignment's lead time from the delegatee and
    returns a warning (not an error) if it is scheduled inside that lead window."""
    current = get(conn, account_id, assignment_id)
    delegatee = delegatees_core.get(conn, account_id, delegatee_id=assignee_id, slug=assignee_slug)
    lead = current.lead_time_minutes if current.lead_time_minutes is not None else delegatee.lead_time_minutes
    conn.execute(
        "UPDATE assignments SET assignee_id = ?, lead_time_minutes = ?, updated_at = ? "
        "WHERE id = ? AND account_id = ?",
        (delegatee.id, lead, now_iso(), assignment_id, account_id),
    )
    updated = get(conn, account_id, assignment_id)

    warning: str | None = None
    if updated.scheduled_start and delegatee.lead_time_minutes > 0:
        minutes_until = (_parse_dt(updated.scheduled_start) - clock.now()).total_seconds() / 60
        if minutes_until < delegatee.lead_time_minutes:
            warning = (
                f"{delegatee.name} usually needs ~{delegatee.lead_time_minutes} min lead time, "
                f"but this is scheduled in {int(minutes_until)} min."
            )
    return updated, warning


def set_status(conn: sqlite3.Connection, account_id: int, assignment_id: int, status: str) -> Assignment:
    current = get(conn, account_id, assignment_id)
    if status not in VALID_STATUS:
        raise ValidationError(f"status must be one of {sorted(VALID_STATUS)}.")
    conn.execute(
        "UPDATE assignments SET status = ?, updated_at = ? WHERE id = ? AND account_id = ?",
        (status, now_iso(), assignment_id, account_id),
    )
    # Completing a plan logs a fact (deduped) so the audit log stays complete.
    if status == "done" and current.status != "done":
        activities_core.log_completion(
            conn,
            account_id,
            assignment_id=assignment_id,
            title=current.title,
            assignee_id=current.assignee_id,
            goal_id=current.goal_id,
        )
    return get(conn, account_id, assignment_id)


def set_archived(
    conn: sqlite3.Connection, account_id: int, assignment_id: int, archived: bool
) -> Assignment:
    """Archive (or restore) an assignment. Idempotent; archiving twice keeps the first
    timestamp so 'when did this leave my plate' stays truthful."""
    current = get(conn, account_id, assignment_id)
    if archived == (current.archived_at is not None):
        return current
    conn.execute(
        "UPDATE assignments SET archived_at = ?, updated_at = ? WHERE id = ? AND account_id = ?",
        (now_iso() if archived else None, now_iso(), assignment_id, account_id),
    )
    return get(conn, account_id, assignment_id)


def delete(conn: sqlite3.Connection, account_id: int, assignment_id: int) -> Assignment:
    target = get(conn, account_id, assignment_id)
    # Attachment bytes live on disk, so the polymorphic (entity_kind, entity_id) rows can't
    # cascade — clean rows AND files here. Lazy import: attachments imports this module.
    from . import attachments as attachments_core
    from . import task_items as task_items_core

    attachments_core.delete_for_entity(conn, account_id, "assignment", assignment_id)
    # Same polymorphic-parent problem for the checklist: no FK, so nothing cascades.
    task_items_core.delete_for_parent(conn, account_id, "assignment", assignment_id)
    conn.execute("DELETE FROM assignments WHERE id = ? AND account_id = ?", (assignment_id, account_id))
    return target


def _occurrence(
    conn: sqlite3.Connection, a: Assignment, when: datetime,
    *, day_index: int | None = None, day_count: int | None = None,
    override_occurs_at: str | None = None,
) -> Occurrence:
    """Build one occurrence. `when` is always the ORIGINAL expansion instant — its date is the
    identity key — while `override_occurs_at`, when set, supplies the effective display time."""
    key = when.date().isoformat()
    ov = conn.execute(
        "SELECT status FROM occurrence_status WHERE assignment_id = ? AND occurrence_date = ?",
        (a.id, key),
    ).fetchone()
    return Occurrence(
        assignment_id=a.id,
        title=a.title,
        occurs_at=override_occurs_at if override_occurs_at else when.isoformat(),
        status=ov["status"] if ov else a.status,
        assignee_id=a.assignee_id,
        schedule_kind=a.schedule_kind,
        hidden=a.hidden,
        occurrence_date=key,
        rescheduled=override_occurs_at is not None,
        day_index=day_index,
        day_count=day_count,
    )


def _original_instants(
    a: Assignment, start_dt: datetime, end_dt: datetime
) -> Iterator[tuple[datetime, int | None, int | None]]:
    """Yield the assignment's ORIGINAL (series-time) instants within [start_dt, end_dt] as
    `(when, day_index, day_count)` tuples — the expansion logic shared by the calendar and by
    override validation. Overrides are applied by the caller; this never looks at them."""
    zone = _zone(a.timezone)   # None → UTC-anchored (legacy rows), unchanged behavior
    if a.schedule_kind == "sporadic":
        if a.scheduled_start:
            # Anchor in the assignment's zone so a multi-day span is measured in LOCAL days —
            # a short event that only crosses midnight in UTC isn't mislabeled "Day 1 of 2", and
            # each day's occurrence lands on the day the creator meant.
            begin = _anchor(_parse_dt(a.scheduled_start), zone)
            finish = _anchor(_parse_dt(a.scheduled_end), zone) if a.scheduled_end else begin
            span_days = (finish.date() - begin.date()).days
            if span_days >= 1:
                # A first-class multi-day event: one occurrence per day across the span, each
                # tagged Day i of N, clamped to the query window. Start at the day the window
                # opens rather than day 1, so a (legacy, pre-cap) span ending in year 9999
                # costs only the days actually asked for.
                total = span_days + 1
                first = max(0, (start_dt.astimezone(begin.tzinfo).date() - begin.date()).days - 1)
                for i in range(first, total):
                    day_dt = begin + timedelta(days=i)   # wall-clock preserved across DST
                    if day_dt > end_dt:
                        break
                    if start_dt <= day_dt:
                        yield day_dt, i + 1, total
            elif start_dt <= begin <= end_dt:
                yield begin, None, None
    elif a.rrule and a.scheduled_start:
        # Anchor DTSTART in the assignment's zone so recurrence steps preserve local wall-clock
        # (9 AM stays 9 AM) across DST, instead of drifting with a fixed UTC clock-time.
        dtstart = _anchor(_parse_dt(a.scheduled_start), zone)
        # `scheduled_end`, when set, is the recurrence's upper bound — an adjustable end date that
        # works even when the rrule carries no UNTIL/COUNT of its own. Without this clamp a routine
        # like 'FREQ=DAILY' paints an occurrence on every day forever; honoring scheduled_end is
        # what makes "remind me daily for a week" actually stop. Clamp the window to end-of-day in
        # the assignment's zone so a same-day end still yields the final occurrence.
        window_end = end_dt
        if a.scheduled_end:
            se = _anchor(_parse_dt(a.scheduled_end), zone)
            se_eod = se.replace(hour=23, minute=59, second=59)
            if se_eod < window_end:
                window_end = se_eod
        if window_end < start_dt:
            return
        if _bare_freq(a.rrule, {"MONTHLY", "YEARLY"}) and dtstart.day > 28:
            # "Monthly/Yearly on the 29th-31st": clamp short months to their last day rather than
            # skipping them (dateutil's default), so the reminder actually fires every period.
            freq = "MONTHLY" if "MONTHLY" in a.rrule.upper() else "YEARLY"
            for when in _expand_clamped(freq, dtstart, start_dt, window_end):
                yield when, None, None
            return
        try:
            rule = rrulestr(a.rrule, dtstart=dtstart)
        except (ValueError, TypeError):
            return
        # Lazily, not `rule.between()`: that materialises every instant in the window before the
        # caller can stop, and the caller (a time-ordered merge with a result cap) usually wants
        # a handful. The step cap bounds the instants skipped before the window opens as well.
        for when in itertools.islice(rule, MAX_EXPANSION_STEPS):
            if when > window_end:
                break
            if when >= start_dt:
                yield when, None, None


def parents_for(
    conn: sqlite3.Connection, account_id: int, assignment_ids: Iterable[int]
) -> dict[int, Assignment]:
    """The parent assignments for a set of occurrences, keyed by id.

    An `Occurrence` carries `occurs_at` but no duration, so anything that needs to know how
    long an occurrence actually *lasts* has to come back here for the parent's
    `scheduled_start`/`scheduled_end`. Both the free-time search and the iCal export need
    that, and the export not doing it is why every exported event was 30 minutes long.

    One query rather than one per id — `calendar()` can return hundreds of occurrences across
    a handful of parents.
    """
    ids = sorted({int(i) for i in assignment_ids})
    if not ids:
        return {}
    placeholders = ",".join("?" for _ in ids)
    rows = conn.execute(
        f"SELECT * FROM assignments WHERE account_id = ? AND id IN ({placeholders})",
        (account_id, *ids),
    ).fetchall()
    return {int(r["id"]): _row(r) for r in rows}


def occurrence_duration(a: Assignment) -> timedelta:
    """How long ONE occurrence of this assignment occupies. Zero means a point in time.

    Only a one-off carries a real span: its `scheduled_end` is when the event ends. A routine's
    `scheduled_end` is something else entirely — the date the RECURRENCE stops (see
    `_original_instants`, which clamps expansion to it) — so a routine occurrence has no stored
    duration and is a point. Reading a routine's series end as a per-occurrence length is how
    "take meds daily for a week" became seven overlapping week-long busy blocks and a seven-day
    iCal event every day.
    """
    if a.schedule_kind != "sporadic" or not a.scheduled_start or not a.scheduled_end:
        return timedelta(0)
    span = _parse_dt(a.scheduled_end) - _parse_dt(a.scheduled_start)
    return span if span > timedelta(0) else timedelta(0)


def _parse_window(start: str, end: str, *, max_days: int | None) -> tuple[datetime, datetime]:
    """Validate a calendar window at the boundary, so a bad value is a 422, never a 500."""
    try:
        start_dt = _parse_dt(start)
    except (ValueError, TypeError) as exc:
        raise ValidationError(
            "start must be an ISO-8601 datetime.", hint=f"e.g. '2026-08-03T00:00:00Z'; got {start!r}"
        ) from exc
    try:
        end_dt = _parse_dt(end)
    except (ValueError, TypeError) as exc:
        raise ValidationError(
            "end must be an ISO-8601 datetime.", hint=f"e.g. '2026-08-10T00:00:00Z'; got {end!r}"
        ) from exc
    if end_dt < start_dt:
        raise ValidationError("end must be on or after start.")
    if max_days is not None and end_dt - start_dt > timedelta(days=max_days):
        raise ValidationError(
            f"The calendar window may span at most {max_days} days.",
            hint="Narrow start/end and read the next range separately.",
        )
    return start_dt, end_dt


# One expansion instant awaiting the merge: (effective instant, assignment id, original
# instant, day_index, day_count, override occurs_at). The first two are the merge key.
_Pending = tuple[datetime, int, datetime, int | None, int | None, str | None]


def _base_stream(
    a: Assignment, start_dt: datetime, end_dt: datetime, moved: dict[str, str]
) -> Iterator[_Pending]:
    """The assignment's un-overridden occurrences, in time order. An occurrence with a parseable
    override is left to `_moved_stream`, which knows its effective instant."""
    for when, day_index, day_count in _original_instants(a, start_dt, end_dt):
        if when.date().isoformat() in moved:
            continue
        yield when, a.id, when, day_index, day_count, None


def _moved_stream(
    a: Assignment, start_dt: datetime, end_dt: datetime, moved: dict[str, str]
) -> list[_Pending]:
    """Overridden occurrences whose NEW instant falls in the window, sorted. Finite and small
    (one row per rescheduled occurrence), so it is built eagerly. The key must be a genuine
    expansion date: stale overrides (e.g. after an rrule edit) must not resurrect anything."""
    out: list[_Pending] = []
    zone = _zone(a.timezone)
    for key, ov in moved.items():
        effective = _parse_dt(ov)
        if not (start_dt <= effective <= end_dt):
            continue
        d = datetime.fromisoformat(key).date()
        day_anchor = datetime(d.year, d.month, d.day, tzinfo=zone or UTC)
        margin = timedelta(hours=36)   # generous: covers any zone-vs-UTC date skew
        match = next(
            (t for t in _original_instants(a, day_anchor - margin,
                                           day_anchor + timedelta(days=1) + margin)
             if t[0].date().isoformat() == key),
            None,
        )
        if match is not None:
            out.append((effective, a.id, match[0], match[1], match[2], ov))
    out.sort(key=lambda p: (p[0], p[1]))
    return out


def iter_occurrences(
    conn: sqlite3.Connection,
    account_id: int,
    start_dt: datetime,
    end_dt: datetime,
    *,
    include_hidden: bool = False,
    assignee_id: int | None = None,
    assignment_id: int | None = None,
) -> Iterator[Occurrence]:
    """Every occurrence in [start_dt, end_dt], lazily and in true time order across ALL
    assignments. No window cap — internal callers bound their own windows and stop early.

    Time order is what makes a result cap honest. `calendar()` used to expand assignment by
    assignment in table order and stop at 1000, so three old daily routines over a year filled
    the cap and an assignment created after them — next week's meeting — simply vanished from
    the calendar, from free-time search and from reminders. A heap merge of per-assignment
    streams means the cap now cuts off the far future, never the near one.
    """
    where = [
        "account_id = ?", "archived_at IS NULL",
        "(scheduled_start IS NOT NULL OR schedule_kind = 'routine')",
    ]
    params: list[Any] = [account_id]
    if not include_hidden:
        where.append("hidden = 0")
    if assignee_id is not None:
        where.append("assignee_id = ?")
        params.append(assignee_id)
    if assignment_id is not None:
        where.append("id = ?")
        params.append(assignment_id)
    rows = conn.execute(f"SELECT * FROM assignments WHERE {' AND '.join(where)}", params).fetchall()
    override_sql = (
        "SELECT o.assignment_id, o.occurrence_date, o.occurs_at FROM occurrence_overrides o"
        " JOIN assignments a ON a.id = o.assignment_id WHERE a.account_id = ?"
    )
    override_params: list[Any] = [account_id]
    if assignment_id is not None:
        override_sql += " AND a.id = ?"
        override_params.append(assignment_id)
    overrides: dict[int, dict[str, str]] = {}
    for orow in conn.execute(override_sql, override_params).fetchall():
        try:
            # Only a parseable override moves anything; an unparseable one falls back to the
            # series time (it is simply not in the moved map).
            _parse_dt(orow["occurs_at"])
            datetime.fromisoformat(orow["occurrence_date"])
        except (ValueError, TypeError):
            continue
        overrides.setdefault(orow["assignment_id"], {})[orow["occurrence_date"]] = orow["occurs_at"]

    by_id: dict[int, Assignment] = {}
    streams: list[Iterator[_Pending]] = []
    for r in rows:
        a = _row(r)
        # Defense in depth for legacy rows: writes are validated, but a pre-fix row with a
        # malformed scheduled_start/end must not raise below and 500 the whole account's
        # calendar. Skip any row whose datetimes don't parse.
        try:
            if a.scheduled_start:
                _parse_dt(a.scheduled_start)
            if a.scheduled_end:
                _parse_dt(a.scheduled_end)
        except (ValueError, TypeError):
            continue
        by_id[a.id] = a
        moved = overrides.get(a.id, {})
        streams.append(_base_stream(a, start_dt, end_dt, moved))
        if moved:
            streams.append(iter(_moved_stream(a, start_dt, end_dt, moved)))

    for _effective, aid, when, day_index, day_count, ov in heapq.merge(
        *streams, key=lambda p: (p[0], p[1])
    ):
        yield _occurrence(conn, by_id[aid], when, day_index=day_index, day_count=day_count,
                          override_occurs_at=ov)


def calendar_window(
    conn: sqlite3.Connection,
    account_id: int,
    start: str,
    end: str,
    *,
    include_hidden: bool = False,
    assignee_id: int | None = None,
    limit: int = CALENDAR_MAX_OCCURRENCES,
) -> tuple[list[Occurrence], bool]:
    """`calendar()` plus whether it was truncated — i.e. more occurrences exist in the window
    than were returned. The returned ones are always the EARLIEST, so a truncated read is
    complete up to its last occurrence and the caller can page by starting just after it."""
    start_dt, end_dt = _parse_window(start, end, max_days=CALENDAR_MAX_WINDOW_DAYS)
    limit = max(1, min(limit, CALENDAR_MAX_OCCURRENCES))
    taken = list(itertools.islice(
        iter_occurrences(conn, account_id, start_dt, end_dt,
                         include_hidden=include_hidden, assignee_id=assignee_id),
        limit + 1,
    ))
    return taken[:limit], len(taken) > limit


def calendar(
    conn: sqlite3.Connection,
    account_id: int,
    start: str,
    end: str,
    *,
    include_hidden: bool = False,
    assignee_id: int | None = None,
    limit: int = CALENDAR_MAX_OCCURRENCES,
) -> list[Occurrence]:
    """Expand all assignments into concrete occurrences within [start, end], earliest first,
    at most `limit` of them (see `calendar_window` for the truncation flag). The window may span
    at most CALENDAR_MAX_WINDOW_DAYS; malformed or reversed bounds are a ValidationError."""
    occurrences, _ = calendar_window(
        conn, account_id, start, end,
        include_hidden=include_hidden, assignee_id=assignee_id, limit=limit,
    )
    return occurrences


def reschedule_occurrence(
    conn: sqlite3.Connection,
    account_id: int,
    assignment_id: int,
    occurrence_date: str,
    occurs_at: str,
) -> None:
    """Move ONE occurrence of a routine assignment to a new instant without touching the
    series. Sporadic assignments reschedule by editing the assignment itself (`update`)."""
    a = get(conn, account_id, assignment_id)
    if a.schedule_kind != "routine":
        raise ValidationError(
            "Only routine (recurring) assignments take per-occurrence reschedules.",
            hint="For a one-off, update the assignment's scheduled_start instead.",
        )
    try:
        _parse_dt(occurs_at)
    except (ValueError, TypeError) as exc:
        raise ValidationError(f"occurs_at is not an ISO-8601 instant: {occurs_at!r}.") from exc
    if not _is_occurrence_date(a, occurrence_date):
        raise NotFound(f"No occurrence of this assignment on {occurrence_date}.")
    ts = now_iso()
    conn.execute(
        "INSERT INTO occurrence_overrides (assignment_id, occurrence_date, occurs_at,"
        " created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
        " ON CONFLICT(assignment_id, occurrence_date)"
        " DO UPDATE SET occurs_at = excluded.occurs_at, updated_at = excluded.updated_at",
        (assignment_id, occurrence_date, occurs_at, ts, ts),
    )
    conn.execute(
        "UPDATE assignments SET updated_at = ? WHERE id = ?", (ts, assignment_id)
    )


def clear_occurrence_override(
    conn: sqlite3.Connection, account_id: int, assignment_id: int, occurrence_date: str
) -> bool:
    """Reset one occurrence to its series time. Returns False if no override existed."""
    get(conn, account_id, assignment_id)  # ownership
    cur = conn.execute(
        "DELETE FROM occurrence_overrides WHERE assignment_id = ? AND occurrence_date = ?",
        (assignment_id, occurrence_date),
    )
    if cur.rowcount:
        conn.execute(
            "UPDATE assignments SET updated_at = ? WHERE id = ?", (now_iso(), assignment_id)
        )
    return bool(cur.rowcount)


def _is_occurrence_date(a: Assignment, occurrence_date: str) -> bool:
    """Whether the series genuinely expands on that date (in the assignment's zone)."""
    try:
        d = datetime.fromisoformat(occurrence_date).date()
    except (ValueError, TypeError):
        return False
    zone = _zone(a.timezone)
    day_anchor = datetime(d.year, d.month, d.day, tzinfo=zone or UTC)
    margin = timedelta(hours=36)
    return any(
        t[0].date().isoformat() == occurrence_date
        for t in _original_instants(a, day_anchor - margin, day_anchor + timedelta(days=1) + margin)
    )


def set_occurrence_status(
    conn: sqlite3.Connection,
    account_id: int,
    assignment_id: int,
    occurrence_date: str,
    status: str,
    note: str | None = None,
) -> None:
    current = get(conn, account_id, assignment_id)  # ownership
    if status not in VALID_STATUS:
        raise ValidationError(f"status must be one of {sorted(VALID_STATUS)}.")
    prior = conn.execute(
        "SELECT status FROM occurrence_status WHERE assignment_id = ? AND occurrence_date = ?",
        (assignment_id, occurrence_date),
    ).fetchone()
    conn.execute(
        "INSERT INTO occurrence_status (assignment_id, occurrence_date, status, note, updated_at) "
        "VALUES (?, ?, ?, ?, ?) ON CONFLICT(assignment_id, occurrence_date) "
        "DO UPDATE SET status = excluded.status, note = excluded.note, updated_at = excluded.updated_at",
        (assignment_id, occurrence_date, status, note, now_iso()),
    )
    # A routine occurrence marked done logs a fact for that specific date (deduped).
    if status == "done" and (prior is None or prior["status"] != "done"):
        activities_core.log_completion(
            conn,
            account_id,
            assignment_id=assignment_id,
            title=current.title,
            assignee_id=current.assignee_id,
            goal_id=current.goal_id,
            occurrence_date=occurrence_date,
        )
