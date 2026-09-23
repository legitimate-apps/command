"""Attachment + checklist MCP tools — the detail hanging off a note or assignment.

Both were reachable from the in-app assistant and from nowhere else, so the operator's own
Claude Code could see that an assignment existed but not what was attached to it or what
steps it had been broken into.

Attachments are read-only over MCP by default (see DEFAULT_MCP_PERMISSIONS): reading a
document the operator attached is the useful case; a remote agent uploading or deleting their
files is not.
"""

from __future__ import annotations

import sqlite3
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from ...config import Settings
from ...core import attachments as attachments_core
from ...core import task_items as task_items_core
from ...core import veil
from .. import permissions
from ._common import run_for_account

# Text formats worth decoding. Anything else is described, not decoded — handing an agent the
# bytes of a JPEG invites a confident summary of nonsense.
READABLE_MIMES = frozenset({
    "application/json", "application/xml", "application/x-yaml", "application/yaml",
    "application/csv", "application/javascript",
})
DEFAULT_MAX_CHARS = 8_000
HARD_MAX_CHARS = 40_000


def register(mcp: FastMCP, settings: Settings) -> None:
    @mcp.tool(
        name="attachments_list",
        description=(
            "List the files attached to a note or assignment. `entity_kind` is 'note' or "
            "'assignment'. Check here when the operator refers to 'the document', 'the photo' "
            "or 'what I attached' — the text of an attachment is often where the real detail is."
        ),
        annotations=ToolAnnotations(
            title="List attachments", readOnlyHint=True, openWorldHint=False
        ),
    )
    async def attachments_list(
        entity_kind: str, entity_id: int, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "attachments", "read")
            # Attachments carry no veil of their own — they inherit the parent's. Without this an
            # agent that cannot read a hidden assignment could still list its filenames.
            veil.require_parent_visible(
                conn, account_id, entity_kind, entity_id, include_hidden=include_hidden
            )
            items = attachments_core.list_for(conn, account_id, entity_kind, entity_id)
            return {"items": [a.model_dump() for a in items], "count": len(items)}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="attachments_read",
        description=(
            "Read a TEXT attachment's contents (plain text, markdown, CSV, JSON and similar). "
            "Binary formats — PDFs, images, archives — are NOT decoded: the tool reports the "
            "type instead, so describe what the file is rather than guessing at its contents. "
            "Long files are truncated to `max_chars`; `truncated` says whether that happened."
        ),
        annotations=ToolAnnotations(
            title="Read attachment", readOnlyHint=True, openWorldHint=False
        ),
    )
    async def attachments_read(
        attachment_id: int, max_chars: int = DEFAULT_MAX_CHARS, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "attachments", "read")
            meta = attachments_core.get(conn, account_id, attachment_id)
            # The file's CONTENTS, so the veil matters more here than anywhere.
            veil.require_parent_visible(
                conn, account_id, meta.entity_kind, meta.entity_id, include_hidden=include_hidden
            )
            path = attachments_core.file_path(conn, account_id, attachment_id)
            if not (meta.mime.startswith("text/") or meta.mime in READABLE_MIMES):
                return {
                    "attachment_id": attachment_id, "filename": meta.filename,
                    "mime": meta.mime, "readable": False,
                    "note": f"{meta.mime} is not text; its contents were not read.",
                }
            cap = max(1, min(max_chars, HARD_MAX_CHARS))
            with open(path, encoding="utf-8", errors="replace") as fh:
                content = fh.read(cap + 1)
            return {
                "attachment_id": attachment_id, "filename": meta.filename, "mime": meta.mime,
                "readable": True, "truncated": len(content) > cap, "content": content[:cap],
            }

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="checklist_list",
        description=(
            "The checklist items on an assignment, goal or activity. `parent_type` is "
            "'assignment', 'goal' or 'activity'. Steps live here rather than as separate assignments, so an "
            "assignment that looks like one job may have several outstanding pieces."
        ),
        annotations=ToolAnnotations(
            title="List checklist", readOnlyHint=True, openWorldHint=False
        ),
    )
    async def checklist_list(
        parent_type: str, parent_id: int, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "task_items", "read")
            veil.require_parent_visible(
                conn, account_id, parent_type, parent_id, include_hidden=include_hidden
            )
            items = task_items_core.list_items(conn, account_id, parent_type, parent_id)
            return {"items": [i.model_dump() for i in items], "count": len(items)}

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="checklist_add",
        description=(
            "Add a checklist item to an assignment, goal or activity. Prefer this over creating several "
            "assignments when one piece of work has steps — it keeps the plan readable and the "
            "steps attached to the thing they belong to."
        ),
        annotations=ToolAnnotations(
            title="Add checklist item", readOnlyHint=False, destructiveHint=False,
            idempotentHint=False, openWorldHint=False,
        ),
    )
    async def checklist_add(
        parent_type: str, parent_id: int, text: str, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "task_items", "create")
            veil.require_parent_visible(
                conn, account_id, parent_type, parent_id, include_hidden=include_hidden
            )
            item = task_items_core.add(
                conn, account_id, parent_type, parent_id, text=text, source="ai"
            )
            return item.model_dump()

        return await run_for_account(settings.db_path, work)

    @mcp.tool(
        name="checklist_set_done",
        description="Tick or untick one checklist item by id. Idempotent.",
        annotations=ToolAnnotations(
            title="Set checklist item done", readOnlyHint=False, destructiveHint=False,
            idempotentHint=True, openWorldHint=False,
        ),
    )
    async def checklist_set_done(
        item_id: int, done: bool = True, include_hidden: bool = False
    ) -> dict[str, Any]:
        def work(conn: sqlite3.Connection, account_id: int) -> dict[str, Any]:
            permissions.require(conn, account_id, "task_items", "update")
            item = task_items_core.get(conn, account_id, item_id)
            veil.require_parent_visible(
                conn, account_id, item.parent_type, item.parent_id, include_hidden=include_hidden
            )
            return task_items_core.update(conn, account_id, item_id, done=done).model_dump()

        return await run_for_account(settings.db_path, work)
