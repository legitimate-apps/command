"""The calendar/scheduling group on the AGENT toolset.

`core/schedule.py` is covered by `test_schedule_core.py`; this pins the wiring — that the
tools are registered, callable through a RunContext, and return the agent-facing JSON. The
assistant was previously blind to the calendar entirely, so "is it actually on the toolset?"
is the regression worth guarding.

The TOOLS list order is also asserted: it is the Anthropic prompt-cache breakpoint, and a
re-sort silently costs a full cache miss on every request rather than failing loudly.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core.agent import tools as T


def _deps(tmp_path: Path, conn: sqlite3.Connection, account_id: int) -> T.AgentDeps:
    return T.AgentDeps(db_path=str(tmp_path / "t.db"), account_id=account_id)


class _Ctx:
    """Minimal stand-in for pydantic-ai's RunContext — the tools only read `.deps`."""

    def __init__(self, deps: T.AgentDeps) -> None:
        self.deps = deps


@pytest.fixture
def wired(tmp_path: Path) -> tuple[_Ctx, sqlite3.Connection, int]:
    from command.db import connect, init_db

    db = str(tmp_path / "t.db")
    init_db(db)
    conn = connect(db)
    account_id = accounts_core.register(conn, "owner", "password1").id
    conn.commit()
    return _Ctx(T.AgentDeps(db_path=db, account_id=account_id)), conn, account_id


def test_the_scheduling_group_is_on_the_toolset() -> None:
    names = {t.__name__ for t in T.TOOLS}
    for required in ("get_calendar", "find_free_time", "find_conflicts", "find_stale_assignments"):
        assert required in names, f"{required} is not registered on the agent toolset"


# The exact, ordered toolset. TOOLS is the Anthropic prompt-cache breakpoint
# (runner.stamp_cache_breakpoint), so ANY change to this sequence — including a reorder that
# adds nothing — costs a full cache miss on every request for every user, silently. Pinning
# the whole list means an intentional change is a deliberate one-line edit here, while an
# accidental re-sort fails loudly. Append new tools at the END of their group.
EXPECTED_TOOL_ORDER = [
    "search_notes", "create_note",
    "list_assignments", "create_assignment", "update_assignment", "set_assignment_status",
    "list_people", "upsert_person",
    "list_goals", "create_goal",
    "search_activities",
    "web_search", "fetch_url",
    "ask_peer",
    "delete_assignment", "delete_activity", "delete_goal", "remove_person",
    "get_calendar", "find_free_time", "find_conflicts", "find_stale_assignments",
    "get_note", "mark_note_processed", "triage_unprocessed_notes",
    "update_goal", "link_notes_to_goal", "list_goal_notes",
    "get_assignment", "assign_assignment", "search_people", "log_activity", "activity_summary",
    "list_checklist", "add_checklist_item", "set_checklist_item_done",
    "list_attachments", "read_attachment",
]


def test_tool_order_is_stable_for_the_prompt_cache() -> None:
    assert [t.__name__ for t in T.TOOLS] == EXPECTED_TOOL_ORDER
    assert len(T.TOOLS) == len({t.__name__ for t in T.TOOLS}), "duplicate tool name"


def test_get_calendar_returns_occurrences(wired) -> None:
    ctx, conn, aid = wired
    A.create(conn, aid, title="Dentist",
             scheduled_start="2026-08-03T10:00:00+00:00",
             scheduled_end="2026-08-03T11:00:00+00:00")
    conn.commit()
    out = json.loads(T.get_calendar(ctx, "2026-08-03T00:00:00+00:00", "2026-08-04T00:00:00+00:00"))
    assert [o["title"] for o in out] == ["Dentist"]


def test_find_free_time_returns_slots(wired) -> None:
    ctx, conn, aid = wired
    A.create(conn, aid, title="Dentist",
             scheduled_start="2126-08-03T10:00:00+00:00",
             scheduled_end="2126-08-03T11:00:00+00:00")
    conn.commit()
    # Far-future window so the real clock can never clamp it away.
    out = json.loads(T.find_free_time(ctx, 30, "2126-08-03T09:00:00+00:00", "2126-08-03T12:00:00+00:00"))
    assert [(s["start"], s["end"]) for s in out] == [
        ("2126-08-03T09:00:00+00:00", "2126-08-03T10:00:00+00:00"),
        ("2126-08-03T11:00:00+00:00", "2126-08-03T12:00:00+00:00"),
    ]


def test_find_conflicts_reports_a_double_booking(wired) -> None:
    ctx, conn, aid = wired
    A.create(conn, aid, title="A", scheduled_start="2026-08-03T10:00:00+00:00",
             scheduled_end="2026-08-03T11:00:00+00:00")
    A.create(conn, aid, title="B", scheduled_start="2026-08-03T10:30:00+00:00",
             scheduled_end="2026-08-03T11:30:00+00:00")
    conn.commit()
    out = json.loads(T.find_conflicts(ctx, "2026-08-03T00:00:00+00:00", "2026-08-04T00:00:00+00:00"))
    assert len(out) == 1
    assert {out[0]["first"]["title"], out[0]["second"]["title"]} == {"A", "B"}


def test_find_stale_assignments_flags_blocked_work(wired) -> None:
    ctx, conn, aid = wired
    A.create(conn, aid, title="Waiting on parts", status="blocked")
    conn.commit()
    out = json.loads(T.find_stale_assignments(ctx, 0))
    assert any(
        f["title"] == "Waiting on parts" and "blocked" in f["reasons"] for f in out["items"]
    )


def test_find_stale_assignments_reports_scale_without_dumping_the_backlog(wired) -> None:
    """Observed on live data: 46 stale items came back as ~3.4k tokens of context, on a tool
    the model reaches for constantly. It needs to know the SCALE, not read every row — the
    payload is re-paid on every subsequent turn of the conversation."""
    ctx, conn, aid = wired
    for i in range(40):
        A.create(conn, aid, title=f"Stalled {i}", status="blocked")
    conn.commit()

    out = json.loads(T.find_stale_assignments(ctx, 0))
    assert out["total"] == 40, "the true scale must still be reported"
    assert out["shown"] == 15, "but only the top slice is handed over by default"
    assert len(out["items"]) == 15

    # ...and the user can still ask for more.
    wider = json.loads(T.find_stale_assignments(ctx, 0, limit=40))
    assert wider["shown"] == 40


def test_tool_errors_come_back_actionable_not_as_tracebacks(wired) -> None:
    """`_guard` must turn a domain error into something the model can act on."""
    ctx, _, _ = wired
    out = T.find_free_time(ctx, 0, "2026-08-03T09:00:00+00:00", "2026-08-03T17:00:00+00:00")
    assert "Traceback" not in out
    assert "duration_minutes" in out
