"""The notes→goals, delegation and attachment tool groups on the agent toolset.

The domain logic is already covered by each core module's own suite; what these pin is the
WIRING and the agent-facing contract — that the tools exist, are callable, return the JSON
the model will actually see, and enforce the invariants that matter on this surface.

Two of those invariants are load-bearing enough to have dedicated tests: notes must stay
undeletable (Hard Rule 1), and `read_attachment` must refuse to decode binary rather than
handing a model a screenful of mojibake it will then confidently summarise.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import attachments as ATT
from command.core import delegatees as D
from command.core import goals as G
from command.core import notes as N
from command.core.agent import tools as T


class _Ctx:
    def __init__(self, deps: T.AgentDeps) -> None:
        self.deps = deps


@pytest.fixture
def wired(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from command.config import get_settings
    from command.db import connect, init_db

    db = str(tmp_path / "t.db")
    monkeypatch.setenv("COMMAND_DB_PATH", db)
    get_settings.cache_clear()
    init_db(db)
    conn = connect(db)
    account_id = accounts_core.register(conn, "owner", "password1").id
    conn.commit()
    yield _Ctx(T.AgentDeps(db_path=db, account_id=account_id)), conn, account_id
    conn.close()
    get_settings.cache_clear()


# ---------- the invariant that outranks every feature ----------

def test_no_tool_can_delete_a_note() -> None:
    """Hard Rule 1. Notes are the raw input the whole system is built on."""
    names = {t.__name__ for t in T.TOOLS}
    for forbidden in ("delete_note", "remove_note", "destroy_note", "archive_note"):
        assert forbidden not in names, f"{forbidden} must never exist on the agent surface"


def test_the_new_groups_are_registered() -> None:
    names = [t.__name__ for t in T.TOOLS]
    for required in (
        "get_note", "mark_note_processed", "triage_unprocessed_notes",
        "update_goal", "link_notes_to_goal", "list_goal_notes",
        "get_assignment", "assign_assignment", "search_people",
        "log_activity", "activity_summary",
        "list_checklist", "add_checklist_item", "set_checklist_item_done",
        "list_attachments", "read_attachment",
    ):
        assert required in names, f"{required} is not on the agent toolset"
    assert len(names) == len(set(names)), "duplicate tool name"


# ---------- notes -> goals ----------

def test_mark_note_processed_closes_the_triage_loop(wired) -> None:
    ctx, conn, aid = wired
    note = N.create(conn, aid, body="turn me into a goal")
    conn.commit()

    before = json.loads(T.triage_unprocessed_notes(ctx))
    assert [n["id"] for n in before["unprocessed_notes"]] == [note.id]

    T.mark_note_processed(ctx, note.id)

    after = json.loads(T.triage_unprocessed_notes(ctx))
    assert after["unprocessed_notes"] == []
    # ...and the note itself still exists. Processing is not deletion.
    assert json.loads(T.get_note(ctx, note.id))["id"] == note.id


def test_triage_returns_notes_and_goals_together(wired) -> None:
    ctx, conn, aid = wired
    N.create(conn, aid, body="an idea")
    G.create(conn, aid, title="Ship the thing")
    conn.commit()
    out = json.loads(T.triage_unprocessed_notes(ctx))
    assert len(out["unprocessed_notes"]) == 1 and len(out["goals"]) == 1


def test_linking_notes_records_a_goals_provenance(wired) -> None:
    ctx, conn, aid = wired
    note = N.create(conn, aid, body="why this goal exists")
    goal = G.create(conn, aid, title="A goal")
    conn.commit()
    assert json.loads(T.link_notes_to_goal(ctx, goal.id, [note.id]))["linked"] == 1
    assert [n["id"] for n in json.loads(T.list_goal_notes(ctx, goal.id))] == [note.id]


def test_update_goal_leaves_omitted_fields_alone(wired) -> None:
    ctx, conn, aid = wired
    goal = G.create(conn, aid, title="Original", description="keep me")
    conn.commit()
    out = json.loads(T.update_goal(ctx, goal.id, title="Renamed"))
    assert out["title"] == "Renamed"
    assert out["description"] == "keep me", "a one-field edit must not wipe the rest of the row"


def test_hidden_notes_stay_out_of_triage(wired) -> None:
    ctx, conn, aid = wired
    N.create(conn, aid, body="secret", hidden=True)
    conn.commit()
    assert json.loads(T.triage_unprocessed_notes(ctx))["unprocessed_notes"] == []


# ---------- delegation ----------

def test_assign_and_read_back(wired) -> None:
    ctx, conn, aid = wired
    sam, _ = D.upsert(conn, aid, name="Sam", kind="human")
    a = A.create(conn, aid, title="File taxes")
    conn.commit()
    assert json.loads(T.assign_assignment(ctx, a.id, sam.id))["assignee_id"] == sam.id
    assert json.loads(T.get_assignment(ctx, a.id))["assignee_id"] == sam.id


def test_search_people_finds_by_name(wired) -> None:
    ctx, conn, aid = wired
    D.upsert(conn, aid, name="Dana", kind="human")
    conn.commit()
    assert "Dana" in [p["name"] for p in json.loads(T.search_people(ctx, "dan"))]


def test_log_activity_records_history(wired) -> None:
    ctx, _conn, _aid = wired
    out = json.loads(T.log_activity(ctx, "Called the vendor", details="They'll ship Monday"))
    assert out["title"] == "Called the vendor"


# ---------- checklists ----------

def test_checklist_round_trip(wired) -> None:
    ctx, conn, aid = wired
    a = A.create(conn, aid, title="Move house")
    conn.commit()
    item = json.loads(T.add_checklist_item(ctx, "assignment", a.id, "Book the van"))
    assert item["text"] == "Book the van" and item["done"] is False
    assert json.loads(T.set_checklist_item_done(ctx, item["id"]))["done"] is True
    assert [i["id"] for i in json.loads(T.list_checklist(ctx, "assignment", a.id))] == [item["id"]]


# ---------- attachments ----------

def test_read_attachment_returns_text(wired) -> None:
    ctx, conn, aid = wired
    note = N.create(conn, aid, body="with a file")
    att = ATT.save(conn, aid, "note", note.id, filename="notes.txt",
                   mime="text/plain", data=b"the quick brown fox")
    conn.commit()
    out = json.loads(T.read_attachment(ctx, att.id))
    assert out["readable"] is True and "quick brown fox" in out["content"]


def test_read_attachment_refuses_binary_instead_of_returning_noise(wired) -> None:
    """Handing a model decoded JPEG bytes invites a confident summary of nonsense."""
    ctx, conn, aid = wired
    note = N.create(conn, aid, body="with an image")
    att = ATT.save(conn, aid, "note", note.id, filename="photo.jpg",
                   mime="image/jpeg", data=b"\xff\xd8\xff\xe0binary")
    conn.commit()
    out = json.loads(T.read_attachment(ctx, att.id))
    assert out["readable"] is False
    assert "content" not in out
    assert "image/jpeg" in out["note"]


def test_read_attachment_truncates_long_text(wired) -> None:
    ctx, conn, aid = wired
    note = N.create(conn, aid, body="long file")
    att = ATT.save(conn, aid, "note", note.id, filename="big.txt",
                   mime="text/plain", data=b"x" * 5000)
    conn.commit()
    out = json.loads(T.read_attachment(ctx, att.id, max_chars=100))
    assert out["truncated"] is True and len(out["content"]) == 100
