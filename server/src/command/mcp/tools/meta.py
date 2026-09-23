"""command_whoami — orientation tool."""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import accounts as accounts_core
from ...core import delegatees as delegatees_core
from ...core import settings as settings_core
from ._common import run_for_account


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="command_whoami",
        description=(
            "Return the authenticated account, your capabilities, and the current MCP permission "
            "matrix (what you may read/write/delete — the operator controls this in settings). "
            "Call this first to orient; respect the matrix before promising any write."
        ),
        annotations=ToolAnnotations(title="Who am I", readOnlyHint=True, openWorldHint=False),
    )
    async def command_whoami() -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            account = accounts_core.get_account(conn, account_id)
            me = delegatees_core.ensure_self(conn, account_id)
            return {
                "account": {
                    "id": account.id,
                    "username": account.username,
                    "display_name": account.display_name,
                },
                "self_delegatee": {"slug": me.slug, "name": me.name},
                "permissions": settings_core.mcp_permissions(conn, account_id),
                "notes_policy": "Notes are read + create only; they can never be deleted or edited via MCP.",
                "activities_policy": f"Activities are the fact log; '{me.slug}' is the operator as an actor. "
                "Marking an assignment done auto-logs a completion activity.",
                "workflow": "read unprocessed notes -> form goals + assignments -> assign to delegatees "
                "with enough lead time -> mark notes processed -> log/audit activities.",
            }

        return await run_for_account(settings.db_path, work)
