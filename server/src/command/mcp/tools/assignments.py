"""Assignments MCP tools."""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import assignments as assignments_core
from ...core import confirm
from .. import permissions
from ._common import run_for_account


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="assignments_search",
        description=(
            "Search assignments by title/details substring. `include_hidden` (default false) keeps the "
            "operator's hidden assignments out of results unless set true."
        ),
        annotations=ToolAnnotations(title="Search assignments", readOnlyHint=True, openWorldHint=False),
    )
    async def assignments_search(query: str, include_hidden: bool = False, limit: int = 20) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "read")
            items = assignments_core.search(
                conn, account_id, query, include_hidden=include_hidden, limit=limit
            )
            return {"items": [a.model_dump() for a in items], "count": len(items)}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="assignments_get",
        description=(
            "Get an assignment by id. `include_hidden` (default false) matches "
            "assignments_search: the operator's hidden (invisible-ink) assignments stay "
            "invisible unless explicitly asked for, and read as 'no such assignment' rather "
            "than as a refusal."
        ),
        annotations=ToolAnnotations(title="Get assignment", readOnlyHint=True, openWorldHint=False),
    )
    async def assignments_get(assignment_id: int, include_hidden: bool = False) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "read")
            return assignments_core.get_for_agent(
                conn, account_id, assignment_id, include_hidden=include_hidden
            ).model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="assignments_calendar",
        description=(
            "Expand all assignments into concrete occurrences within [start, end] (ISO-8601 datetimes), "
            "routine RRULEs expanded and per-occurrence status overlaid. This is what the calendar shows. "
            "`include_hidden` (default false) excludes the operator's hidden assignments unless set true. "
            "The window may span at most 400 days. Occurrences come earliest first, at most 1000; "
            "`truncated: true` means more exist — call again starting from the last `occurs_at`."
        ),
        annotations=ToolAnnotations(title="Calendar", readOnlyHint=True, openWorldHint=False),
    )
    async def assignments_calendar(start: str, end: str, include_hidden: bool = False) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "read")
            occ, truncated = assignments_core.calendar_window(
                conn, account_id, start, end, include_hidden=include_hidden
            )
            return {
                "occurrences": [o.model_dump() for o in occ],
                "count": len(occ),
                "truncated": truncated,
            }

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="assignments_create",
        description=(
            "Create an assignment. schedule_kind 'sporadic' (one-off, set scheduled_start) or 'routine' "
            "(recurring, set rrule like 'FREQ=WEEKLY;BYDAY=MO,WE,FR' AND scheduled_start as the recurrence "
            "start). For a routine, set timezone to the user's IANA zone (e.g. 'America/New_York') so the "
            "recurrence keeps its local wall-clock time across DST. Optionally link a goal_id and set "
            "assignee_id, lead_time_minutes, priority."
        ),
        annotations=ToolAnnotations(
            title="Create assignment",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def assignments_create(
        title: str,
        details: str | None = None,
        goal_id: int | None = None,
        assignee_id: int | None = None,
        schedule_kind: str = "sporadic",
        rrule: str | None = None,
        scheduled_start: str | None = None,
        scheduled_end: str | None = None,
        timezone: str | None = None,
        lead_time_minutes: int | None = None,
        status: str = "todo",
        priority: int = 0,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "create")
            assignment = assignments_core.create(
                conn,
                account_id,
                title=title,
                details=details,
                goal_id=goal_id,
                assignee_id=assignee_id,
                schedule_kind=schedule_kind,
                rrule=rrule,
                scheduled_start=scheduled_start,
                scheduled_end=scheduled_end,
                timezone=timezone,
                lead_time_minutes=lead_time_minutes,
                status=status,
                priority=priority,
            )
            permissions.audit(
                conn,
                account_id,
                tool="assignments_create",
                action="create",
                entity="assignment",
                entity_id=assignment.id,
                summary=assignment.title,
            )
            return assignment.model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="assignments_update",
        description=(
            "Update an assignment's fields. Omitted fields are left unchanged. A hidden assignment "
            "reads as not found unless `include_hidden` is true (same for assign/set_status)."
        ),
        annotations=ToolAnnotations(
            title="Update assignment",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=False,
        ),
    )
    async def assignments_update(
        assignment_id: int,
        title: str | None = None,
        details: str | None = None,
        goal_id: int | None = None,
        schedule_kind: str | None = None,
        rrule: str | None = None,
        scheduled_start: str | None = None,
        scheduled_end: str | None = None,
        timezone: str | None = None,
        lead_time_minutes: int | None = None,
        status: str | None = None,
        priority: int | None = None,
        include_hidden: bool = False,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "update")
            # Writes by id echo the row back — veil them exactly like a read.
            assignments_core.get_for_agent(
                conn, account_id, assignment_id, include_hidden=include_hidden
            )
            # This tool's contract is "omitted fields are left unchanged", and a typed tool
            # signature gives an agent no way to say "explicit null". core's nullable fields now
            # read None as "clear", so drop the Nones here rather than silently wiping every field
            # the agent didn't mention.
            updates: dict[str, Any] = {
                key: value
                for key, value in {
                    "title": title,
                    "details": details,
                    "goal_id": goal_id,
                    "schedule_kind": schedule_kind,
                    "rrule": rrule,
                    "scheduled_start": scheduled_start,
                    "scheduled_end": scheduled_end,
                    "timezone": timezone,
                    "lead_time_minutes": lead_time_minutes,
                    "status": status,
                    "priority": priority,
                }.items()
                if value is not None
            }
            assignment = assignments_core.update(conn, account_id, assignment_id, **updates)
            return assignment.model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="assignments_assign",
        description=(
            "Assign an assignment to a delegatee (by slug or id). Defaults the assignment's lead time "
            "from the delegatee and returns a `lead_time_warning` (string or null) if it's scheduled "
            "inside that delegatee's lead window — surface that warning to the operator."
        ),
        annotations=ToolAnnotations(
            title="Assign",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=False,
        ),
    )
    async def assignments_assign(
        assignment_id: int, assignee_slug: str | None = None, assignee_id: int | None = None,
        include_hidden: bool = False,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "update")
            assignments_core.get_for_agent(
                conn, account_id, assignment_id, include_hidden=include_hidden
            )
            assignment, warning = assignments_core.assign(
                conn, account_id, assignment_id, assignee_id=assignee_id, assignee_slug=assignee_slug
            )
            return {"assignment": assignment.model_dump(), "lead_time_warning": warning}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="assignments_set_status",
        description=(
            "Set an assignment's status (todo|scheduled|in_progress|done|blocked|cancelled|skipped). "
            "Setting 'done' auto-logs a completion activity (deduped); 'skipped' marks it not-done."
        ),
        annotations=ToolAnnotations(
            title="Set assignment status",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=False,
        ),
    )
    async def assignments_set_status(
        assignment_id: int, status: str, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "update")
            assignments_core.get_for_agent(
                conn, account_id, assignment_id, include_hidden=include_hidden
            )
            return assignments_core.set_status(conn, account_id, assignment_id, status).model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="assignments_delete",
        description=(
            "Delete an assignment. DESTRUCTIVE: call once without confirm_token for a plan + token, then "
            "again with confirm_token."
        ),
        annotations=ToolAnnotations(
            title="Delete assignment",
            readOnlyHint=False,
            destructiveHint=True,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def assignments_delete(
        assignment_id: int, confirm_token: str | None = None, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "delete")
            # Via `get_for_agent`: the confirm summary below embeds the title, so an ungated
            # fetch would leak a hidden item's title into the model's context even though
            # the veil is supposed to make it invisible.
            target = assignments_core.get_for_agent(
                conn, account_id, assignment_id, include_hidden=include_hidden
            )
            payload = {"assignment_id": assignment_id}
            if confirm_token is None:
                token, ttl = confirm.issue(conn, account_id, "assignments_delete", payload)
                return {
                    "needs_confirm": True,
                    "confirm_token": token,
                    "expires_in_seconds": ttl,
                    "summary": f"Delete assignment '{target.title}' (id {assignment_id}).",
                }
            confirm.consume(conn, account_id, "assignments_delete", confirm_token, payload)
            removed = assignments_core.delete(conn, account_id, assignment_id)
            permissions.audit(
                conn,
                account_id,
                tool="assignments_delete",
                action="delete",
                entity="assignment",
                entity_id=removed.id,
                summary=removed.title,
            )
            return {"deleted": True, "assignment": removed.model_dump()}

        return await run_for_account(settings.db_path, work)
