"""Scheduling intelligence: free-time search, conflict detection, staleness audit.

The three questions the assistant could never answer before, because it could not see the
calendar at all: *when am I free?*, *what collides?*, and *what has gone quiet?*

Pure computations layered over `assignments.calendar()` — no new storage, no new domain
rules. `now` is always an explicit parameter (the `core/reminders.py` pattern) so behaviour
is testable without touching the wall clock.

One distinction runs through all three functions: an assignment with a `scheduled_end` is an
**interval** and occupies time; one with only a `scheduled_start` is a **point in time** (a
reminder — "take meds") and occupies none. A reminder therefore never eats into free time,
but it can still collide with something, which is why free-time search and conflict detection
treat zero-length spans differently rather than sharing one rule.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta, tzinfo

from pydantic import BaseModel

from ..errors import ValidationError
from . import assignments as assignments_core
from . import clock
from . import delegatees as delegatees_core

# Re-exported from `assignments`, which owns the status vocabulary. Kept as a name here because
# callers already reach for `schedule.INACTIVE_STATUSES`.
INACTIVE_STATUSES = assignments_core.INACTIVE_STATUSES

# Cap the expansion window so a pathological range can't fan out unboundedly.
MAX_WINDOW_DAYS = 366


class FreeSlot(BaseModel):
    """A contiguous gap big enough for the requested duration."""

    start: str
    end: str
    minutes: int


class ConflictParty(BaseModel):
    """One side of a collision — enough to name it without a second lookup."""

    assignment_id: int
    title: str
    start: str
    end: str


class Conflict(BaseModel):
    first: ConflictParty
    second: ConflictParty
    overlap_start: str
    overlap_end: str


class StaleAssignment(BaseModel):
    """An assignment that has gone quiet, and why."""

    assignment_id: int
    title: str
    status: str
    reasons: list[str]
    updated_at: str
    assignee_id: int | None = None
    assignee_slug: str | None = None
    assignee_name: str | None = None
    overdue_since: str | None = None


# ---------- shared helpers ----------


def _parse(value: str, *, field: str) -> datetime:
    try:
        dt = datetime.fromisoformat(value)
    except ValueError as exc:
        raise ValidationError(
            f"{field} must be an ISO-8601 timestamp (e.g. 2026-08-03T09:00:00+00:00).",
            hint=f"got {value!r}",
        ) from exc
    return dt.replace(tzinfo=UTC) if dt.tzinfo is None else dt


def _iso(dt: datetime) -> str:
    return dt.astimezone(UTC).isoformat()


class _Busy:
    """One occupied span on the calendar, already clipped to the query window."""

    __slots__ = ("assignment_id", "end", "start", "title")

    def __init__(self, assignment_id: int, title: str, start: datetime, end: datetime) -> None:
        self.assignment_id = assignment_id
        self.title = title
        self.start = start
        self.end = end

    @property
    def is_point(self) -> bool:
        """A reminder rather than an interval — occupies an instant, not a span."""
        return self.start == self.end


def _busy_spans(
    conn: sqlite3.Connection,
    account_id: int,
    window_start: datetime,
    window_end: datetime,
    *,
    include_points: bool,
    include_hidden: bool,
) -> tuple[list[_Busy], datetime]:
    """Every occupied span intersecting the window, oldest first, plus the HORIZON the spans
    are complete up to — `window_end`, unless the calendar read was truncated, in which case
    the last occurrence it returned (nothing beyond it is known, so it must not read as free).

    Occurrence *times* come from `calendar()` so recurrence expansion, per-occurrence
    overrides and reschedules are all inherited rather than re-derived. Durations come from
    the parent assignment (`assignments.occurrence_duration`), because an `Occurrence` carries
    only `occurs_at`.

    `include_hidden` decides whether veiled items take part. Free-time search passes True: a
    hidden meeting still occupies the hour, and the answer ("free 2-3pm") never names it.
    Conflict detection returns TITLES, so its agent-facing callers pass their own opt-in.
    """
    occurrences, truncated = assignments_core.calendar_window(
        conn, account_id, _iso(window_start), _iso(window_end), include_hidden=include_hidden
    )
    if not occurrences:
        return [], window_end
    horizon = _parse(occurrences[-1].occurs_at, field="occurs_at") if truncated else window_end

    parents = assignments_core.parents_for(conn, account_id, (o.assignment_id for o in occurrences))

    spans: list[_Busy] = []
    # A multi-day sporadic event expands to one occurrence PER DAY. Its true span is the
    # parent's single start->end, so collapse those back to one span instead of laying the
    # full duration down on every day and double-booking the calendar.
    multiday_seen: set[int] = set()

    for occ in occurrences:
        parent = parents.get(occ.assignment_id)
        if parent is None or parent.archived_at is not None:
            continue
        if (occ.status or parent.status) in INACTIVE_STATUSES:
            continue

        if occ.day_count and occ.day_count > 1:
            if occ.assignment_id in multiday_seen:
                continue
            multiday_seen.add(occ.assignment_id)
            if not parent.scheduled_start or not parent.scheduled_end:
                continue
            start = _parse(parent.scheduled_start, field="scheduled_start")
            end = _parse(parent.scheduled_end, field="scheduled_end")
        else:
            start = _parse(occ.occurs_at, field="occurs_at")
            end = start + assignments_core.occurrence_duration(parent)

        if not include_points and start == end:
            continue
        # Clip to the window; drop anything that only touches it at a single edge.
        clipped_start = max(start, window_start)
        clipped_end = min(end, window_end)
        if clipped_end < clipped_start:
            continue
        if clipped_start == clipped_end and start != end:
            continue
        spans.append(_Busy(occ.assignment_id, occ.title, clipped_start, clipped_end))

    spans.sort(key=lambda s: (s.start, s.end))
    return spans, horizon


def _merge(spans: list[_Busy]) -> list[tuple[datetime, datetime]]:
    """Union overlapping/touching spans into disjoint occupied intervals."""
    merged: list[tuple[datetime, datetime]] = []
    for span in spans:
        if merged and span.start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], span.end))
        else:
            merged.append((span.start, span.end))
    return merged


def _workday_segments(
    start: datetime, end: datetime, zone: tzinfo
) -> list[tuple[datetime, datetime]]:
    """Split [start, end) into Mon-Fri pieces IN `zone`, dropping weekends entirely.

    The zone is a parameter and not "whatever tzinfo the inputs happen to carry" because that
    is what this used to be, and it made the answer depend on two accidents: which offset the
    caller wrote its timestamps in, and whether the window got clamped to `now` (which is UTC,
    so any window starting in the past — i.e. most of them — silently switched the whole
    calculation to UTC). For anyone west of Greenwich that turns their Friday evening into
    "the weekend" and their Sunday evening into "a weekday".
    """
    segments: list[tuple[datetime, datetime]] = []
    cursor = start
    while cursor < end:
        local = cursor.astimezone(zone)
        # Midnight in the user's zone, converted back — NOT `.replace(hour=0)` on the raw
        # instant, which would land on midnight in whatever zone it was carrying.
        next_midnight = (local + timedelta(days=1)).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        day_end = min(next_midnight.astimezone(cursor.tzinfo), end)
        if local.weekday() < 5:
            segments.append((cursor, day_end))
        cursor = day_end
    # Stitch adjacent weekday pieces back together so Mon->Tue reads as one gap.
    stitched: list[tuple[datetime, datetime]] = []
    for seg in segments:
        if stitched and stitched[-1][1] == seg[0]:
            stitched[-1] = (stitched[-1][0], seg[1])
        else:
            stitched.append(seg)
    return stitched


# ---------- free time ----------


def find_free_time(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    duration_minutes: int,
    start: str,
    end: str,
    now: datetime,
    workday_only: bool = False,
    timezone: str | None = None,
) -> list[FreeSlot]:
    """Gaps of at least `duration_minutes` between `start` and `end`, soonest first.

    The window is clamped to `now` — offering a slot in the past is never useful. Reminders
    (no `scheduled_end`) do not consume time; cancelled/done/archived work does not either.

    `timezone` is the account's zone and only matters when `workday_only` is set: it decides
    whose Saturday is being skipped. It defaults to UTC, which is the old behaviour.
    """
    if duration_minutes <= 0:
        raise ValidationError(
            "duration_minutes must be at least 1.", hint=f"got {duration_minutes}"
        )
    window_start = _parse(start, field="start")
    window_end = _parse(end, field="end")
    if window_end <= window_start:
        raise ValidationError("end must be after start.", hint=f"{start} -> {end}")
    if window_end - window_start > timedelta(days=MAX_WINDOW_DAYS):
        raise ValidationError(
            f"The window may span at most {MAX_WINDOW_DAYS} days.",
            hint="narrow the range and search again",
        )

    window_start = max(window_start, now)
    if window_end <= window_start:
        return []

    need = timedelta(minutes=duration_minutes)
    # Hidden items take part: a veiled appointment still occupies its hour, and a free slot
    # names nothing. Leaving them out would offer the user a time they are already booked.
    spans, horizon = _busy_spans(
        conn, account_id, window_start, window_end, include_points=False, include_hidden=True
    )
    occupied = _merge(spans)
    # Past a truncated calendar read nothing is known, so it must not be offered as free.
    window_end = min(window_end, horizon)
    if window_end <= window_start:
        return []

    candidates = (
        _workday_segments(window_start, window_end, clock.zone_or_utc(timezone))
        if workday_only
        else [(window_start, window_end)]
    )

    slots: list[FreeSlot] = []
    for seg_start, seg_end in candidates:
        cursor = seg_start
        for busy_start, busy_end in occupied:
            if busy_end <= cursor or busy_start >= seg_end:
                continue
            gap_end = min(busy_start, seg_end)
            if gap_end - cursor >= need:
                slots.append(_slot(cursor, gap_end))
            cursor = max(cursor, busy_end)
            if cursor >= seg_end:
                break
        if seg_end - cursor >= need:
            slots.append(_slot(cursor, seg_end))
    return slots


def _slot(start: datetime, end: datetime) -> FreeSlot:
    return FreeSlot(
        start=_iso(start), end=_iso(end), minutes=int((end - start).total_seconds() // 60)
    )


# ---------- conflicts ----------


def find_conflicts(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    start: str,
    end: str,
    include_hidden: bool = False,
) -> list[Conflict]:
    """Pairs of occurrences that overlap in time, soonest first.

    Each party carries its TITLE, so hidden items stay out unless the caller opts in
    (`include_hidden`) — the veil means an agent never learns a hidden item's name from here.

    Back-to-back is not a conflict (one ends exactly as the next begins). Two reminders at
    the same instant ARE — that is the case a naive `<`-only comparison misses, and it is
    precisely the double-booking a person feels. An assignment never conflicts with its own
    other occurrences.
    """
    window_start = _parse(start, field="start")
    window_end = _parse(end, field="end")
    if window_end <= window_start:
        raise ValidationError("end must be after start.", hint=f"{start} -> {end}")
    if window_end - window_start > timedelta(days=MAX_WINDOW_DAYS):
        raise ValidationError(
            f"The window may span at most {MAX_WINDOW_DAYS} days.",
            hint="narrow the range and search again",
        )

    spans, _ = _busy_spans(
        conn, account_id, window_start, window_end,
        include_points=True, include_hidden=include_hidden,
    )
    conflicts: list[Conflict] = []
    for i, a in enumerate(spans):
        for b in spans[i + 1 :]:
            if b.start > a.end:
                break  # sorted by start: nothing later can reach back
            if a.assignment_id == b.assignment_id:
                continue
            overlap_start = max(a.start, b.start)
            overlap_end = min(a.end, b.end)
            if overlap_end < overlap_start:
                continue
            # A zero-length intersection only counts when it is a genuine coincidence of
            # instants, not two intervals merely touching end-to-start.
            if overlap_start == overlap_end and not (a.is_point or b.is_point):
                continue
            conflicts.append(
                Conflict(
                    first=_party(a),
                    second=_party(b),
                    overlap_start=_iso(overlap_start),
                    overlap_end=_iso(overlap_end),
                )
            )
    return conflicts


def _party(span: _Busy) -> ConflictParty:
    return ConflictParty(
        assignment_id=span.assignment_id,
        title=span.title,
        start=_iso(span.start),
        end=_iso(span.end),
    )


# ---------- staleness ----------


def find_stale_assignments(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    threshold_days: int = 7,
    now: datetime,
    limit: int = 100,
    include_hidden: bool = False,
) -> list[StaleAssignment]:
    """Work that has gone quiet: overdue, blocked, or untouched past `threshold_days`.

    This is the follow-through question — "who owes me what, and what has stalled?" — so
    each finding carries the delegatee, and reasons are ordered most-actionable first
    (overdue, then blocked, then merely untouched).

    A recurring assignment is only overdue when a past occurrence was left unactioned;
    one whose every past occurrence is done or skipped is up to date, not overdue. Work that
    is itself settled (`INACTIVE_STATUSES`: done, cancelled, skipped) is never stale — a
    skipped assignment was decided about, not forgotten.

    Findings carry titles, so hidden assignments are excluded unless `include_hidden` — this
    feeds agents and the lock-screen briefing, and both must honour the veil.
    """
    if threshold_days < 0:
        raise ValidationError("threshold_days cannot be negative.", hint=f"got {threshold_days}")
    cutoff = now - timedelta(days=threshold_days)

    settled = sorted(INACTIVE_STATUSES)
    hidden_clause = "" if include_hidden else " AND hidden = 0"
    rows = conn.execute(
        "SELECT * FROM assignments WHERE account_id = ? AND archived_at IS NULL "
        f"AND status NOT IN ({', '.join('?' for _ in settled)}){hidden_clause} ORDER BY id",
        (account_id, *settled),
    ).fetchall()

    roster, _ = delegatees_core.list_(conn, account_id, include_self=True, limit=200)
    people = {d.id: d for d in roster}
    findings: list[StaleAssignment] = []

    for row in rows:
        a = assignments_core._row(row)
        reasons: list[str] = []
        overdue_since = _overdue_since(conn, account_id, a, now=now)
        if overdue_since is not None:
            reasons.append("overdue")
        if a.status == "blocked":
            reasons.append("blocked")
        if _parse(a.updated_at, field="updated_at") <= cutoff:
            reasons.append("untouched")
        if not reasons:
            continue

        person = people.get(a.assignee_id) if a.assignee_id is not None else None
        findings.append(
            StaleAssignment(
                assignment_id=a.id,
                title=a.title,
                status=a.status,
                reasons=reasons,
                updated_at=a.updated_at,
                assignee_id=a.assignee_id,
                assignee_slug=getattr(person, "slug", None),
                assignee_name=getattr(person, "name", None),
                overdue_since=overdue_since,
            )
        )
        if len(findings) >= limit:
            break
    return findings


def _overdue_since(
    conn: sqlite3.Connection,
    account_id: int,
    a: assignments_core.Assignment,
    *,
    now: datetime,
) -> str | None:
    """The earliest unactioned past occurrence, or None when nothing is outstanding.

    Expands THIS assignment only, lazily and in time order, stopping at the first unactioned
    occurrence. It used to expand the whole account from this assignment's first start to now
    — once per assignment, so a stale scan was quadratic — and then filter, which also meant
    the 1000-occurrence cap could be filled by other assignments before this one appeared.
    """
    if not a.scheduled_start:
        return None
    first = _parse(a.scheduled_start, field="scheduled_start")
    if first >= now:
        return None
    for occ in assignments_core.iter_occurrences(
        conn, account_id, first, now, include_hidden=True, assignment_id=a.id
    ):
        if occ.status in INACTIVE_STATUSES:
            continue
        if _parse(occ.occurs_at, field="occurs_at") < now:
            return occ.occurs_at
    return None
