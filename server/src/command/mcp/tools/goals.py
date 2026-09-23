"""Goals MCP tools."""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import confirm
from ...core import goals as goals_core
from .. import permissions
from ._common import run_for_account


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="goals_search",
        description="Search goals by title/description substring.",
        annotations=ToolAnnotations(title="Search goals", readOnlyHint=True, openWorldHint=False),
    )
    async def goals_search(query: str, limit: int = 20) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "goals", "read")
            items = goals_core.search(conn, account_id, query, limit=limit)
            return {"items": [g.model_dump() for g in items], "count": len(items)}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="goals_get",
        description=(
            "Get a goal by id, including the ids of the notes it was assembled from. "
            "`include_hidden` (default false) leaves the operator's hidden notes out of `note_ids`."
        ),
        annotations=ToolAnnotations(title="Get goal", readOnlyHint=True, openWorldHint=False),
    )
    async def goals_get(goal_id: int, include_hidden: bool = False) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "goals", "read")
            goal = goals_core.get(conn, account_id, goal_id)
            note_ids = [
                n.id
                for n in goals_core.list_notes(
                    conn, account_id, goal_id, include_hidden=include_hidden
                )
            ]
            return {**goal.model_dump(), "note_ids": note_ids}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="goals_create",
        description="Create a goal. status: open|in_progress|done|dropped; target_date optional ISO date.",
        annotations=ToolAnnotations(
            title="Create goal",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def goals_create(
        title: str, description: str | None = None, status: str = "open", target_date: str | None = None
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "goals", "create")
            goal = goals_core.create(
                conn, account_id, title=title, description=description, status=status, target_date=target_date
            )
            permissions.audit(
                conn,
                account_id,
                tool="goals_create",
                action="create",
                entity="goal",
                entity_id=goal.id,
                summary=goal.title,
            )
            return goal.model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="goals_update",
        description="Update a goal's title/description/status/target_date. Omitted fields stay unchanged.",
        annotations=ToolAnnotations(
            title="Update goal",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=False,
        ),
    )
    async def goals_update(
        goal_id: int,
        title: str | None = None,
        description: str | None = None,
        status: str | None = None,
        target_date: str | None = None,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "goals", "update")
            # Preserve this tool's "omitted fields are left unchanged" contract: core reads an
            # explicit None on `target_date` as "clear", and a typed tool signature can't
            # distinguish omitted from null. See mcp/tools/assignments.py:assignments_update.
            updates: dict[str, Any] = {
                key: value
                for key, value in {
                    "title": title,
                    "description": description,
                    "status": status,
                    "target_date": target_date,
                }.items()
                if value is not None
            }
            goal = goals_core.update(conn, account_id, goal_id, **updates)
            permissions.audit(
                conn,
                account_id,
                tool="goals_update",
                action="update",
                entity="goal",
                entity_id=goal.id,
                summary=goal.title,
            )
            return goal.model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="goals_link_notes",
        description=(
            "Record that a goal was assembled from these note ids (provenance). Idempotent. "
            "A hidden note reads as not found unless `include_hidden` is true."
        ),
        annotations=ToolAnnotations(
            title="Link notes to goal",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=False,
        ),
    )
    async def goals_link_notes(
        goal_id: int, note_ids: list[int], include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "goals", "update")
            linked = goals_core.link_notes(
                conn, account_id, goal_id, note_ids, include_hidden=include_hidden
            )
            return {"linked": linked}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="goals_delete",
        description=(
            "Delete a goal. DESTRUCTIVE: call once without confirm_token to get a plan + token, then "
            "again with confirm_token. Assignments under it have their goal link cleared, not deleted."
        ),
        annotations=ToolAnnotations(
            title="Delete goal",
            readOnlyHint=False,
            destructiveHint=True,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def goals_delete(goal_id: int, confirm_token: str | None = None) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "goals", "delete")
            target = goals_core.get(conn, account_id, goal_id)
            payload = {"goal_id": goal_id}
            if confirm_token is None:
                token, ttl = confirm.issue(conn, account_id, "goals_delete", payload)
                return {
                    "needs_confirm": True,
                    "confirm_token": token,
                    "expires_in_seconds": ttl,
                    "summary": f"Delete goal '{target.title}' (id {goal_id}).",
                }
            confirm.consume(conn, account_id, "goals_delete", confirm_token, payload)
            removed = goals_core.delete(conn, account_id, goal_id)
            permissions.audit(
                conn,
                account_id,
                tool="goals_delete",
                action="delete",
                entity="goal",
                entity_id=removed.id,
                summary=removed.title,
            )
            return {"deleted": True, "goal": removed.model_dump()}

        return await run_for_account(settings.db_path, work)
