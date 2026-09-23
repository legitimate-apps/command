"""The veil on agent WRITES by id and on goal provenance — not only on reads.

Before the fix an agent that could not read a hidden item could still:
- read hidden note BODIES through `list_goal_notes` (and their ids through `goals_get`);
- probe which ids exist behind the veil with `link_notes_to_goal` / `goals_link_notes`;
- mark a hidden note processed, retitle / reassign / re-status a hidden assignment, or update a
  hidden activity — each of which echoed the full hidden row straight back.

Every one of these now reads as "not found", exactly like a bad id, unless the caller opted in
(`allow_hidden` for the in-app agent, `include_hidden` over MCP).
"""

from __future__ import annotations

import json
import sqlite3
from typing import Any

import pytest
from mcp.server.auth.middleware.auth_context import auth_context_var
from mcp.server.auth.middleware.bearer_auth import AuthenticatedUser
from mcp.server.auth.provider import AccessToken
from mcp.server.fastmcp.exceptions import ToolError

from command.config import get_settings
from command.core import accounts, activities, assignments, goals, notes
from command.core import delegatees as delegatees_core
from command.core.agent import tools
from command.db import connect, init_db
from command.mcp.server import build_mcp


@pytest.fixture
def world(tmp_path: Any) -> Any:
    db = str(tmp_path / "v.db")
    init_db(db)
    conn = connect(db)
    aid = accounts.register(conn, "veil-writer", "password1").id
    note = notes.create(conn, aid, "SECRET note body", hidden=True)
    task = assignments.create(conn, aid, title="SECRET task", hidden=True)
    act = activities.create(conn, aid, title="SECRET log", hidden=True)
    goal = goals.create(conn, aid, title="visible goal")
    conn.execute("INSERT INTO goal_notes (goal_id, note_id) VALUES (?, ?)", (goal.id, note.id))
    me = delegatees_core.ensure_self(conn, aid)
    conn.commit()
    return db, conn, aid, note, task, act, goal, me


def _ctx(db: str, aid: int, allow_hidden: bool = False) -> Any:
    class _C:
        deps = tools.AgentDeps(db_path=db, account_id=aid, allow_hidden=allow_hidden)

    return _C()


def _err(out: str) -> str:
    payload = json.loads(out)
    assert isinstance(payload, dict) and "error" in payload, f"expected an error, got {out[:120]}"
    assert "SECRET" not in out
    return str(payload["error"])


def test_in_app_goal_provenance_hides_hidden_notes(world: Any) -> None:
    db, _, aid, note, *_rest = world
    goal = world[6]
    assert json.loads(tools.list_goal_notes(_ctx(db, aid), goal.id)) == []
    shown = json.loads(tools.list_goal_notes(_ctx(db, aid, allow_hidden=True), goal.id))
    assert [n["id"] for n in shown] == [note.id]
    assert "No note" in _err(tools.link_notes_to_goal(_ctx(db, aid), goal.id, [note.id]))


def test_in_app_writes_by_id_refuse_hidden_targets(world: Any) -> None:
    db, _conn, aid, note, task, _act, _goal, me = world
    ctx = _ctx(db, aid)
    _err(tools.mark_note_processed(ctx, note.id))
    _err(tools.update_assignment(ctx, task.id, title="renamed"))
    _err(tools.set_assignment_status(ctx, task.id, "done"))
    _err(tools.assign_assignment(ctx, task.id, me.id))
    _err(tools.log_activity(ctx, "did it", assignment_id=task.id))
    _err(tools.add_checklist_item(ctx, "assignment", task.id, "step"))
    fresh = connect(db)
    assert notes.get(fresh, aid, note.id).processed_at is None
    row = assignments.get(fresh, aid, task.id)
    assert (row.title, row.status, row.assignee_id) == ("SECRET task", "todo", None)
    # The per-chat opt-in still works.
    ok = json.loads(tools.set_assignment_status(_ctx(db, aid, allow_hidden=True), task.id, "done"))
    assert ok["status"] == "done"


@pytest.fixture
def mcp_world(world: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    db, _conn, aid, *_ = world
    monkeypatch.setenv("COMMAND_DB_PATH", db)
    get_settings.cache_clear()
    token = AccessToken(token="cmd_test", client_id=str(aid), scopes=[], expires_at=None)
    reset = auth_context_var.set(AuthenticatedUser(token))
    try:
        yield build_mcp(get_settings()), world
    finally:
        auth_context_var.reset(reset)
        get_settings.cache_clear()


async def _call(mcp: Any, tool: str, /, **args: Any) -> Any:
    result = await mcp.call_tool(tool, args)
    payload = result[1] if isinstance(result, tuple) else result
    return json.loads(payload) if isinstance(payload, str) else payload


@pytest.mark.anyio
async def test_mcp_writes_and_provenance_honour_the_veil(mcp_world: Any) -> None:
    mcp, (db, _conn, aid, note, task, act, goal, _me) = mcp_world
    got = await _call(mcp, "goals_get", goal_id=goal.id)
    assert got["note_ids"] == []
    for tool, args in [
        ("goals_link_notes", {"goal_id": goal.id, "note_ids": [note.id]}),
        ("notes_mark_processed", {"note_id": note.id}),
        ("assignments_update", {"assignment_id": task.id, "title": "renamed"}),
        ("assignments_set_status", {"assignment_id": task.id, "status": "done"}),
        ("assignments_assign", {"assignment_id": task.id, "assignee_slug": "me"}),
        ("activities_update", {"activity_id": act.id, "title": "renamed"}),
        ("activities_log", {"title": "x", "assignment_id": task.id}),
        ("checklist_add", {"parent_type": "assignment", "parent_id": task.id, "text": "step"}),
    ]:
        with pytest.raises(ToolError) as err:
            await _call(mcp, tool, **args)
        assert "SECRET" not in str(err.value), tool
    fresh = connect(db)
    assert assignments.get(fresh, aid, task.id).title == "SECRET task"
    assert activities.get(fresh, aid, act.id).title == "SECRET log"
    # Explicit opt-in still reaches the item.
    out = await _call(mcp, "assignments_set_status", assignment_id=task.id, status="done",
                      include_hidden=True)
    assert out["status"] == "done"


def test_checklist_parent_must_exist(conn: sqlite3.Connection) -> None:
    from command.core import task_items
    from command.errors import NotFound

    aid = accounts.register(conn, "parentless", "password1").id
    with pytest.raises(NotFound):
        task_items.add(conn, aid, "assignment", 9999, text="orphan")


def test_deleting_a_parent_removes_its_checklist(conn: sqlite3.Connection) -> None:
    from command.core import task_items

    aid = accounts.register(conn, "cleaner", "password1").id
    a = assignments.create(conn, aid, title="t")
    g = goals.create(conn, aid, title="g")
    act = activities.create(conn, aid, title="l")
    for kind, pid in (("assignment", a.id), ("goal", g.id), ("activity", act.id)):
        task_items.add(conn, aid, kind, pid, text="step")
    assignments.delete(conn, aid, a.id)
    goals.delete(conn, aid, g.id)
    activities.delete(conn, aid, act.id)
    assert conn.execute("SELECT COUNT(*) FROM task_items").fetchone()[0] == 0
