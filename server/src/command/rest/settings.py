"""Settings REST endpoints — the operator-controlled MCP permission matrix.

The getter always returns the *effective* matrix (with the notes-immutable
backstop applied), so even a PUT that tries to enable notes delete/update reads
back as disabled.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel

from ..core import briefings as briefings_core
from ..core import settings as settings_core
from .deps import CurrentAccount, Db

router = APIRouter(prefix="/api/settings", tags=["settings"])


class McpPermissionsUpdate(BaseModel):
    permissions: dict[str, dict[str, bool]]


@router.get("")
def get_settings(account: CurrentAccount, conn: Db) -> dict[str, Any]:
    return {
        "mcp_permissions": settings_core.mcp_permissions(conn, account.id),
        "briefings": briefings_core.get_prefs(conn, account.id).model_dump(),
    }


class BriefingsUpdate(BaseModel):
    """A partial update — unlisted fields, and unlisted kinds, keep their current values."""

    enabled: bool | None = None
    cadence: str | None = None
    hour_local: int | None = None
    kinds: dict[str, bool] | None = None


@router.put("/briefings")
def update_briefings(
    body: BriefingsUpdate, account: CurrentAccount, conn: Db
) -> dict[str, Any]:
    patch = body.model_dump(exclude_none=True)
    return briefings_core.set_prefs(conn, account.id, patch).model_dump()


@router.put("/mcp-permissions")
def update_mcp_permissions(body: McpPermissionsUpdate, account: CurrentAccount, conn: Db) -> dict[str, Any]:
    settings_core.set_value(conn, account.id, settings_core.MCP_PERMISSIONS_KEY, body.permissions)
    return {"mcp_permissions": settings_core.mcp_permissions(conn, account.id)}
