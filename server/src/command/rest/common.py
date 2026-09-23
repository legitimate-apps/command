"""Shared REST response shapes."""

from __future__ import annotations

from pydantic import BaseModel


class Page[T](BaseModel):
    """A page of results plus an opaque cursor for the next page (null at end)."""

    items: list[T]
    next_cursor: str | None = None
