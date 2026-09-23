"""Two accounts on one server: B can neither see nor change anything of A's.

Command Cloud puts strangers on one database, so account isolation stops being a property of a
personal server and becomes THE property. `test_tool_account_scoping` checks the source (every
tool-layer core call passes an account scope); this drives the real surfaces with two real
accounts and asserts on what actually comes back:

- every REST route that takes an id or a name, called by B with A's identifiers;
- B's collection, search and calendar reads never contain A's marker text;
- cross-references (B creating/linking/assigning onto A's goals, notes, people, assignments);
- the delegatee (`/api/my/*`) surface, attachments, peers, agent threads and the iCal feed;
- every MCP tool that takes an id or a slug, called in B's auth context with A's identifiers;
- afterwards A's data is byte-for-byte what A left.

Coverage is enforced, not hoped for: a new REST route with a path parameter, or a new MCP tool
taking an id/slug, fails `test_every_*_is_covered` until it is added to the probes below.
"""

from __future__ import annotations

import json
import re
import sqlite3
from collections.abc import Iterator
from typing import Any

import pytest
from fastapi.testclient import TestClient
from mcp.server.auth.middleware.auth_context import auth_context_var
from mcp.server.auth.middleware.bearer_auth import AuthenticatedUser
from mcp.server.auth.provider import AccessToken
from mcp.server.fastmcp.exceptions import ToolError

from command.config import get_settings
from command.core import settings as settings_core
from command.core.agent import threads
from command.core.peers import registry
from command.db import connect
from command.mcp.server import build_mcp

MARK = "ALPHA-SECRET"
PASSWORD = "correct-horse-battery"

PEER_CARD = {
    "name": "Alpha Agent",
    "description": f"{MARK} peer",
    "supportedInterfaces": [
        {"url": "https://alpha.example.com/a2a", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}
    ],
    "version": "1.0.0",
    "capabilities": {"streaming": False, "pushNotifications": False},
    "defaultInputModes": ["text/plain"],
    "defaultOutputModes": ["text/plain"],
    "skills": [{"id": "alpha", "name": "Alpha", "description": "x", "tags": []}],
}


