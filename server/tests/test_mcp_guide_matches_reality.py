"""The MCP guide must describe the surface that actually exists.

CLAUDE.md calls `docs/mcp/MCP-GUIDE.md` "the agent-facing contract", and an external agent
reads it to decide what it can do. A guide that lags the code is worse than no guide: it
tells the agent to call tools that don't exist, and hides tools that do. This drifted once
already — the guide described 31 tools while the in-app assistant had 38.

So: every tool the server exposes must appear in the guide, and every tool the guide names
must exist.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from command.config import get_settings
from command.mcp.server import build_mcp

GUIDE = Path(__file__).resolve().parents[2] / "docs" / "mcp" / "MCP-GUIDE.md"


@pytest.fixture
def guide_text() -> str:
    return GUIDE.read_text(encoding="utf-8")


async def _server_tool_names(tmp_path, monkeypatch) -> set[str]:
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "g.db"))
    get_settings.cache_clear()
    from command.db import init_db

    init_db(str(tmp_path / "g.db"))
    try:
        return {t.name for t in await build_mcp(get_settings()).list_tools()}
    finally:
        get_settings.cache_clear()


@pytest.mark.anyio
async def test_every_exposed_tool_is_documented(guide_text: str, tmp_path, monkeypatch) -> None:
    exposed = await _server_tool_names(tmp_path, monkeypatch)
    undocumented = sorted(name for name in exposed if name not in guide_text)
    assert not undocumented, (
        f"these tools exist but the agent-facing guide never mentions them: {undocumented}"
    )


@pytest.mark.anyio
async def test_the_guide_does_not_promise_tools_that_do_not_exist(
    guide_text: str, tmp_path, monkeypatch
) -> None:
    exposed = await _server_tool_names(tmp_path, monkeypatch)
    # Backticked identifiers that look like tool names (a group prefix + underscore).
    prefixes = ("notes_", "goals_", "assignments_", "activities_", "delegatees_",
                "settings_", "schedule_", "attachments_", "checklist_", "command_")
    # Names the guide mentions precisely to say they DON'T exist. Their absence is the
    # documented contract ("the matrix is read-only over MCP; there is no settings_update"),
    # so finding them missing is correct, not a drift.
    deliberately_absent = {"settings_update"}
    named = {
        token for token in re.findall(r"`([a-z_]+)`", guide_text)
        if token.startswith(prefixes)
    } - deliberately_absent
    phantom = sorted(named - exposed)
    assert not phantom, (
        f"the guide tells an agent to call tools that do not exist: {phantom}"
    )


def test_every_mcp_tool_consults_the_permission_matrix() -> None:
    """The settings matrix is only a control if every tool actually asks it.

    Hard Rule 2 says which entities MCP may read/write/delete is server-controlled, not
    hard-coded per call site — but that is enforced by each tool remembering to call
    `permissions.require`, and nothing was checking that they all do. A tool added without it
    would read or write the account's data with the operator's matrix switched off, and every
    existing test would still pass.

    Source-level rather than behavioural on purpose: the failure mode is an omission, and an
    omission is invisible to a test that only exercises the tools that exist today.
    """
    # Meta tools that answer questions about the caller's own session/config rather than
    # touching planner data. Explicit allowlist so adding to it is a deliberate decision.
    no_matrix_needed = {
        "command_whoami",   # which account this token resolves to
        "settings_get",     # read-back of the matrix itself, including what is disabled
    }

    unchecked: list[str] = []
    examined = 0
    tools_dir = Path(__file__).resolve().parents[1] / "src" / "command" / "mcp" / "tools"
    for path in sorted(tools_dir.glob("*.py")):
        source = path.read_text()
        # Everything after one @mcp.tool( up to the next one is that tool's definition.
        for chunk in re.split(r"@mcp\.tool\(", source)[1:]:
            match = re.search(r'name="([^"]+)"', chunk)
            if match is None:
                continue
            examined += 1
            body = chunk.split("@mcp.tool(")[0]
            if "permissions.require(" not in body and match.group(1) not in no_matrix_needed:
                unchecked.append(f"{path.name}:{match.group(1)}")

    assert examined >= 39, f"only found {examined} tools — did the parse break?"
    assert unchecked == [], (
        "these MCP tools never call permissions.require, so the operator's matrix cannot "
        f"switch them off: {unchecked}"
    )
