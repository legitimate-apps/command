"""Attachments + checklists on MCP, and the permission defaults that govern them.

Two things worth pinning beyond "the tools exist":

1. The new permission entities must reach EXISTING accounts. `mcp_permissions` merges stored
   settings over the defaults, so they do — but if that merge ever inverted, every account
   created before this change would silently lose the new tools with a permission error and
   no obvious cause.
2. Attachments must stay read-only by default. A remote agent deleting the operator's files
   also removes bytes from disk, which no confirm-token round trip can undo.
"""

from __future__ import annotations

import sqlite3
from typing import Any

import pytest

from command.config import get_settings
from command.core import accounts as accounts_core
from command.core import settings as settings_core
from command.mcp.server import build_mcp


@pytest.fixture
def mcp(tmp_path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "mcp.db"))
    get_settings.cache_clear()
    from command.db import init_db

    init_db(str(tmp_path / "mcp.db"))
    yield build_mcp(get_settings())
    get_settings.cache_clear()


async def _names(mcp: Any) -> set[str]:
    return {t.name for t in await mcp.list_tools()}


@pytest.mark.anyio
async def test_detail_tools_are_exposed(mcp: Any) -> None:
    names = await _names(mcp)
    for required in (
        "attachments_list", "attachments_read",
        "checklist_list", "checklist_add", "checklist_set_done",
    ):
        assert required in names, f"{required} missing from MCP"


@pytest.mark.anyio
async def test_attachment_reads_are_annotated_read_only(mcp: Any) -> None:
    tools = {t.name: t for t in await mcp.list_tools()}
    for name in ("attachments_list", "attachments_read", "checklist_list"):
        assert tools[name].annotations.readOnlyHint is True
    # ...and the writers do not pretend to be reads.
    assert tools["checklist_add"].annotations.readOnlyHint is False
    assert tools["checklist_set_done"].annotations.idempotentHint is True


def test_new_entities_reach_accounts_that_already_existed(conn: sqlite3.Connection) -> None:
    """The merge is stored-over-defaults, so an account created before these entities existed
    still gets them. If that ever inverted, older accounts would lose the tools silently."""
    aid = accounts_core.register(conn, "existing", "password1").id
    # Simulate a pre-existing account whose stored matrix predates the new entities.
    settings_core.set_value(
        conn, aid, settings_core.MCP_PERMISSIONS_KEY,
        {"notes": {"read": True}, "assignments": {"read": True}},
    )
    perms = settings_core.mcp_permissions(conn, aid)
    assert perms["attachments"]["read"] is True
    assert perms["task_items"]["read"] is True
    assert perms["task_items"]["create"] is True


def test_attachments_are_not_writable_by_default(conn: sqlite3.Connection) -> None:
    """Least privilege (Hard Rule 2). Deleting an attachment also removes bytes from disk —
    there is no undo, confirm-token or not."""
    aid = accounts_core.register(conn, "owner", "password1").id
    perms = settings_core.mcp_permissions(conn, aid)
    assert perms["attachments"]["create"] is False
    assert perms["attachments"]["update"] is False
    assert perms["attachments"]["delete"] is False
    # Checklist deletion is off by default too — marking an item done loses nothing.
    assert perms["task_items"]["delete"] is False


def test_notes_immutability_survives_the_new_entities(conn: sqlite3.Connection) -> None:
    """Hard Rule 1 backstop, re-checked because this commit edited the defaults table."""
    aid = accounts_core.register(conn, "owner2", "password1").id
    settings_core.set_value(
        conn, aid, settings_core.MCP_PERMISSIONS_KEY,
        {"notes": {"update": True, "delete": True}},  # a hostile/incorrect stored value
    )
    perms = settings_core.mcp_permissions(conn, aid)
    assert perms["notes"]["update"] is False
    assert perms["notes"]["delete"] is False
