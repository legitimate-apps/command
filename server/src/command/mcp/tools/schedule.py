"""Scheduling MCP tools — free time, collisions, and what has gone quiet.

The same `core/schedule.py` the in-app assistant uses, so both surfaces answer "when am I
free?", "what clashes?" and "what needs chasing?" identically. Read-only: these compute over
assignments and write nothing, so they need only `assignments: read` and no confirm-token.

`assignments_calendar` already returns raw occurrences. These are the questions you would
otherwise have to answer by pulling the whole calendar and reasoning over it — cheaper here,
and correct about the cases that are easy to get wrong by hand (a reminder occupies an
instant but no duration; two things touching end-to-start do not collide).
"""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import accounts as accounts_core
from ...core import clock
from ...core import schedule as schedule_core
from .. import permissions
from ._common import run_for_account

# Hand back a workable slice, not the entire backlog: every row is context the caller pays
# for. `total` still reports the true scale.
DEFAULT_STALE_LIMIT = 15
MAX_STALE_SCAN = 200


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="schedule_find_free_time",
        description=(
            "Find gaps of at least `duration_minutes` in the operator's calendar between `start` "
            "and `end`, soonest first. Use this to pick a time BEFORE creating a scheduled "
            "assignment, instead of guessing a slot that may already be taken. Never returns a "
            "slot in the past. Point-in-time reminders (no end time) do not consume time — only "
            "assignments with an end do. Set `workday_only` to skip Saturday and Sunday. "
            "`start`/`end` are ISO-8601 instants."
        ),
        annotations=ToolAnnotations(
            title="Find free time", readOnlyHint=True, openWorldHint=False
        ),
    )
    async def schedule_find_free_time(
        duration_minutes: int,
        start: str,
        end: str,
        workday_only: bool = False,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "read")
            slots = schedule_core.find_free_time(
                conn, account_id, duration_minutes=duration_minutes,
                start=start, end=end, now=clock.now(), workday_only=workday_only,
                # Whose weekend to skip. Without it the day split happens in UTC.
                timezone=accounts_core.get_timezone(conn, account_id),
            )
            return {"items": [s.model_dump() for s in slots], "count": len(slots)}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="schedule_find_conflicts",
        description=(
            "List pairs of occurrences that overlap in time within the window — the operator's "
            "double-bookings. Use it when asked whether anything clashes, and after scheduling "
            "something to confirm you did not create a collision. Back-to-back items are NOT "
            "conflicts; two reminders at the same instant ARE. The window may span at most 366 "
            "days. `include_hidden` (default false) keeps the operator's hidden assignments — "
            "and their titles — out of the result unless set true."
        ),
        annotations=ToolAnnotations(
            title="Find conflicts", readOnlyHint=True, openWorldHint=False
        ),
    )
    async def schedule_find_conflicts(
        start: str, end: str, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "read")
            found = schedule_core.find_conflicts(
                conn, account_id, start=start, end=end, include_hidden=include_hidden
            )
            return {"items": [c.model_dump() for c in found], "count": len(found)}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="schedule_find_stale",
        description=(
            "Work that has gone quiet: overdue occurrences, blocked items, and anything untouched "
            "for more than `threshold_days`. Each finding names the delegatee responsible and why "
            "it is flagged, most-actionable reason first. This is the tool for 'what needs "
            "chasing?', 'who owes me what?' and 'what has stalled?' — far cheaper and more "
            "accurate than listing everything and judging it yourself. Returns `total` alongside "
            "the first `limit` findings, so you can state the real scale without reading every "
            "row. A recurring assignment whose past occurrences are all done or skipped is up to "
            "date, not overdue. `include_hidden` (default false) keeps the operator's hidden "
            "assignments out unless set true."
        ),
        annotations=ToolAnnotations(
            title="Find stalled work", readOnlyHint=True, openWorldHint=False
        ),
    )
    async def schedule_find_stale(
        threshold_days: int = 7, limit: int = DEFAULT_STALE_LIMIT, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "assignments", "read")
            findings = schedule_core.find_stale_assignments(
                conn, account_id, threshold_days=threshold_days,
                now=clock.now(), limit=MAX_STALE_SCAN, include_hidden=include_hidden,
            )
            shown = findings[: max(1, min(limit, MAX_STALE_SCAN))]
            return {
                "total": len(findings),
                "count": len(shown),
                "items": [f.model_dump() for f in shown],
            }

        return await run_for_account(settings.db_path, work)
