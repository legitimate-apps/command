"""Assignments REST endpoints (incl. calendar expansion + lead-time-aware assign)."""

from __future__ import annotations

from fastapi import APIRouter, Query, Response
from pydantic import BaseModel

from ..core import assignments as assignments_core
from .common import Page
from .deps import CurrentAccount, Db

router = APIRouter(prefix="/api/assignments", tags=["assignments"])

# Set on every calendar read: "true" when more occurrences exist than the body carries.
TRUNCATED_HEADER = "X-Calendar-Truncated"


class AssignmentCreate(BaseModel):
    title: str
    details: str | None = None
    goal_id: int | None = None
    assignee_id: int | None = None
    schedule_kind: str = "sporadic"
    rrule: str | None = None
    scheduled_start: str | None = None
    scheduled_end: str | None = None
    timezone: str | None = None   # IANA zone the recurrence is anchored to (DST-correct expansion)
    lead_time_minutes: int | None = None
    status: str = "todo"
    priority: int = 0
    hidden: bool = False


class AssignmentUpdate(BaseModel):
    title: str | None = None
    details: str | None = None
    goal_id: int | None = None
    # Explicit null unassigns. `POST /assign` gives work to someone (and defaults the lead time);
    # it requires a delegatee, so this is the only way to take an assignee back off.
    assignee_id: int | None = None
    schedule_kind: str | None = None
    rrule: str | None = None
    scheduled_start: str | None = None
    scheduled_end: str | None = None
    timezone: str | None = None
    lead_time_minutes: int | None = None
    status: str | None = None
    priority: int | None = None
    hidden: bool | None = None
    notes: str | None = None


class AssignIn(BaseModel):
    assignee_id: int | None = None
    assignee_slug: str | None = None


class StatusIn(BaseModel):
    status: str


class OccurrenceRescheduleIn(BaseModel):
    occurs_at: str


class OccurrenceStatusIn(BaseModel):
    status: str
    note: str | None = None


class AssignResult(BaseModel):
    assignment: assignments_core.Assignment
    lead_time_warning: str | None = None


@router.get("", response_model=Page[assignments_core.Assignment])
def list_assignments(
    account: CurrentAccount,
    conn: Db,
    status: str | None = Query(None),
    assignee_id: int | None = Query(None),
    schedule_kind: str | None = Query(None),
    archived: bool = Query(False, description="true lists ONLY archived assignments"),
    limit: int = Query(100, ge=1, le=200),
    cursor: str | None = Query(None),
) -> Page[assignments_core.Assignment]:
    items, nxt = assignments_core.list_(
        conn,
        account.id,
        status=status,
        assignee_id=assignee_id,
        schedule_kind=schedule_kind,
        archived=archived,
        include_hidden=True,  # the app shows hidden assignments (veiled); only the agent excludes them
        limit=limit,
        cursor=cursor,
    )
    return Page(items=items, next_cursor=nxt)


@router.post("", response_model=assignments_core.Assignment, status_code=201)
def create_assignment(
    body: AssignmentCreate, account: CurrentAccount, conn: Db
) -> assignments_core.Assignment:
    return assignments_core.create(conn, account.id, **body.model_dump())


# Static routes BEFORE the parameterized /{assignment_id} so they aren't captured as an id.
@router.get("/calendar", response_model=list[assignments_core.Occurrence])
def calendar(
    response: Response,
    account: CurrentAccount, conn: Db, start: str = Query(...), end: str = Query(...)
) -> list[assignments_core.Occurrence]:
    """Occurrences in [start, end] (ISO-8601, at most 400 days apart), earliest first, capped
    at 1000. A capped read sets `X-Calendar-Truncated: true`; the body is still the earliest
    occurrences, so the client can fetch the remainder from the last `occurs_at`."""
    occurrences, truncated = assignments_core.calendar_window(
        conn, account.id, start, end, include_hidden=True
    )
    response.headers[TRUNCATED_HEADER] = "true" if truncated else "false"
    return occurrences


