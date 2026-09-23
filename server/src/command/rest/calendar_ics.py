"""Calendar export (iCal subscription) + upcoming reminders.

`/api/calendar.ics` is reachable with a stateless per-account token in the query string so an
Apple Calendar subscription (which sends no cookie) can poll it; the app fetches its own
subscribe URL from `/api/calendar/subscription`. `/api/reminders/upcoming` is session-authed.
"""

from __future__ import annotations

from datetime import timedelta
from typing import Annotated

from fastapi import APIRouter, Query, Response

from ..core import assignments as assignments_core
from ..core import calendar_ics, clock
from ..core import reminders as reminders_core
from ..errors import NotFound
from .deps import Config, CurrentAccount, Db

router = APIRouter(tags=["calendar"])

# How far back/ahead the subscribed calendar shows events.
_PAST_DAYS = 30
_FUTURE_DAYS = 365
_DEFAULT_DAYS = reminders_core.DEFAULT_WINDOW_DAYS
_MAX_DAYS = reminders_core.MAX_WINDOW_DAYS


@router.get("/api/calendar/subscription")
def subscription(account: CurrentAccount, settings: Config) -> dict[str, str | None]:
    """The user's personal iCal subscribe URL (or a disabled marker if export isn't configured)."""
    if not settings.calendar_export_secret:
        return {"enabled": "false", "url": None}
    token = calendar_ics.calendar_token(account.id, settings.calendar_export_secret)
    base = (settings.public_base_url or "").rstrip("/")
    return {"enabled": "true", "url": f"{base}/api/calendar.ics?token={token}"}


@router.get("/api/calendar.ics")
def calendar_ics_feed(
    conn: Db,
    settings: Config,
    token: Annotated[str, Query()],
) -> Response:
    if not settings.calendar_export_secret:
        raise NotFound("Calendar export is not enabled.")
    account_id = calendar_ics.verify_calendar_token(token, settings.calendar_export_secret)
    if account_id is None:
        raise NotFound("Invalid calendar token.")
    now = clock.now()
    occurrences = assignments_core.calendar(
        conn, account_id,
        (now - timedelta(days=_PAST_DAYS)).isoformat(),
        (now + timedelta(days=_FUTURE_DAYS)).isoformat(),
        include_hidden=False,   # never export veiled items
    )
    # Occurrences carry no duration; the parents do. Without this every exported event is a
    # flat 30 minutes regardless of what the user actually scheduled.
    parents = assignments_core.parents_for(
        conn, account_id, (o.assignment_id for o in occurrences)
    )
    body = calendar_ics.build_ics(
        occurrences, calendar_name="Command", now=now, parents=parents
    )
    return Response(content=body, media_type="text/calendar; charset=utf-8")


@router.get("/api/reminders/upcoming", response_model=list[reminders_core.Reminder])
def upcoming(
    account: CurrentAccount,
    conn: Db,
    within_days: Annotated[int, Query(ge=1, le=_MAX_DAYS)] = _DEFAULT_DAYS,
) -> list[reminders_core.Reminder]:
    return reminders_core.upcoming_reminders(
        conn, account.id, now=clock.now(), within_days=within_days
    )
