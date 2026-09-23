"""Hidden / invisible-ink veil: hidden captures are returned to the app but excluded
from agent reads by default, with an explicit per-call/per-conversation opt-in."""

from __future__ import annotations

import json
import sqlite3
from types import SimpleNamespace

from fastapi.testclient import TestClient

from command.core import accounts as accounts_core
from command.core import activities as act_core
from command.core import assignments as a_core
from command.core import notes as n_core


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


# --- Core choke point: default-exclude, opt-in include ----------------------


def test_notes_hidden_core(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    n_core.create(conn, aid, "visible")
    h = n_core.create(conn, aid, "secret", hidden=True)
    assert h.hidden is True
    assert {n.body for n in n_core.search(conn, aid)[0]} == {"visible"}
    assert {n.body for n in n_core.search(conn, aid, include_hidden=True)[0]} == {"visible", "secret"}
    # reversible un-hide (Hard Rule 1: never deletes)
    n_core.set_hidden(conn, aid, h.id, False)
    assert {n.body for n in n_core.search(conn, aid)[0]} == {"visible", "secret"}


def test_activities_hidden_core(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    act_core.create(conn, aid, title="visible did")
    act_core.create(conn, aid, title="secret did", hidden=True)
    assert {a.title for a in act_core.search(conn, aid)[0]} == {"visible did"}
    got = {a.title for a in act_core.search(conn, aid, include_hidden=True)[0]}
    assert got == {"visible did", "secret did"}
    # audit rollup also excludes hidden by default
    assert sum(r.count for r in act_core.summary(conn, aid)) == 1
    assert sum(r.count for r in act_core.summary(conn, aid, include_hidden=True)) == 2


def test_assignments_hidden_core(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a_core.create(conn, aid, title="visible task", schedule_kind="sporadic",
                  scheduled_start="2026-06-20T10:00:00+00:00")
    a_core.create(conn, aid, title="secret task", schedule_kind="sporadic",
                  scheduled_start="2026-06-20T11:00:00+00:00", hidden=True)
    # list_ + search
    assert {a.title for a in a_core.list_(conn, aid)[0]} == {"visible task"}
    got = {a.title for a in a_core.list_(conn, aid, include_hidden=True)[0]}
    assert got == {"visible task", "secret task"}
    assert {a.title for a in a_core.search(conn, aid, "task")} == {"visible task"}
    got = {a.title for a in a_core.search(conn, aid, "task", include_hidden=True)}
    assert got == {"visible task", "secret task"}
    # calendar expansion (and the Occurrence projection carries the flag)
    start, end = "2026-06-20T00:00:00+00:00", "2026-06-20T23:59:59+00:00"
    assert {o.title for o in a_core.calendar(conn, aid, start, end)} == {"visible task"}
    occ = a_core.calendar(conn, aid, start, end, include_hidden=True)
    assert {o.title for o in occ} == {"visible task", "secret task"}
    assert any(o.hidden for o in occ)


# --- Agent tools: allow_hidden threads from AgentDeps to the core filter ------


def test_agent_tools_respect_allow_hidden(tmp_path: object) -> None:
    from command.core.agent.tools import AgentDeps, list_assignments, search_activities, search_notes
    from command.db import connect, init_db

    db = str(tmp_path / "agent.db")  # type: ignore[operator]
    init_db(db)
    c = connect(db)
    aid = _acct(c)
    n_core.create(c, aid, "visible thought")
    n_core.create(c, aid, "hidden thought", hidden=True)
    act_core.create(c, aid, title="visible did")
    act_core.create(c, aid, title="hidden did", hidden=True)
    a_core.create(c, aid, title="visible task")
    a_core.create(c, aid, title="hidden task", hidden=True)
    c.commit()  # the tools open their own connections — make writes visible
    c.close()

    def deps(allow: bool) -> object:
        return SimpleNamespace(deps=AgentDeps(db_path=db, account_id=aid, allow_hidden=allow))

    # Default OFF excludes hidden across all three read tools…
    assert {n["body"] for n in json.loads(search_notes(deps(False)))} == {"visible thought"}
    assert {a["title"] for a in json.loads(search_activities(deps(False)))} == {"visible did"}
    assert {a["title"] for a in json.loads(list_assignments(deps(False)))} == {"visible task"}
    # …and the per-conversation opt-in reveals them.
    assert {n["body"] for n in json.loads(search_notes(deps(True)))} == {"visible thought", "hidden thought"}
    assert {a["title"] for a in json.loads(search_activities(deps(True)))} == {"visible did", "hidden did"}
    assert {a["title"] for a in json.loads(list_assignments(deps(True)))} == {"visible task", "hidden task"}


# --- REST: the app sees hidden items (to veil them), flagged ------------------


def test_rest_hidden_roundtrip(client: TestClient) -> None:
    r = client.post("/api/auth/register", json={"username": "owner", "password": "password1"})
    assert r.status_code == 200
    vis = client.post("/api/notes", json={"body": "visible"}).json()
    hid = client.post("/api/notes", json={"body": "secret", "hidden": True}).json()
    assert hid["hidden"] is True and vis["hidden"] is False
    # the app's list returns both, with the flag set, so it can render the veil
    rows = {n["body"]: n["hidden"] for n in client.get("/api/notes").json()["items"]}
    assert rows == {"visible": False, "secret": True}
    # hidden assignment + log round-trip the flag too
    assert client.post("/api/assignments", json={"title": "t", "hidden": True}).json()["hidden"] is True
    assert client.post("/api/activities", json={"title": "x", "hidden": True}).json()["hidden"] is True
    # reversible un-hide
    client.post(f"/api/notes/{hid['id']}/hidden", params={"hidden": "false"})
    assert client.get(f"/api/notes/{hid['id']}").json()["hidden"] is False
