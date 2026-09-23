"""Checklist items for the entity detail pages (assignment / goal / activity).

A single generic endpoint set keyed by (parent_type, parent_id) backs all three detail pages.
Account-scoped via the session; parent ownership is the app's concern (an item only lists under
the parent it was created on, and items are account-scoped so cross-account access 404s).
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query
from pydantic import BaseModel

from ..core import task_items
from .deps import CurrentAccount, Db

router = APIRouter(prefix="/api/items", tags=["items"])


class ItemCreate(BaseModel):
    parent_type: str
    parent_id: int
    text: str


class ItemUpdate(BaseModel):
    text: str | None = None
    done: bool | None = None


class ReorderIn(BaseModel):
    parent_type: str
    parent_id: int
    ordered_ids: list[int]


@router.get("", response_model=list[task_items.TaskItem])
def list_items(
    account: CurrentAccount, conn: Db,
    parent_type: Annotated[str, Query()], parent_id: Annotated[int, Query()],
) -> list[task_items.TaskItem]:
    return task_items.list_items(conn, account.id, parent_type, parent_id)


@router.post("", response_model=task_items.TaskItem, status_code=201)
def add_item(body: ItemCreate, account: CurrentAccount, conn: Db) -> task_items.TaskItem:
    return task_items.add(conn, account.id, body.parent_type, body.parent_id, text=body.text)


@router.patch("/{item_id}", response_model=task_items.TaskItem)
def update_item(item_id: int, body: ItemUpdate, account: CurrentAccount, conn: Db) -> task_items.TaskItem:
    return task_items.update(conn, account.id, item_id, text=body.text, done=body.done)


@router.delete("/{item_id}", status_code=204)
def delete_item(item_id: int, account: CurrentAccount, conn: Db) -> None:
    task_items.delete(conn, account.id, item_id)


@router.post("/reorder", response_model=list[task_items.TaskItem])
def reorder_items(body: ReorderIn, account: CurrentAccount, conn: Db) -> list[task_items.TaskItem]:
    return task_items.reorder(conn, account.id, body.parent_type, body.parent_id, body.ordered_ids)