@router.get("/search", response_model=list[assignments_core.Assignment])
def search_assignments(
    account: CurrentAccount, conn: Db, q: str = Query(...), limit: int = Query(20, ge=1, le=50)
) -> list[assignments_core.Assignment]:
    return assignments_core.search(conn, account.id, q, include_hidden=True, limit=limit)


@router.get("/{assignment_id}", response_model=assignments_core.Assignment)
def get_assignment(assignment_id: int, account: CurrentAccount, conn: Db) -> assignments_core.Assignment:
    return assignments_core.get(conn, account.id, assignment_id)


@router.patch("/{assignment_id}", response_model=assignments_core.Assignment)
def update_assignment(
    assignment_id: int, body: AssignmentUpdate, account: CurrentAccount, conn: Db
) -> assignments_core.Assignment:
    # `exclude_unset` is load-bearing: only fields the client actually sent are forwarded, so an
    # omitted field stays UNSET (unchanged) while an explicit JSON null reaches core as None and
    # clears the column (unlink a goal, unschedule, reset lead time). Dumping every field would
    # send None for each omitted one — which now means "clear" — and wipe the record.
    return assignments_core.update(conn, account.id, assignment_id, **body.model_dump(exclude_unset=True))


@router.delete("/{assignment_id}", response_model=assignments_core.Assignment)
def delete_assignment(assignment_id: int, account: CurrentAccount, conn: Db) -> assignments_core.Assignment:
    return assignments_core.delete(conn, account.id, assignment_id)


@router.post("/{assignment_id}/assign", response_model=AssignResult)
def assign_assignment(assignment_id: int, body: AssignIn, account: CurrentAccount, conn: Db) -> AssignResult:
    assignment, warning = assignments_core.assign(
        conn, account.id, assignment_id, assignee_id=body.assignee_id, assignee_slug=body.assignee_slug
    )
    return AssignResult(assignment=assignment, lead_time_warning=warning)


@router.post("/{assignment_id}/archive", response_model=assignments_core.Assignment)
def archive_assignment(
    assignment_id: int, account: CurrentAccount, conn: Db
) -> assignments_core.Assignment:
    return assignments_core.set_archived(conn, account.id, assignment_id, True)


@router.post("/{assignment_id}/unarchive", response_model=assignments_core.Assignment)
def unarchive_assignment(
    assignment_id: int, account: CurrentAccount, conn: Db
) -> assignments_core.Assignment:
    return assignments_core.set_archived(conn, account.id, assignment_id, False)


@router.post("/{assignment_id}/status", response_model=assignments_core.Assignment)
def set_assignment_status(
    assignment_id: int, body: StatusIn, account: CurrentAccount, conn: Db
) -> assignments_core.Assignment:
    return assignments_core.set_status(conn, account.id, assignment_id, body.status)


@router.post("/{assignment_id}/occurrences/{occurrence_date}/status")
def set_occurrence_status(
    assignment_id: int,
    occurrence_date: str,
    body: OccurrenceStatusIn,
    account: CurrentAccount,
    conn: Db,
) -> dict[str, bool]:
    assignments_core.set_occurrence_status(
        conn, account.id, assignment_id, occurrence_date, body.status, body.note
    )
    return {"updated": True}


@router.post("/{assignment_id}/occurrences/{occurrence_date}/reschedule")
def reschedule_occurrence(
    assignment_id: int,
    occurrence_date: str,
    body: OccurrenceRescheduleIn,
    account: CurrentAccount,
    conn: Db,
) -> dict[str, bool]:
    """Move ONE occurrence of a routine assignment (the series is untouched)."""
    assignments_core.reschedule_occurrence(
        conn, account.id, assignment_id, occurrence_date, body.occurs_at
    )
    return {"updated": True}


@router.delete("/{assignment_id}/occurrences/{occurrence_date}/reschedule")
def reset_occurrence(
    assignment_id: int, occurrence_date: str, account: CurrentAccount, conn: Db
) -> dict[str, bool]:
    """Reset a rescheduled occurrence back to its series time."""
    removed = assignments_core.clear_occurrence_override(
        conn, account.id, assignment_id, occurrence_date
    )
    return {"removed": removed}
