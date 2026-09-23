"""Activities MCP tools — the fact log + audit rollup.

Activities are "X did Y at time T": logged out-of-the-blue or auto-created when a
plan is marked done. Use `activities_summary` to audit patterns (who does what,
how often). The actor is a delegatee slug; `me` is the operator (see
`command_whoami`). All writes are settings-gated; delete needs a confirm-token.
"""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import activities as activities_core
from ...core import confirm, veil
from .. import permissions
from ._common import run_for_account


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="activities_log",
        description=(
            "Record something that HAPPENED (a fact), e.g. a delegatee did a chore out of the blue, or "
            "you want to keep track of an activity. This is the backward-looking log, distinct from "
            "assignments (the forward plan) — completing an assignment auto-logs its own activity, so "
            "use this for spontaneous/unplanned things. Returns the created activity."
        ),
        annotations=ToolAnnotations(
            title="Log activity",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def activities_log(
        title: str,
        actor: str | None = None,
        occurred_at: str | None = None,
        category: str | None = None,
        details: str | None = None,
        duration_minutes: int | None = None,
        goal_id: int | None = None,
        assignment_id: int | None = None,
        include_hidden: bool = False,
    ) -> dict[str, Any]:
        """`actor`: delegatee slug who did it; defaults to you (`me`). `occurred_at`: ISO-8601
        datetime; defaults to now (back-date for past events). `category`: free-form bucket used
        for audits (keep it consistent, e.g. 'chores', 'errands'). `duration_minutes`: optional
        time spent. `goal_id`/`assignment_id`: optional links (a hidden assignment reads as not
        found unless `include_hidden`)."""

        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "activities", "create")
            if assignment_id is not None:
                veil.require_parent_visible(
                    conn, account_id, "assignment", assignment_id, include_hidden=include_hidden
                )
            activity = activities_core.create(
                conn,
                account_id,
                title=title,
                actor_slug=actor,
                occurred_at=occurred_at,
                category=category,
                details=details,
                duration_minutes=duration_minutes,
                goal_id=goal_id,
                assignment_id=assignment_id,
                source="mcp",
            )
            permissions.audit(
                conn,
                account_id,
                tool="activities_log",
                action="create",
                entity="activity",
                entity_id=activity.id,
                summary=f"{activity.actor_name or 'Me'}: {activity.title}",
            )
            return activity.model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="activities_search",
        description=(
            "Search the activity log, most recent first by when it happened. Filter by `actor` (slug), "
            "`category`, `goal_id`, `assignment_id`, a `query` substring, and a time window "
            "`start`/`end` (ISO-8601), and `include_hidden` (default false; the operator's hidden log "
            "entries stay out unless set true). Cursor-paginated; pass the returned `next_cursor`, null "
            "means end. For totals/patterns prefer activities_summary."
        ),
        annotations=ToolAnnotations(title="Search activities", readOnlyHint=True, openWorldHint=False),
    )
    async def activities_search(
        query: str | None = None,
        actor: str | None = None,
        category: str | None = None,
        goal_id: int | None = None,
        assignment_id: int | None = None,
        source: str | None = None,
        start: str | None = None,
        end: str | None = None,
        include_hidden: bool = False,
        limit: int = 50,
        cursor: str | None = None,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "activities", "read")
            items, nxt = activities_core.search(
                conn,
                account_id,
                query=query,
                actor_slug=actor,
                category=category,
                goal_id=goal_id,
                assignment_id=assignment_id,
                source=source,
                start=start,
                end=end,
                include_hidden=include_hidden,
                limit=limit,
                cursor=cursor,
            )
            return {"items": [a.model_dump() for a in items], "count": len(items), "next_cursor": nxt}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="activities_get",
        description=(
            "Get one activity by id. `include_hidden` (default false) matches activities_list: "
            "the operator's hidden (invisible-ink) log entries stay invisible unless explicitly "
            "asked for, and read as 'no such activity' rather than as a refusal."
        ),
        annotations=ToolAnnotations(title="Get activity", readOnlyHint=True, openWorldHint=False),
    )
    async def activities_get(activity_id: int, include_hidden: bool = False) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "activities", "read")
            return activities_core.get_for_agent(
                conn, account_id, activity_id, include_hidden=include_hidden
            ).model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="activities_summary",
        description=(
            "Audit rollup: counts (+ total minutes) of logged activities, grouped by actor and/or "
            "category over an optional time window. This answers 'what does each person do, and how "
            "much' and 'what does a typical period look like'. Buckets come back busiest-first."
        ),
        annotations=ToolAnnotations(title="Activity summary", readOnlyHint=True, openWorldHint=False),
    )
    async def activities_summary(
        start: str | None = None,
        end: str | None = None,
        actor: str | None = None,
        include_hidden: bool = False,
        group_by: list[str] | None = None,
    ) -> dict[str, Any]:
        """`start`/`end`: ISO-8601 window (omit for all time). `actor`: limit to one delegatee slug.
        `group_by`: any of ['actor','category'] (default both)."""

        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "activities", "read")
            actor_id = None
            if actor is not None:
                from ...core import delegatees as delegatees_core

                actor_id = delegatees_core.get(conn, account_id, slug=actor).id
            dims = tuple(group_by) if group_by else ("actor", "category")
            rows = activities_core.summary(
                conn, account_id, start=start, end=end, actor_id=actor_id,
                include_hidden=include_hidden, group_by=dims,
            )
            return {"buckets": [r.model_dump() for r in rows], "count": len(rows)}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="activities_update",
        description=(
            "Correct a logged activity (re-time it, re-attribute the actor, fix the category/details). "
            "Omitted fields are left unchanged."
        ),
        annotations=ToolAnnotations(
            title="Update activity",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=False,
        ),
    )
    async def activities_update(
        activity_id: int,
        title: str | None = None,
        actor: str | None = None,
        occurred_at: str | None = None,
        category: str | None = None,
        details: str | None = None,
        duration_minutes: int | None = None,
        goal_id: int | None = None,
        include_hidden: bool = False,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "activities", "update")
            # The update echoes the activity back; a hidden one reads as not found.
            activities_core.get_for_agent(
                conn, account_id, activity_id, include_hidden=include_hidden
            )
            activity = activities_core.update(
                conn,
                account_id,
                activity_id,
                title=title,
                actor_slug=actor,
                occurred_at=occurred_at,
                category=category,
                details=details,
                duration_minutes=duration_minutes,
                goal_id=goal_id,
            )
            permissions.audit(
                conn,
                account_id,
                tool="activities_update",
                action="update",
                entity="activity",
                entity_id=activity.id,
                summary=activity.title,
            )
            return activity.model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="activities_delete",
        description=(
            "Delete a logged activity. DESTRUCTIVE: call once without confirm_token to get a plan + "
            "token, show the summary to the operator, then call again with confirm_token to execute."
        ),
        annotations=ToolAnnotations(
            title="Delete activity",
            readOnlyHint=False,
            destructiveHint=True,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def activities_delete(
        activity_id: int, confirm_token: str | None = None, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "activities", "delete")
            # Via `get_for_agent`: the confirm summary below embeds the title, so an ungated
            # fetch would leak a hidden item's title into the model's context even though
            # the veil is supposed to make it invisible.
            target = activities_core.get_for_agent(
                conn, account_id, activity_id, include_hidden=include_hidden
            )
            payload = {"activity_id": activity_id}
            if confirm_token is None:
                token, ttl = confirm.issue(conn, account_id, "activities_delete", payload)
                return {
                    "needs_confirm": True,
                    "confirm_token": token,
                    "expires_in_seconds": ttl,
                    "summary": f"Delete activity '{target.title}' (id {activity_id}).",
                }
            confirm.consume(conn, account_id, "activities_delete", confirm_token, payload)
            removed = activities_core.delete(conn, account_id, activity_id)
            permissions.audit(
                conn,
                account_id,
                tool="activities_delete",
                action="delete",
                entity="activity",
                entity_id=removed.id,
                summary=removed.title,
            )
            return {"deleted": True, "activity": removed.model_dump()}

        return await run_for_account(settings.db_path, work)
