"""Scheduling on the MCP surface.

The two surfaces had drifted: the in-app agent gained free-time search, conflict detection
and the staleness audit, while the operator's external Claude Code — which is the surface
CLAUDE.md describes the whole delegation workflow running through — could still only pull raw
occurrences and reason over them by hand.

`core/` is meant to be the single source of truth both surfaces inherit, so this pins that
the scheduling tools exist on MCP, are permission-gated, and are honestly annotated read-only.
"""

from __future__ import annotations

from typing import Any

import pytest

from command.config import get_settings
from command.mcp.server import build_mcp


@pytest.fixture
def mcp(tmp_path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "mcp.db"))
    get_settings.cache_clear()
    from command.db import init_db

    init_db(str(tmp_path / "mcp.db"))
    yield build_mcp(get_settings())
    get_settings.cache_clear()


async def _tools(mcp: Any) -> dict[str, Any]:
    return {t.name: t for t in await mcp.list_tools()}


@pytest.mark.anyio
async def test_the_scheduling_tools_are_exposed_over_mcp(mcp: Any) -> None:
    names = await _tools(mcp)
    for required in (
        "schedule_find_free_time", "schedule_find_conflicts", "schedule_find_stale"
    ):
        assert required in names, f"{required} is missing from the MCP surface"


@pytest.mark.anyio
async def test_they_are_annotated_read_only_honestly(mcp: Any) -> None:
    """Annotations are hints, not enforcement — but a read-only tool claiming otherwise (or a
    writer claiming read-only) misleads every client that shows them to a user."""
    names = await _tools(mcp)
    for tool_name in (
        "schedule_find_free_time", "schedule_find_conflicts", "schedule_find_stale"
    ):
        annotations = names[tool_name].annotations
        assert annotations is not None, f"{tool_name} has no annotations"
        assert annotations.readOnlyHint is True
        assert annotations.openWorldHint is False


@pytest.mark.anyio
async def test_descriptions_carry_the_gotchas_a_caller_would_get_wrong(mcp: Any) -> None:
    """These tools have two non-obvious behaviours. An agent that doesn't know them will
    misread the results rather than fail loudly."""
    names = await _tools(mcp)
    conflicts = names["schedule_find_conflicts"].description or ""
    assert "Back-to-back" in conflicts, "must say touching items are not a conflict"
    free = names["schedule_find_free_time"].description or ""
    assert "reminders" in free.lower(), "must say point-in-time reminders don't consume time"
    stale = names["schedule_find_stale"].description or ""
    assert "total" in stale, "must document that it reports scale beyond what it returns"


@pytest.mark.anyio
async def test_both_surfaces_expose_the_same_scheduling_capability(mcp: Any) -> None:
    """The regression guard: neither surface should silently fall behind the other again."""
    from command.core.agent import tools as agent_tools

    agent = {t.__name__ for t in agent_tools.TOOLS}
    mcp_names = set(await _tools(mcp))
    pairs = [
        ("find_free_time", "schedule_find_free_time"),
        ("find_conflicts", "schedule_find_conflicts"),
        ("find_stale_assignments", "schedule_find_stale"),
    ]
    for agent_name, mcp_name in pairs:
        assert agent_name in agent, f"{agent_name} missing from the in-app agent"
        assert mcp_name in mcp_names, f"{mcp_name} missing from MCP"
