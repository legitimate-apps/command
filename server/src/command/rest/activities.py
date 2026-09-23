"""Activities REST endpoints — the fact log + audit summary for the app."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query
from pydantic import BaseModel

from ..core import activities as activities_core
from .common import Page
from .deps import CurrentAccount, Db

router = APIRouter(prefix="/api/activities", tags=["activities"])


class ActivityCreate(BaseModel):
    title: str
    actor_id: int | None = None
    actor_slug: str | None = None
    details: str | None = None
    category: str | None = None
    occurred_at: str | None = None
    duration_minutes: int | None = None
    goal_id: int | None = None
    assignment_id: int | None = None
    occurrence_date: str | None = None
    source: str = "manual"
    hidden: bool = False


class ActivityUpdate(BaseModel):
    title: str | None = None
    actor_id: int | None = None
    actor_slug: str | None = None
    details: str | None = None
    category: str | None = None
    occurred_at: str | None = None
    duration_minutes: int | None = None
    goal_id: int | None = None
    hidden: bool | None = None


@router.get("", response_model=Page[activities_core.Activity])
def list_activities(
    account: CurrentAccount,
    conn: Db,
    query: str | None = Query(None),
    actor_id: int | None = Query(None),
    category: str | None = Query(None),
    goal_id: int | None = Query(None),
    assignment_id: int | None = Query(None),
    source: str | None = Query(None),
    start: str | None = Query(None),
    end: str | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = Query(None),
) -> Page[activities_core.Activity]:
    items, nxt = activities_core.search(
        conn,
        account.id,
        query=query,
        actor_id=actor_id,
        category=category,
        goal_id=goal_id,
        assignment_id=assignment_id,
        source=source,
        start=start,
        end=end,
        include_hidden=True,  # the app shows hidden logs (veiled); only the agent excludes them
        limit=limit,
        cursor=cursor,
    )
    return Page(items=items, next_cursor=nxt)


@router.post("", response_model=activities_core.Activity, status_code=201)
def create_activity(body: ActivityCreate, account: CurrentAccount, conn: Db) -> activities_core.Activity:
    return activities_core.create(conn, account.id, **body.model_dump())


# Static route BEFORE /{activity_id} so it isn't captured as an id.
@router.get("/summary", response_model=list[activities_core.ActivitySummaryRow])
def activity_summary(
    account: CurrentAccount,
    conn: Db,
    start: str | None = Query(None),
    end: str | None = Query(None),
    actor_id: int | None = Query(None),
    group_by: Annotated[list[str] | None, Query()] = None,
) -> list[activities_core.ActivitySummaryRow]:
    return activities_core.summary(
        conn,
        account.id,
        start=start,
        end=end,
        actor_id=actor_id,
        include_hidden=True,  # app's own audit rollup includes hidden; the agent's excludes
        group_by=tuple(group_by) if group_by else ("actor", "category"),
    )


@router.get("/{activity_id}", response_model=activities_core.Activity)
def get_activity(activity_id: int, account: CurrentAccount, conn: Db) -> activities_core.Activity:
    return activities_core.get(conn, account.id, activity_id)


@router.patch("/{activity_id}", response_model=activities_core.Activity)
def update_activity(
    activity_id: int, body: ActivityUpdate, account: CurrentAccount, conn: Db
) -> activities_core.Activity:
    return activities_core.update(conn, account.id, activity_id, **body.model_dump())


@router.delete("/{activity_id}", response_model=activities_core.Activity)
def delete_activity(activity_id: int, account: CurrentAccount, conn: Db) -> activities_core.Activity:
    return activities_core.delete(conn, account.id, activity_id)
