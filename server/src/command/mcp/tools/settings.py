"""Settings MCP tools — read-only. The permission matrix is operator-controlled
in the app; the agent it governs cannot change it."""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import settings as settings_core
from ._common import run_for_account


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="settings_get",
        description=(
            "Read this account's MCP permission matrix (read/write/delete per entity). "
            "It is operator-controlled in the app; you cannot change it from here."
        ),
        annotations=ToolAnnotations(title="Get settings", readOnlyHint=True, openWorldHint=False),
    )
    async def settings_get() -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            return {"mcp_permissions": settings_core.mcp_permissions(conn, account_id)}

        return await run_for_account(settings.db_path, work)
