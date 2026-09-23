"""Notes MCP tools — read + create + mark-processed. No delete/edit (Hard Rule 1)."""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import notes as notes_core
from .. import permissions
from ._common import run_for_account


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="notes_search",
        description=(
            "Search this account's captured notes, newest first. Filter with `query` (substring), "
            "`unprocessed=true` (not yet turned into goals — the usual starting point), `source` "
            "('typed'|'voice'), `include_archived`, and `include_hidden` (default false — the "
            "operator's invisible-ink/hidden notes stay out of results unless you set it true). "
            "Cursor-paginated: pass the returned `next_cursor` to page; a null cursor means no more results. "
            "`matched: false` means the query matched nothing; `recent_notes` then holds the newest "
            "notes (not matches) so you can check for differently-worded ones."
        ),
        annotations=ToolAnnotations(title="Search notes", readOnlyHint=True, openWorldHint=False),
    )
    async def notes_search(
        query: str | None = None,
        unprocessed: bool | None = None,
        source: str | None = None,
        include_archived: bool = False,
        include_hidden: bool = False,
        limit: int = 50,
        cursor: str | None = None,
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "notes", "read")
            found = notes_core.search_with_fallback(
                conn,
                account_id,
                query=query,
                unprocessed=unprocessed,
                source=source,
                include_archived=include_archived,
                include_hidden=include_hidden,
                limit=limit,
                cursor=cursor,
            )
            out: dict[str, Any] = {
                "items": [n.model_dump() for n in found.items],
                "count": len(found.items),
                "next_cursor": found.next_cursor,
                "matched": found.matched,
            }
            if not found.matched:
                # Labelled, never mixed into `items`: the newest notes, for you to inspect.
                out["recent_notes"] = [n.model_dump() for n in found.recent]
            return out

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="notes_get",
        description=(
            "Fetch a single note by id. `include_hidden` (default false) matches notes_search: "
            "the operator's hidden (invisible-ink) notes stay invisible unless explicitly asked "
            "for, and a hidden note reads as 'no such note' rather than as a refusal."
        ),
        annotations=ToolAnnotations(title="Get note", readOnlyHint=True, openWorldHint=False),
    )
    async def notes_get(note_id: int, include_hidden: bool = False) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "notes", "read")
            return notes_core.get_for_agent(
                conn, account_id, note_id, include_hidden=include_hidden
            ).model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="notes_create",
        description=(
            "Create a note for this account (e.g. to capture a decision reached with the operator). "
            "Additive only; notes are never deletable via MCP."
        ),
        annotations=ToolAnnotations(
            title="Create note",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def notes_create(body: str, source: str = "typed") -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "notes", "create")
            note = notes_core.create(conn, account_id, body, source=source)
            permissions.audit(
                conn,
                account_id,
                tool="notes_create",
                action="create",
                entity="note",
                entity_id=note.id,
                summary=note.body[:80],
            )
            return note.model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="notes_mark_processed",
        description=(
            "Flag a note as processed (turned into goals) or not. Reversible workflow marker, not a "
            "content edit — use it after you've assembled goals/assignments from a note. A hidden "
            "note reads as not found unless `include_hidden` is true."
        ),
        annotations=ToolAnnotations(
            title="Mark note processed",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=False,
        ),
    )
    async def notes_mark_processed(
        note_id: int, processed: bool = True, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            # `process` is a reversible workflow flag (processed_at), not a body edit, so it
            # sits outside the forbidden notes update/delete actions — but it is still
            # settings-gated so the operator governs every MCP mutation.
            permissions.require(conn, account_id, "notes", "process")
            # The write echoes the whole note back, so it goes through the same veil as a read.
            notes_core.get_for_agent(conn, account_id, note_id, include_hidden=include_hidden)
            note = notes_core.set_processed(conn, account_id, note_id, processed)
            permissions.audit(
                conn,
                account_id,
                tool="notes_mark_processed",
                action="process",
                entity="note",
                entity_id=note.id,
                summary=f"marked note {note.id} processed={processed}",
            )
            return note.model_dump()

        return await run_for_account(settings.db_path, work)
