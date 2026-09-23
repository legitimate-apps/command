"""Delegatees MCP tools."""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import confirm
from ...core import delegatees as delegatees_core
from .. import permissions
from ._common import run_for_account


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="delegatees_search",
        description="Find delegatees (people or AI models) by name or slug substring.",
        annotations=ToolAnnotations(title="Search delegatees", readOnlyHint=True, openWorldHint=False),
    )
    async def delegatees_search(query: str, limit: int = 20) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "delegatees", "read")
            items = delegatees_core.search(conn, account_id, query, limit=limit)
            return {"items": [d.model_dump() for d in items], "count": len(items)}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="delegatees_list",
        description="List delegatees, newest first. Cursor-paginated; set active_only to skip inactive ones.",
        annotations=ToolAnnotations(title="List delegatees", readOnlyHint=True, openWorldHint=False),
    )
    async def delegatees_list(
        active_only: bool = False, limit: int = 100, cursor: str | None = None
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "delegatees", "read")
            items, nxt = delegatees_core.list_(
                conn, account_id, active_only=active_only, limit=limit, cursor=cursor
            )
            return {"items": [d.model_dump() for d in items], "count": len(items), "next_cursor": nxt}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="delegatees_get",
        description="Get one delegatee by slug.",
        annotations=ToolAnnotations(title="Get delegatee", readOnlyHint=True, openWorldHint=False),
    )
    async def delegatees_get(slug: str) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "delegatees", "read")
            return delegatees_core.get(conn, account_id, slug=slug).model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="delegatees_upsert",
        description=(
            "Create or update a delegatee — idempotent by slug, so it checks existence for you "
            "(no separate check-before-create). Omit `slug` and it is derived from `name`; if a "
            "delegatee with that slug already exists it is UPDATED in place, so calling this twice "
            "with the same name won't create duplicates. To add a genuinely separate person who "
            "shares a name, pass a distinct `slug`. `kind` must be 'human' or 'ai_model'. "
            "`lead_time_minutes` is how much advance notice they need. `metadata` is a free-form "
            "object (personality, contact, model_id, capabilities). On an UPDATE, omitted fields "
            "keep their current values (a deactivated delegatee stays deactivated unless you pass "
            "active=true); on create they default to human / 0 / {} / active. The result's "
            "`created` flag is true for a new delegatee, false for an update."
        ),
        annotations=ToolAnnotations(
            title="Upsert delegatee",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=False,
        ),
    )
    async def delegatees_upsert(
        name: str,
        slug: str | None = None,
        kind: str | None = None,
        lead_time_minutes: int | None = None,
        metadata: dict[str, Any] | None = None,
        active: bool | None = None,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            # Gate on what upsert will actually do: update if the canonical slug (explicit
            # or name-derived) already exists, else create.
            canonical = delegatees_core.slugify(slug or name)
            action = "update" if delegatees_core.exists(conn, account_id, canonical) else "create"
            permissions.require(conn, account_id, "delegatees", action)
            delegatee, created = delegatees_core.upsert(
                conn,
                account_id,
                name=name,
                slug=slug,
                kind=kind,
                lead_time_minutes=lead_time_minutes,
                metadata=metadata,
                active=active,
            )
            permissions.audit(
                conn,
                account_id,
                tool="delegatees_upsert",
                action="create" if created else "update",
                entity="delegatee",
                entity_id=delegatee.id,
                summary=f"{delegatee.name} ({delegatee.slug})",
            )
            return {"delegatee": delegatee.model_dump(), "created": created}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="delegatees_remove",
        description=(
            "Remove a delegatee. DESTRUCTIVE: call once without confirm_token to get a plan + token, "
            "show the summary to the operator, then call again with confirm_token to execute. "
            "Assignments referencing them are unassigned, not deleted."
        ),
        annotations=ToolAnnotations(
            title="Remove delegatee",
            readOnlyHint=False,
            destructiveHint=True,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def delegatees_remove(slug: str, confirm_token: str | None = None) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "delegatees", "delete")
            target = delegatees_core.get(conn, account_id, slug=slug)
            payload = {"slug": slug}
            if confirm_token is None:
                token, ttl = confirm.issue(conn, account_id, "delegatees_remove", payload)
                return {
                    "needs_confirm": True,
                    "confirm_token": token,
                    "expires_in_seconds": ttl,
                    "summary": f"Remove '{target.name}' ({slug}); their assignments get unassigned.",
                }
            confirm.consume(conn, account_id, "delegatees_remove", confirm_token, payload)
            removed = delegatees_core.remove(conn, account_id, slug=slug)
            permissions.audit(
                conn,
                account_id,
                tool="delegatees_remove",
                action="delete",
                entity="delegatee",
                entity_id=removed.id,
                summary=f"removed {removed.name} ({slug})",
            )
            return {"removed": True, "delegatee": removed.model_dump()}

        return await run_for_account(settings.db_path, work)
