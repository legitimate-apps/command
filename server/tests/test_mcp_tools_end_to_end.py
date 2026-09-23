"""Actually CALL the MCP tools — nothing did before.

Coverage found the gap: `mcp/tools/*` sat at 35-46%, the lowest in the project, because every
existing MCP test lists tool *names* and inspects the permission matrix without ever invoking a
tool body. That is the surface an external agent drives, so it was the least-exercised code in
the thing most exposed to one.

It matters most for the invisible-ink veil. The veil tests assert `get_for_agent` and
`require_parent_visible` behave (the callees) and a source-level invariant asserts the gate is
present — but "the gate exists in the source" and "the gate fires when the tool is called" are
different claims, and today already produced one bug that lived exactly in that gap. These close
it by going through `call_tool`, auth context and all.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from mcp.server.auth.middleware.auth_context import auth_context_var
from mcp.server.auth.middleware.bearer_auth import AuthenticatedUser
from mcp.server.auth.provider import AccessToken
from mcp.server.fastmcp.exceptions import ToolError

from command.config import get_settings
from command.core import accounts as accounts_core
from command.core import assignments as assignments_core
from command.core import attachments as attachments_core
from command.core import notes as notes_core
from command.core import task_items as task_items_core
from command.db import connect, init_db
from command.mcp.server import build_mcp


@pytest.fixture
def live(tmp_path, monkeypatch: pytest.MonkeyPatch):
    """An MCP server, a database, and an authenticated account — the real call path."""
    db = str(tmp_path / "mcp.db")
    monkeypatch.setenv("COMMAND_DB_PATH", db)
    monkeypatch.setenv("COMMAND_ATTACHMENTS_DIR", str(tmp_path / "attachments"))
    get_settings.cache_clear()
    init_db(db)
    conn = connect(db)
    account = accounts_core.register(conn, "mcp-caller", "password1")
    conn.commit()

    # The transport normally populates this; a tool resolves its account from it.
    token = AccessToken(token="cmd_test", client_id=str(account.id), scopes=[], expires_at=None)
    reset = auth_context_var.set(AuthenticatedUser(token))
    try:
        yield build_mcp(get_settings()), conn, account.id
    finally:
        auth_context_var.reset(reset)
        get_settings.cache_clear()


async def _call(mcp: Any, tool: str, /, **args: Any) -> Any:
    """Invoke a tool the way a client does, returning its structured payload."""
    # Positional-only above: a tool may itself take a parameter called `name`.
    result = await mcp.call_tool(tool, args)
    # FastMCP returns (content, structured) in this SDK version; tolerate either shape.
    payload = result[1] if isinstance(result, tuple) else result
    if isinstance(payload, str):
        return json.loads(payload)
    return payload


@pytest.mark.anyio
async def test_notes_get_returns_a_visible_note(live) -> None:
    mcp, conn, account_id = live
    note = notes_core.create(conn, account_id, "an ordinary note")
    conn.commit()
    out = await _call(mcp, "notes_get", note_id=note.id)
    assert "ordinary note" in json.dumps(out)


@pytest.mark.anyio
async def test_notes_get_refuses_a_hidden_note_through_the_real_tool(live) -> None:
    """The end-to-end claim: the veil fires when the tool is *called*, not just in source."""
    mcp, conn, account_id = live
    note = notes_core.create(conn, account_id, "SECRET: therapy notes")
    notes_core.set_hidden(conn, account_id, note.id, True)
    conn.commit()

    with pytest.raises(ToolError) as err:
        await _call(mcp, "notes_get", note_id=note.id)
    assert "SECRET" not in str(err.value), "the refusal must not echo the hidden content back"

    revealed = await _call(mcp, "notes_get", note_id=note.id, include_hidden=True)
    assert "SECRET" in json.dumps(revealed), "an explicit opt-in must still work"


@pytest.mark.anyio
async def test_attachments_and_checklist_inherit_the_veil_through_the_real_tools(live) -> None:
    """The second-order leak, exercised through the tools rather than the helper."""
    mcp, conn, account_id = live
    a = assignments_core.create(conn, account_id, title="SECRET: lawyer", hidden=True)
    attachments_core.save(
        conn, account_id, "assignment", a.id,
        filename="settlement.txt", mime="text/plain", data=b"the terms",
    )
    task_items_core.add(conn, account_id, "assignment", a.id, text="call the solicitor")
    conn.commit()

    with pytest.raises(ToolError):
        await _call(mcp, "attachments_list", entity_kind="assignment", entity_id=a.id)
    with pytest.raises(ToolError):
        await _call(mcp, "checklist_list", parent_type="assignment", parent_id=a.id)

    # And the filenames/steps are reachable when the operator asks for them.
    listed = await _call(
        mcp, "attachments_list", entity_kind="assignment", entity_id=a.id, include_hidden=True
    )
    assert "settlement.txt" in json.dumps(listed)


@pytest.mark.anyio
async def test_a_visible_parents_detail_is_unaffected(live) -> None:
    mcp, conn, account_id = live
    a = assignments_core.create(conn, account_id, title="ordinary task")
    task_items_core.add(conn, account_id, "assignment", a.id, text="step one")
    conn.commit()
    out = await _call(mcp, "checklist_list", parent_type="assignment", parent_id=a.id)
    assert "step one" in json.dumps(out)


@pytest.mark.anyio
async def test_a_destructive_tool_will_not_act_without_a_confirm_token(live) -> None:
    """Hard Rule 2 through the real call path: first call plans, it does not delete."""
    mcp, conn, account_id = live
    a = assignments_core.create(conn, account_id, title="delete me")
    conn.commit()

    planned = await _call(mcp, "assignments_delete", assignment_id=a.id)
    body = json.dumps(planned)
    assert "needs_confirm" in body and "confirm_token" in body
    # Still there — the planning call must not have deleted anything.
    assert assignments_core.get(conn, account_id, a.id).title == "delete me"


# --- the rest of the tool surface, driven for the first time -------------------
#
# These modules had never executed under test (goals 36%, delegatees 38%, activities 35%).
# Exercising the real round trips is how a broken tool body gets found; the permission matrix
# and the tool list say nothing about whether a tool actually works.


@pytest.mark.anyio
async def test_goals_round_trip_through_the_tools(live) -> None:
    mcp, _conn, _ = live
    created = await _call(mcp, "goals_create", title="Ship the planner", description="by autumn")
    goal_id = created["id"]

    found = await _call(mcp, "goals_search", query="planner")
    assert "Ship the planner" in json.dumps(found)

    got = await _call(mcp, "goals_get", goal_id=goal_id)
    assert "Ship the planner" in json.dumps(got)

    updated = await _call(mcp, "goals_update", goal_id=goal_id, status="done")
    assert "done" in json.dumps(updated)


@pytest.mark.anyio
async def test_goals_link_notes_connects_the_capture_to_the_plan(live) -> None:
    """The workflow the product is built around: raw notes become a goal."""
    mcp, conn, account_id = live
    note = notes_core.create(conn, account_id, "idea worth planning")
    conn.commit()
    goal = await _call(mcp, "goals_create", title="From a note")
    goal_id = goal["id"]
    linked = await _call(mcp, "goals_link_notes", goal_id=goal_id, note_ids=[note.id])
    assert json.dumps(linked)


@pytest.mark.anyio
async def test_delegatees_upsert_is_idempotent_by_slug(live) -> None:
    """Documented contract: re-upserting the same name updates rather than duplicating."""
    mcp, _conn, _ = live
    first = await _call(mcp, "delegatees_upsert", name="Roommate Jordan")
    again = await _call(mcp, "delegatees_upsert", name="Roommate Jordan", lead_time_minutes=120)
    slug = first["delegatee"]["slug"]
    assert slug == again["delegatee"]["slug"], "same name must resolve to the same delegatee"
    assert first["created"] is True and again["created"] is False, "the second call is an update"

    listed = await _call(mcp, "delegatees_list")
    slugs = [d["slug"] for d in listed["items"]]
    assert slugs.count(slug) == 1, f"upsert duplicated the delegatee: {slugs}"

    got = await _call(mcp, "delegatees_get", slug=slug)
    assert got["lead_time_minutes"] == 120, "the second upsert must have updated the row"


@pytest.mark.anyio
async def test_activities_log_and_search_round_trip(live) -> None:
    mcp, _conn, _ = live
    await _call(mcp, "activities_log", title="Paid the electricity bill")
    found = await _call(mcp, "activities_search", query="electricity")
    assert "electricity" in json.dumps(found)


@pytest.mark.anyio
async def test_activities_summary_rolls_up_without_exploding_on_an_empty_log(live) -> None:
    """The audit rollup runs on accounts with no activity at all — it must not error."""
    mcp, _conn, _ = live
    empty = await _call(mcp, "activities_summary")
    assert json.dumps(empty)


@pytest.mark.anyio
async def test_schedule_tools_answer_on_an_empty_calendar(live) -> None:
    """All three are read-only helpers that must degrade gracefully with no data."""
    mcp, _conn, _ = live
    free = await _call(
        mcp, "schedule_find_free_time", duration_minutes=30,
        start="2026-09-01T09:00:00+00:00", end="2026-09-01T17:00:00+00:00",
    )
    assert json.dumps(free)
    conflicts = await _call(
        mcp, "schedule_find_conflicts",
        start="2026-09-01T00:00:00+00:00", end="2026-09-02T00:00:00+00:00",
    )
    assert json.dumps(conflicts)
    stale = await _call(mcp, "schedule_find_stale")
    assert json.dumps(stale)


@pytest.mark.anyio
async def test_whoami_orients_without_leaking_the_roster(live) -> None:
    """It is ungated by design, so what it returns is a security question."""
    mcp, _conn, _ = live
    await _call(mcp, "delegatees_upsert", name="Someone Private")
    out = await _call(mcp, "command_whoami")
    body = json.dumps(out)
    assert "permissions" in body
    assert "Someone Private" not in body, "whoami must not enumerate the delegatee roster"


# --- assignments, notes and detail: the workflow the product is built around -------------------


@pytest.mark.anyio
async def test_the_note_to_assignment_workflow_end_to_end(live) -> None:
    """The flow the whole app exists for: capture -> plan -> delegate -> mark processed."""
    mcp, _conn, _ = live
    note = await _call(mcp, "notes_create", body="Roof is leaking, get someone in")
    note_id = note["id"]

    unprocessed = await _call(mcp, "notes_search", unprocessed=True)
    assert any(n["id"] == note_id for n in unprocessed["items"])

    person = await _call(mcp, "delegatees_upsert", name="Handyman Sam")
    task = await _call(mcp, "assignments_create", title="Fix the roof", details="from the note")
    assigned = await _call(
        mcp, "assignments_assign",
        assignment_id=task["id"], assignee_slug=person["delegatee"]["slug"],
    )
    assert json.dumps(assigned)

    await _call(mcp, "notes_mark_processed", note_id=note_id, processed=True)
    still_unprocessed = await _call(mcp, "notes_search", unprocessed=True)
    assert not any(n["id"] == note_id for n in still_unprocessed["items"]), (
        "a processed note must leave the unprocessed queue"
    )


@pytest.mark.anyio
async def test_marking_an_assignment_done_auto_logs_a_completion_activity(live) -> None:
    """A documented domain rule that bypasses the permission matrix — so it needs pinning.

    The agent is told about this in the MCP instructions ("marking an assignment done auto-logs a
    completion activity"), which makes it a contract, not an implementation detail.
    """
    mcp, _conn, _ = live
    task = await _call(mcp, "assignments_create", title="Take out the bins")
    before = await _call(mcp, "activities_search")
    await _call(mcp, "assignments_set_status", assignment_id=task["id"], status="done")
    after = await _call(mcp, "activities_search")
    assert len(after["items"]) > len(before["items"]), "completing an assignment must log a fact"
    assert "Take out the bins" in json.dumps(after)


@pytest.mark.anyio
async def test_assignments_calendar_expands_a_recurring_rule(live) -> None:
    """`assignments_calendar` expands RRULEs — one row becomes many occurrences."""
    mcp, _conn, _ = live
    await _call(
        mcp, "assignments_create", title="Standup", schedule_kind="routine",
        rrule="FREQ=DAILY", scheduled_start="2026-09-01T09:00:00+00:00",
    )
    occurrences = await _call(
        mcp, "assignments_calendar",
        start="2026-09-01T00:00:00+00:00", end="2026-09-05T00:00:00+00:00",
    )
    assert len(occurrences["occurrences"]) >= 4, occurrences


@pytest.mark.anyio
async def test_the_checklist_round_trip_through_the_tools(live) -> None:
    mcp, _conn, _ = live
    task = await _call(mcp, "assignments_create", title="Move house")
    added = await _call(
        mcp, "checklist_add", parent_type="assignment", parent_id=task["id"], text="book a van"
    )
    item_id = added["item"]["id"] if "item" in added else added["id"]

    listed = await _call(mcp, "checklist_list", parent_type="assignment", parent_id=task["id"])
    assert "book a van" in json.dumps(listed)

    await _call(mcp, "checklist_set_done", item_id=item_id, done=True)
    done = await _call(mcp, "checklist_list", parent_type="assignment", parent_id=task["id"])
    assert json.loads(json.dumps(done))["items"][0]["done"] is True


@pytest.mark.anyio
async def test_reading_a_text_attachment_through_the_tool(live) -> None:
    mcp, conn, account_id = live
    task = assignments_core.create(conn, account_id, title="With a document")
    saved = attachments_core.save(
        conn, account_id, "assignment", task.id,
        filename="brief.txt", mime="text/plain", data=b"the actual contents",
    )
    conn.commit()
    out = await _call(mcp, "attachments_read", attachment_id=saved.id)
    assert out["readable"] is True
    assert "the actual contents" in out["content"]


@pytest.mark.anyio
async def test_a_binary_attachment_reports_its_type_instead_of_returning_noise(live) -> None:
    """Documented behaviour: say what the file is rather than decoding a PDF into garbage."""
    mcp, conn, account_id = live
    task = assignments_core.create(conn, account_id, title="With a photo")
    saved = attachments_core.save(
        conn, account_id, "assignment", task.id,
        filename="photo.jpg", mime="image/jpeg", data=b"\xff\xd8\xff\xe0binary",
    )
    conn.commit()
    out = await _call(mcp, "attachments_read", attachment_id=saved.id)
    assert out["readable"] is False
    assert "content" not in out, "binary contents must not be returned at all"