def _h(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _register(client: TestClient, username: str) -> tuple[str, int]:
    r = client.post("/api/auth/register", json={"username": username, "password": PASSWORD})
    assert r.status_code == 200, r.text
    token = r.cookies.get("command_session")
    client.cookies.clear()
    assert token
    return token, int(r.json()["id"])


@pytest.fixture
def world(tmp_path, monkeypatch: pytest.MonkeyPatch) -> Iterator[dict[str, Any]]:
    """An open-signup server with A's full data set and a signed-in B."""
    db = str(tmp_path / "iso.db")
    monkeypatch.setenv("COMMAND_DB_PATH", db)
    monkeypatch.setenv("COMMAND_ATTACHMENTS_DIR", str(tmp_path / "attachments"))
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.setenv("COMMAND_ALLOW_REGISTRATION", "true")
    monkeypatch.setenv("COMMAND_CALENDAR_EXPORT_SECRET", "test-calendar-secret")
    get_settings.cache_clear()
    from command.app import create_app

    with TestClient(create_app()) as c:
        a_tok, a_id = _register(c, "alice")
        b_tok, b_id = _register(c, "bob")
        as_a = _h(a_tok)

        def ok(r: Any) -> Any:
            assert r.status_code < 300, r.text
            return r.json() if r.content else None

        note = ok(c.post("/api/notes", json={"body": f"{MARK} note"}, headers=as_a))
        ok(c.post(f"/api/notes/{note['id']}/close", headers=as_a))  # closing snapshots a revision
        rev = ok(c.get(f"/api/notes/{note['id']}/revisions", headers=as_a))[0]
        goal = ok(c.post("/api/goals", json={"title": f"{MARK} goal"}, headers=as_a))
        ok(c.post(f"/api/goals/{goal['id']}/notes", json={"note_ids": [note["id"]]}, headers=as_a))
        person = ok(c.post(
            "/api/delegatees", json={"name": f"{MARK} Helper", "slug": "alpha-helper"}, headers=as_a
        ))["delegatee"]
        assignment = ok(c.post("/api/assignments", json={
            "title": f"{MARK} task", "schedule_kind": "routine", "rrule": "FREQ=DAILY",
            "scheduled_start": "2026-09-01T09:00:00+00:00", "goal_id": goal["id"],
            "assignee_id": person["id"],
        }, headers=as_a))
        activity = ok(c.post(
            "/api/activities", json={"title": f"{MARK} activity", "goal_id": goal["id"]}, headers=as_a
        ))
        item = ok(c.post("/api/items", json={
            "parent_type": "assignment", "parent_id": assignment["id"], "text": f"{MARK} item",
        }, headers=as_a))
        attachment = ok(c.post(
            "/api/attachments",
            data={"entity_kind": "assignment", "entity_id": str(assignment["id"])},
            files={"file": ("alpha.txt", f"{MARK} file".encode(), "text/plain")},
            headers=as_a,
        ))
        ok(c.post("/api/push/register", json={"token": "a" * 64}, headers=as_a))
        conn = connect(db)
        peer = registry.add_peer(
            conn, a_id, "https://alpha.example.com", token="alpha-peer-token",
            _fetch=lambda url, **kw: dict(PEER_CARD),
        )
        thread = threads.create_thread(conn, a_id, f"{MARK} thread")
        threads.add_message(conn, a_id, thread.id, threads.ROLE_USER, f"{MARK} message")
        conn.commit()

        yield {
            "client": c, "db": db, "conn": conn, "A": as_a, "B": _h(b_tok),
            "a_id": a_id, "b_id": b_id,
            "note": note["id"], "revision": rev["id"], "goal": goal["id"],
            "person": person["id"], "person_slug": person["slug"],
            "assignment": assignment["id"], "occurrence": "2026-09-02",
            "activity": activity["id"], "item": item["id"], "attachment": attachment["id"],
            "peer": peer.name, "thread": thread.id,
        }
        conn.close()
    get_settings.cache_clear()


# ---------------------------------------------------------------- REST: direct references


def _direct_probes(w: dict[str, Any]) -> list[tuple[str, str, dict[str, Any]]]:
    """(method, path, request kwargs) — B addressing A's objects by id or name. Bodies are
    VALID, so a refusal can only come from the ownership check, never from validation."""
    n, g, a, act = w["note"], w["goal"], w["assignment"], w["activity"]
    d, it, att, occ = w["person"], w["item"], w["attachment"], w["occurrence"]
    return [
        ("GET", f"/api/notes/{n}", {}),
        ("PATCH", f"/api/notes/{n}", {"json": {"body": "pwned"}}),
        ("POST", f"/api/notes/{n}/archive", {}),
        ("POST", f"/api/notes/{n}/hidden", {}),
        ("POST", f"/api/notes/{n}/processed", {}),
        ("POST", f"/api/notes/{n}/close", {}),
        ("GET", f"/api/notes/{n}/revisions", {}),
        ("POST", f"/api/notes/{n}/revisions/{w['revision']}/restore", {}),
        ("GET", f"/api/delegatees/{d}", {}),
        ("POST", f"/api/delegatees/{d}/invite", {}),
        ("DELETE", f"/api/delegatees/{d}/invite", {}),
        ("DELETE", f"/api/delegatees/{d}", {}),
        ("GET", f"/api/goals/{g}", {}),
        ("PATCH", f"/api/goals/{g}", {"json": {"title": "pwned"}}),
        ("GET", f"/api/goals/{g}/notes", {}),
        ("POST", f"/api/goals/{g}/notes", {"json": {"note_ids": [n]}}),
        ("DELETE", f"/api/goals/{g}", {}),
        ("GET", f"/api/assignments/{a}", {}),
        ("PATCH", f"/api/assignments/{a}", {"json": {"title": "pwned"}}),
        ("POST", f"/api/assignments/{a}/assign", {"json": {"assignee_id": None}}),
        ("POST", f"/api/assignments/{a}/archive", {}),
        ("POST", f"/api/assignments/{a}/unarchive", {}),
        ("POST", f"/api/assignments/{a}/status", {"json": {"status": "done"}}),
        ("POST", f"/api/assignments/{a}/occurrences/{occ}/status", {"json": {"status": "done"}}),
        ("POST", f"/api/assignments/{a}/occurrences/{occ}/reschedule",
         {"json": {"occurs_at": "2026-09-02T15:00:00+00:00"}}),
        ("DELETE", f"/api/assignments/{a}/occurrences/{occ}/reschedule", {}),
        ("DELETE", f"/api/assignments/{a}", {}),
        ("GET", f"/api/attachments/{att}/download", {}),
        ("DELETE", f"/api/attachments/{att}", {}),
        ("GET", "/api/attachments", {"params": {"entity_kind": "assignment", "entity_id": a}}),
        ("POST", "/api/attachments", {
            "data": {"entity_kind": "note", "entity_id": str(n)},
            "files": {"file": ("x.txt", b"x", "text/plain")},
        }),
        ("GET", f"/api/activities/{act}", {}),
        ("PATCH", f"/api/activities/{act}", {"json": {"title": "pwned"}}),
        ("DELETE", f"/api/activities/{act}", {}),
        ("GET", "/api/items", {"params": {"parent_type": "assignment", "parent_id": a}}),
        ("POST", "/api/items", {"json": {"parent_type": "assignment", "parent_id": a, "text": "x"}}),
        ("POST", "/api/items/reorder",
         {"json": {"parent_type": "assignment", "parent_id": a, "ordered_ids": [it]}}),
        ("PATCH", f"/api/items/{it}", {"json": {"text": "pwned", "done": True}}),
        ("DELETE", f"/api/items/{it}", {}),
        ("GET", f"/api/agent/threads/{w['thread']}", {}),
        ("POST", f"/api/agent/threads/{w['thread']}/truncate", {"json": {"from_message_id": 1}}),
        ("GET", f"/api/peers/{w['peer']}", {}),
        ("PATCH", f"/api/peers/{w['peer']}", {"json": {"enabled": False}}),
        ("POST", f"/api/peers/{w['peer']}/refresh", {}),
        ("DELETE", f"/api/peers/{w['peer']}", {}),
    ]


def _cross_reference_probes(w: dict[str, Any], mine: dict[str, int]) -> list[tuple[str, str, dict[str, Any]]]:
    """B acting on ITS OWN objects while pointing at A's — each must be refused."""
    return [
        ("POST", "/api/assignments", {"json": {"title": "b", "goal_id": w["goal"]}}),
        ("POST", "/api/assignments", {"json": {"title": "b", "assignee_id": w["person"]}}),
        ("PATCH", f"/api/assignments/{mine['assignment']}", {"json": {"goal_id": w["goal"]}}),
        ("PATCH", f"/api/assignments/{mine['assignment']}", {"json": {"assignee_id": w["person"]}}),
        ("POST", f"/api/assignments/{mine['assignment']}/assign", {"json": {"assignee_id": w["person"]}}),
        ("POST", f"/api/assignments/{mine['assignment']}/assign",
         {"json": {"assignee_slug": w["person_slug"]}}),
        ("POST", "/api/activities", {"json": {"title": "b", "goal_id": w["goal"]}}),
        ("POST", "/api/activities", {"json": {"title": "b", "assignment_id": w["assignment"]}}),
        ("POST", "/api/activities", {"json": {"title": "b", "actor_id": w["person"]}}),
        ("PATCH", f"/api/activities/{mine['activity']}", {"json": {"goal_id": w["goal"]}}),
        ("POST", f"/api/goals/{mine['goal']}/notes", {"json": {"note_ids": [w["note"]]}}),
    ]


def _b_objects(c: TestClient, as_b: dict[str, str]) -> dict[str, int]:
    return {
        "goal": c.post("/api/goals", json={"title": "bob goal"}, headers=as_b).json()["id"],
        "assignment": c.post("/api/assignments", json={"title": "bob task"}, headers=as_b).json()["id"],
        "activity": c.post("/api/activities", json={"title": "bob act"}, headers=as_b).json()["id"],
    }


def _snapshot_a(w: dict[str, Any]) -> dict[str, Any]:
    """Everything of A's, as A sees it — compared before and after B's attempts."""
    c, as_a = w["client"], w["A"]
    snap: dict[str, Any] = {}
    for key, path in (
        ("note", f"/api/notes/{w['note']}"),
        ("revisions", f"/api/notes/{w['note']}/revisions"),
        ("goal", f"/api/goals/{w['goal']}"),
        ("goal_notes", f"/api/goals/{w['goal']}/notes"),
        ("person", f"/api/delegatees/{w['person']}"),
        ("assignment", f"/api/assignments/{w['assignment']}"),
        ("activity", f"/api/activities/{w['activity']}"),
        ("thread", f"/api/agent/threads/{w['thread']}"),
        ("peer", f"/api/peers/{w['peer']}"),
        ("push", "/api/push/tokens"),
    ):
        r = c.get(path, headers=as_a)
        assert r.status_code == 200, (path, r.text)
        snap[key] = r.json()
    snap["items"] = c.get(
        "/api/items", params={"parent_type": "assignment", "parent_id": w["assignment"]}, headers=as_a
    ).json()
    snap["attachment"] = c.get(f"/api/attachments/{w['attachment']}/download", headers=as_a).content
    snap["calendar"] = c.get("/api/assignments/calendar", params={
        "start": "2026-09-01T00:00:00+00:00", "end": "2026-09-07T00:00:00+00:00"}, headers=as_a).json()
    return snap


def test_b_cannot_reach_a_by_reference_on_any_rest_route(world) -> None:
    w = world
    c, as_b = w["client"], w["B"]
    before = _snapshot_a(w)
    mine = _b_objects(c, as_b)
    failures = []
    for method, path, kwargs in _direct_probes(w) + _cross_reference_probes(w, mine):
        r = c.request(method, path, headers=as_b, **kwargs)
        # 404 exactly: "no such thing" — never 403 ("exists, not yours"), which would confirm
        # the id, and never 422, which would mean the probe never reached the ownership check.
        if r.status_code != 404 or MARK in r.text:
            failures.append(f"{method} {path} -> {r.status_code} {r.text[:160]}")
    assert not failures, "cross-account access:\n  " + "\n  ".join(failures)
    assert _snapshot_a(w) == before


# ---------------------------------------------------------------- REST: collections

WINDOW = {"start": "2026-08-01T00:00:00+00:00", "end": "2026-10-01T00:00:00+00:00"}

COLLECTION_READS: list[tuple[str, dict[str, Any]]] = [
    ("/api/notes", {}),
    ("/api/notes", {"query": "ALPHA"}),
    ("/api/notes", {"include_archived": True}),
    ("/api/goals", {}),
    ("/api/goals/search", {"q": "ALPHA"}),
    ("/api/delegatees", {"include_self": True}),
    ("/api/delegatees/search", {"q": "ALPHA"}),
    ("/api/assignments", {}),
    ("/api/assignments", {"archived": True}),
    ("/api/assignments/search", {"q": "ALPHA"}),
    ("/api/assignments/calendar", WINDOW),
    ("/api/activities", {}),
    ("/api/activities/summary", {}),
    ("/api/agent/threads", {}),
    ("/api/agent/usage", {}),
    ("/api/agent/entitlement", {}),
    ("/api/peers", {}),
    ("/api/peers/inbound-info", {}),
    ("/api/push/tokens", {}),
    ("/api/reminders/upcoming", {"within_days": 60}),
    ("/api/settings", {}),
    ("/api/calendar/subscription", {}),
    ("/api/auth/me", {}),
    ("/api/access-token", {}),
]


def test_b_collections_never_contain_a(world) -> None:
    c, as_b = world["client"], world["B"]
    for path, params in COLLECTION_READS:
        r = c.get(path, params=params, headers=as_b)
        assert r.status_code == 200, (path, r.text)
        assert MARK not in r.text and "aaaaaaaa" not in r.text, path


def test_b_calendar_feed_is_only_b(world) -> None:
    c, as_a, as_b = world["client"], world["A"], world["B"]
    a_url = c.get("/api/calendar/subscription", headers=as_a).json()["url"]
    b_url = c.get("/api/calendar/subscription", headers=as_b).json()["url"]
    a_token = re.search(r"token=([^&]+)", a_url).group(1)
    b_token = re.search(r"token=([^&]+)", b_url).group(1)
    assert a_token != b_token
    assert MARK in c.get("/api/calendar.ics", params={"token": a_token}).text  # the control
    assert MARK not in c.get("/api/calendar.ics", params={"token": b_token}).text
    # B's signature on A's account id is not A's token.
    forged = f"{world['a_id']}.{b_token.split('.', 1)[1]}"
    r = c.get("/api/calendar.ics", params={"token": forged})
    assert r.status_code != 200 and MARK not in r.text


# ---------------------------------------------------------------- the delegatee surface


def test_b_delegatee_session_cannot_reach_a(world) -> None:
    w = world
    c, as_b = w["client"], w["B"]
    helper = c.post("/api/delegatees", json={"name": "Bob's helper"}, headers=as_b).json()["delegatee"]
    invite = c.post(f"/api/delegatees/{helper['id']}/invite", headers=as_b).json()["invite_token"]
    r = c.post("/api/auth/invite", json={"token": invite})
    assert r.status_code == 200, r.text
    as_d = _h(r.cookies.get("command_session"))
    c.cookies.clear()
    before = _snapshot_a(w)

    for path, params in (("/api/my/assignments", {}), ("/api/my/calendar", WINDOW), ("/api/my/profile", {})):
        r = c.get(path, params=params, headers=as_d)
        assert r.status_code == 200 and MARK not in r.text, path
    a, occ = w["assignment"], w["occurrence"]
    for method, path, kwargs in (
        ("POST", f"/api/my/assignments/{a}/status", {"json": {"status": "done"}}),
        ("POST", f"/api/my/assignments/{a}/occurrences/{occ}/status", {"json": {"status": "done"}}),
        ("GET", f"/api/my/assignments/{a}/attachments", {}),
        ("GET", f"/api/my/attachments/{w['attachment']}/download", {}),
    ):
        r = c.request(method, path, headers=as_d, **kwargs)
        assert r.status_code == 404 and MARK not in r.text, (path, r.status_code, r.text)
    # A delegatee session is not an operator session, for either account.
    assert c.get(f"/api/assignments/{a}", headers=as_d).status_code == 404
    assert _snapshot_a(w) == before


# ---------------------------------------------------------------- coverage guard

# Paths with a parameter that are covered by the delegatee test rather than `_direct_probes`.
_MY_PATHS = {
    "/api/my/assignments/{assignment_id}/status",
    "/api/my/assignments/{assignment_id}/occurrences/{occurrence_date}/status",
    "/api/my/assignments/{assignment_id}/attachments",
    "/api/my/attachments/{attachment_id}/download",
}


def _template(path: str, w: dict[str, Any]) -> str:
    """Turn a concrete probe path back into its route template."""
    out = []
    for seg in path.split("/"):
        if seg.isdigit() or seg in (w["peer"], w["occurrence"]):
            out.append("{}")
        else:
            out.append(seg)
    return "/".join(out)


def test_every_parameterised_rest_route_is_covered(world) -> None:
    w = world
    app = w["client"].app
    probed = {(m, _template(p, w)) for m, p, _ in _direct_probes(w)}
    missing = []
    for path, ops in app.openapi()["paths"].items():
        if "{" not in path or path in _MY_PATHS:
            continue
        shape = re.sub(r"\{[^}]+\}", "{}", path)
        for method in ops:
            if (method.upper(), shape) not in probed:
                missing.append(f"{method.upper()} {path}")
    assert not missing, "routes with no isolation probe (add them to _direct_probes):\n  " + "\n  ".join(
        missing
    )


# ---------------------------------------------------------------- MCP

_ID_ARGS = {
    "note_id", "note_ids", "goal_id", "assignment_id", "activity_id", "attachment_id", "item_id",
    "entity_id", "parent_id", "assignee_id", "assignee_slug", "slug", "actor",
}


def _mcp_probes(w: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """Per tool, calls made as B that point at A's objects. Each must fail or come back clean."""
    n, g, a, act = w["note"], w["goal"], w["assignment"], w["activity"]
    return {
        "notes_get": [{"note_id": n}, {"note_id": n, "include_hidden": True}],
        "notes_mark_processed": [{"note_id": n}],
        "delegatees_get": [{"slug": w["person_slug"]}],
        "delegatees_remove": [{"slug": w["person_slug"]}],
        "goals_get": [{"goal_id": g}],
        "goals_update": [{"goal_id": g, "title": "pwned"}],
        "goals_link_notes": [{"goal_id": g, "note_ids": [n]}, {"goal_id": "__B_GOAL__", "note_ids": [n]}],
        "goals_delete": [{"goal_id": g}],
        "assignments_get": [{"assignment_id": a}],
        "assignments_create": [{"title": "b", "goal_id": g}, {"title": "b", "assignee_id": w["person"]}],
        "assignments_update": [{"assignment_id": a, "title": "pwned"},
                               {"assignment_id": "__B_ASSIGNMENT__", "goal_id": g}],
        "assignments_assign": [{"assignment_id": a, "assignee_slug": "me"},
                               {"assignment_id": "__B_ASSIGNMENT__", "assignee_slug": w["person_slug"]},
                               {"assignment_id": "__B_ASSIGNMENT__", "assignee_id": w["person"]}],
        "assignments_set_status": [{"assignment_id": a, "status": "done"}],
        "assignments_delete": [{"assignment_id": a}],
        "activities_log": [{"title": "b", "goal_id": g}, {"title": "b", "assignment_id": a},
                           {"title": "b", "actor": w["person_slug"]}],
        "activities_search": [{"goal_id": g}, {"assignment_id": a}, {"actor": w["person_slug"]},
                              {"query": "ALPHA"}],
        "activities_summary": [{"actor": w["person_slug"]}, {}],
        "activities_get": [{"activity_id": act}],
        "activities_update": [{"activity_id": act, "title": "pwned"},
                              {"activity_id": "__B_ACTIVITY__", "goal_id": g}],
        "activities_delete": [{"activity_id": act}],
        "attachments_list": [{"entity_kind": "assignment", "entity_id": a},
                             {"entity_kind": "note", "entity_id": n}],
        "attachments_read": [{"attachment_id": w["attachment"]}],
        "checklist_list": [{"parent_type": "assignment", "parent_id": a}],
        "checklist_add": [{"parent_type": "assignment", "parent_id": a, "text": "x"}],
        "checklist_set_done": [{"item_id": w["item"]}],
        # LAST, because it succeeds: upsert by A's slug creates B's OWN person with that slug
        # (slugs are per account). The check is that A's person is untouched (snapshot) and
        # nothing of A's is echoed. Run earlier, B's same-slug person would make the probes
        # above resolve to B's own record and prove nothing.
        "delegatees_upsert": [{"name": "Imposter", "slug": w["person_slug"]}],
    }


# Tools with no id/slug argument whose output must still never contain A's data.
_MCP_READS: dict[str, dict[str, Any]] = {
    "command_whoami": {},
    "notes_search": {"query": "ALPHA", "include_hidden": True, "include_archived": True},
    "delegatees_search": {"query": "ALPHA"},
    "delegatees_list": {},
    "goals_search": {"query": "ALPHA"},
    "assignments_search": {"query": "ALPHA", "include_hidden": True},
    "assignments_calendar": {**WINDOW, "include_hidden": True},
    "schedule_find_conflicts": {**WINDOW},
    "schedule_find_stale": {"threshold_days": 0},
    "schedule_find_free_time": {"duration_minutes": 30, **WINDOW},
    "settings_get": {},
    "notes_create": {"body": "bob note"},
    "goals_create": {"title": "bob goal 2"},
}


def _as_b(w: dict[str, Any]) -> Any:
    token = AccessToken(token="cmd_b", client_id=str(w["b_id"]), scopes=[], expires_at=None)
    return auth_context_var.set(AuthenticatedUser(token))


def _grant_everything(conn: sqlite3.Connection, account_id: int) -> None:
    """Open B's whole MCP permission matrix, so every refusal below is the ownership check and
    not least-privilege defaults (notes update/delete stay forced off — Hard Rule 1)."""
    matrix = settings_core.mcp_permissions(conn, account_id)
    for entity in matrix:
        for action in matrix[entity]:
            matrix[entity][action] = True
    settings_core.set_value(conn, account_id, settings_core.MCP_PERMISSIONS_KEY, matrix)
    conn.commit()


async def _call(mcp: Any, tool: str, args: dict[str, Any]) -> tuple[bool, str]:
    """(refused, text). A needs_confirm result is followed through with its token."""
    try:
        result = await mcp.call_tool(tool, args)
    except ToolError as exc:
        return True, str(exc)
    payload = result[1] if isinstance(result, tuple) else result
    text = json.dumps(payload, default=str)
    if isinstance(payload, dict) and payload.get("needs_confirm"):
        return await _call(mcp, tool, {**args, "confirm_token": payload["confirm_token"]})
    return False, text


@pytest.mark.anyio
async def test_b_mcp_tools_cannot_reach_a(world) -> None:
    w = world
    conn = w["conn"]
    _grant_everything(conn, w["b_id"])
    c, as_b = w["client"], w["B"]
    mine = _b_objects(c, as_b)
    before = _snapshot_a(w)
    mcp = build_mcp(get_settings())
    placeholders = {"__B_GOAL__": mine["goal"], "__B_ASSIGNMENT__": mine["assignment"],
                    "__B_ACTIVITY__": mine["activity"]}
    # Tools that legitimately succeed as B's own write (creating B's person with a reused slug,
    # an unfiltered summary). For them the requirement is only: nothing of A's comes back.
    may_succeed = {"delegatees_upsert", "activities_search", "activities_summary"}
    reset = _as_b(w)
    try:
        failures = []
        for tool, calls in _mcp_probes(w).items():
            for args in calls:
                args = {k: placeholders.get(v, v) if isinstance(v, str) else v for k, v in args.items()}
                refused, text = await _call(mcp, tool, args)
                if MARK in text or (not refused and tool not in may_succeed):
                    failures.append(f"{tool}({args}) -> refused={refused} {text[:160]}")
        for tool, args in _MCP_READS.items():
            refused, text = await _call(mcp, tool, args)
            if MARK in text:
                failures.append(f"{tool}({args}) leaked: {text[:160]}")
    finally:
        auth_context_var.reset(reset)
    assert not failures, "MCP cross-account access:\n  " + "\n  ".join(failures)
    assert _snapshot_a(w) == before

    # The control: the same call in A's context does return A's data, so the refusals above
    # are about WHO is asking, not a harness that could never succeed.
    token = AccessToken(token="cmd_a", client_id=str(w["a_id"]), scopes=[], expires_at=None)
    reset = auth_context_var.set(AuthenticatedUser(token))
    try:
        refused, text = await _call(mcp, "notes_get", {"note_id": w["note"]})
    finally:
        auth_context_var.reset(reset)
    assert not refused and MARK in text


@pytest.mark.anyio
async def test_every_mcp_tool_taking_an_id_is_covered(world) -> None:
    mcp = build_mcp(get_settings())
    probes = _mcp_probes(world)
    missing = []
    for tool in await mcp.list_tools():
        takes_ref = bool(_ID_ARGS & set(tool.inputSchema.get("properties", {})))
        # A tool taking an id/slug needs a probe; any other tool at least a leak read.
        covered = tool.name in probes or (not takes_ref and tool.name in _MCP_READS)
        if not covered:
            missing.append(tool.name)
    assert not missing, f"MCP tools with no isolation probe: {missing}"
