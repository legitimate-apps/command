"""Goals REST endpoints."""

from __future__ import annotations

from fastapi import APIRouter, Query
from pydantic import BaseModel

from ..core import goals as goals_core
from ..core import notes as notes_core
from .common import Page
from .deps import CurrentAccount, Db

router = APIRouter(prefix="/api/goals", tags=["goals"])


class GoalCreate(BaseModel):
    title: str
    description: str | None = None
    status: str = "open"
    target_date: str | None = None


class GoalUpdate(BaseModel):
    title: str | None = None
    description: str | None = None
    status: str | None = None
    target_date: str | None = None
    notes: str | None = None


class LinkNotesIn(BaseModel):
    note_ids: list[int]


@router.get("", response_model=Page[goals_core.Goal])
def list_goals(
    account: CurrentAccount,
    conn: Db,
    status: str | None = Query(None),
    limit: int = Query(100, ge=1, le=200),
    cursor: str | None = Query(None),
) -> Page[goals_core.Goal]:
    items, nxt = goals_core.list_(conn, account.id, status=status, limit=limit, cursor=cursor)
    return Page(items=items, next_cursor=nxt)


@router.post("", response_model=goals_core.Goal, status_code=201)
def create_goal(body: GoalCreate, account: CurrentAccount, conn: Db) -> goals_core.Goal:
    return goals_core.create(
        conn,
        account.id,
        title=body.title,
        description=body.description,
        status=body.status,
        target_date=body.target_date,
    )


@router.get("/search", response_model=list[goals_core.Goal])
def search_goals(
    account: CurrentAccount, conn: Db, q: str = Query(...), limit: int = Query(20, ge=1, le=50)
) -> list[goals_core.Goal]:
    return goals_core.search(conn, account.id, q, limit=limit)


@router.get("/{goal_id}", response_model=goals_core.Goal)
def get_goal(goal_id: int, account: CurrentAccount, conn: Db) -> goals_core.Goal:
    return goals_core.get(conn, account.id, goal_id)


@router.patch("/{goal_id}", response_model=goals_core.Goal)
def update_goal(goal_id: int, body: GoalUpdate, account: CurrentAccount, conn: Db) -> goals_core.Goal:
    # See update_assignment: `exclude_unset` keeps an omitted field UNSET (unchanged) while letting
    # an explicit null clear `target_date`.
    return goals_core.update(conn, account.id, goal_id, **body.model_dump(exclude_unset=True))


@router.delete("/{goal_id}", response_model=goals_core.Goal)
def delete_goal(goal_id: int, account: CurrentAccount, conn: Db) -> goals_core.Goal:
    return goals_core.delete(conn, account.id, goal_id)


@router.post("/{goal_id}/notes")
def link_notes(goal_id: int, body: LinkNotesIn, account: CurrentAccount, conn: Db) -> dict[str, int]:
    return {"linked": goals_core.link_notes(
        conn, account.id, goal_id, body.note_ids, include_hidden=True
    )}


@router.get("/{goal_id}/notes", response_model=list[notes_core.Note])
def goal_notes(goal_id: int, account: CurrentAccount, conn: Db) -> list[notes_core.Note]:
    return goals_core.list_notes(conn, account.id, goal_id, include_hidden=True)
