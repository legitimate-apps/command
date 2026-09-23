from __future__ import annotations

import asyncio

import pytest

from command.config import get_settings
from command.mcp.server import build_mcp


def test_tool_contract(tmp_path: object, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "b.db"))  # type: ignore[operator]
    get_settings.cache_clear()
    mcp = build_mcp(get_settings())
    tools = asyncio.run(mcp.list_tools())
    by_name = {t.name: t for t in tools}

    # Notes are read + create only — no destructive note tools exist (Hard Rule 1).
    assert "notes_search" in by_name
    assert "notes_create" in by_name
    assert "notes_delete" not in by_name
    assert "notes_update" not in by_name

    # Activities: a logged-fact surface with an audit rollup.
    for name in ("activities_log", "activities_search", "activities_summary", "activities_delete"):
        assert name in by_name

    # Destructive tools are annotated destructive.
    for name in ("delegatees_remove", "goals_delete", "assignments_delete", "activities_delete"):
        ann = by_name[name].annotations
        assert ann is not None and ann.destructiveHint is True

    # Read tools are annotated read-only.
    for name in (
        "command_whoami",
        "notes_search",
        "assignments_calendar",
        "settings_get",
        "activities_search",
        "activities_summary",
    ):
        ann = by_name[name].annotations
        assert ann is not None and ann.readOnlyHint is True

    get_settings.cache_clear()
