"""Delegatees REST endpoints."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field

from ..core import delegatee_access
from ..core import delegatees as delegatees_core
from .common import Page
from .deps import CurrentAccount, Db

router = APIRouter(prefix="/api/delegatees", tags=["delegatees"])


class DelegateeUpsert(BaseModel):
    name: str
    slug: str | None = None
    kind: str = "human"
    lead_time_minutes: int = 0
    metadata: dict[str, Any] = Field(default_factory=dict)
    active: bool = True


class UpsertResult(BaseModel):
    delegatee: delegatees_core.Delegatee
    created: bool


class InviteOut(BaseModel):
    invite_token: str
    # Additive: when the code stops working if unused. Codes are also single-use.
    expires_at: str | None = None


@router.get("", response_model=Page[delegatees_core.Delegatee])
def list_delegatees(
    account: CurrentAccount,
    conn: Db,
    active_only: bool = Query(False),
    include_self: bool = Query(False),  # include the hidden "Me" actor (for activity attribution)
    limit: int = Query(100, ge=1, le=200),
    cursor: str | None = Query(None),
) -> Page[delegatees_core.Delegatee]:
    items, nxt = delegatees_core.list_(
        conn, account.id, active_only=active_only, include_self=include_self, limit=limit, cursor=cursor
    )
    return Page(items=items, next_cursor=nxt)


@router.get("/search", response_model=list[delegatees_core.Delegatee])
def search_delegatees(
    account: CurrentAccount, conn: Db, q: str = Query(...), limit: int = Query(20, ge=1, le=50)
) -> list[delegatees_core.Delegatee]:
    return delegatees_core.search(conn, account.id, q, limit=limit)


@router.post("", response_model=UpsertResult)
def upsert_delegatee(body: DelegateeUpsert, account: CurrentAccount, conn: Db) -> UpsertResult:
    # Only the fields the client SENT reach core: an omitted field keeps its stored value on
    # update (and takes core's default on create) instead of being reset to this model's
    # default — which is how an update used to silently re-activate someone.
    sent = body.model_dump(exclude_unset=True)
    delegatee, created = delegatees_core.upsert(
        conn,
        account.id,
        name=body.name,
        slug=body.slug,
        kind=sent.get("kind"),
        lead_time_minutes=sent.get("lead_time_minutes"),
        metadata=sent.get("metadata"),
        active=sent.get("active"),
    )
    return UpsertResult(delegatee=delegatee, created=created)


@router.get("/{delegatee_id}", response_model=delegatees_core.Delegatee)
def get_delegatee(delegatee_id: int, account: CurrentAccount, conn: Db) -> delegatees_core.Delegatee:
    return delegatees_core.get(conn, account.id, delegatee_id=delegatee_id)


@router.post("/{delegatee_id}/invite", response_model=InviteOut)
def create_invite(delegatee_id: int, account: CurrentAccount, conn: Db) -> InviteOut:
    token = delegatee_access.create_invite(conn, account.id, delegatee_id)
    return InviteOut(
        invite_token=token,
        expires_at=delegatee_access.invite_expires_at(conn, account.id, delegatee_id),
    )


@router.delete("/{delegatee_id}/invite", status_code=204)
def revoke_invite(delegatee_id: int, account: CurrentAccount, conn: Db) -> None:
    delegatee_access.revoke_invite(conn, account.id, delegatee_id)


@router.delete("/{delegatee_id}", response_model=delegatees_core.Delegatee)
def delete_delegatee(delegatee_id: int, account: CurrentAccount, conn: Db) -> delegatees_core.Delegatee:
    return delegatees_core.remove(conn, account.id, delegatee_id=delegatee_id)
