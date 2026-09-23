from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


def _auth(client: TestClient) -> None:
    assert (
        client.post("/api/auth/register", json={"username": "owner", "password": "password1"}).status_code
        == 200
    )


def test_notes_flow(client: TestClient) -> None:
    _auth(client)
    r = client.post("/api/notes", json={"body": "buy milk", "source": "typed"})
    assert r.status_code == 201
    nid = r.json()["id"]
    assert client.get("/api/notes").json()["items"][0]["id"] == nid
    assert client.get(f"/api/notes/{nid}").json()["body"] == "buy milk"
    client.post(f"/api/notes/{nid}/processed")
    assert client.get("/api/notes", params={"unprocessed": "true"}).json()["items"] == []
    client.post(f"/api/notes/{nid}/archive")
    assert client.get("/api/notes").json()["items"] == []
    # There is intentionally no delete route for notes (404/405 — either way, no delete).
    assert client.delete(f"/api/notes/{nid}").status_code in (404, 405)


def test_notes_update_revisions_restore(client: TestClient) -> None:
    _auth(client)
    nid = client.post("/api/notes", json={"body": "draft one"}).json()["id"]
    # PATCH can set title + body; an app-set title is the user's.
    r = client.patch(f"/api/notes/{nid}", json={"title": "My Note", "body": "draft two"})
    assert r.status_code == 200
    assert r.json()["title"] == "My Note" and r.json()["title_status"] == "user"
    assert r.json()["body"] == "draft two"

    # close snapshots a backup (AI disabled in tests -> no title-gen, status stays user).
    assert client.post(f"/api/notes/{nid}/close").json()["title_status"] == "user"
    client.patch(f"/api/notes/{nid}", json={"body": "draft three"})
    client.post(f"/api/notes/{nid}/close")

    revs = client.get(f"/api/notes/{nid}/revisions").json()
    assert [v["body"] for v in revs] == ["draft three", "draft two"]  # newest first
    older = revs[-1]["id"]
    restored = client.post(f"/api/notes/{nid}/revisions/{older}/restore")
    assert restored.status_code == 200 and restored.json()["body"] == "draft two"


def test_notes_close_marks_generating_when_ai_on(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _auth(client)
    from command.core import ai

    monkeypatch.setattr(ai, "enabled", lambda: True)
    monkeypatch.setattr(ai, "generate_and_save_title", lambda *a, **k: None)
    client.post("/api/agent/consent")  # titles send note text to a third party
    nid = client.post("/api/notes", json={"body": "some thought"}).json()["id"]
    assert client.post(f"/api/notes/{nid}/close").json()["title_status"] == "generating"


def test_note_create_marks_generating_when_ai_on(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _auth(client)
    from command.core import ai

    monkeypatch.setattr(ai, "enabled", lambda: True)
    monkeypatch.setattr(ai, "generate_and_save_title", lambda *a, **k: None)
    client.post("/api/agent/consent")
    # A title-less note gets an AI title on create.
    assert client.post("/api/notes", json={"body": "buy milk"}).json()["title_status"] == "generating"
    # A note created WITH a title (the duplicate path) keeps it — no auto-gen.
    assert client.post("/api/notes", json={"body": "x", "title": "Named"}).json()["title_status"] == "user"


def test_ai_titles_need_the_same_consent_the_assistant_does(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A note title sends the note body to a third-party model, so it must not fire
    before the user has accepted the AI disclosure — Apple requires consent first,
    and the privacy policy promises it. Without consent the note keeps its
    first-line fallback and NOTHING is dispatched."""
    _auth(client)
    from command.core import ai

    dispatched: list[int] = []
    monkeypatch.setattr(ai, "enabled", lambda: True)
    monkeypatch.setattr(ai, "generate_and_save_title", lambda note_id, account_id: dispatched.append(note_id))

    created = client.post("/api/notes", json={"body": "unconsented thought"}).json()
    assert created["title_status"] != "generating"
    assert client.post(f"/api/notes/{created['id']}/close").json()["title_status"] != "generating"
    assert dispatched == []

    # Consent flips it on for subsequent notes, with no other change.
    client.post("/api/agent/consent")
    after = client.post("/api/notes", json={"body": "consented thought"}).json()
    assert after["title_status"] == "generating"


def test_delegatee_upsert_flow(client: TestClient) -> None:
    _auth(client)
    r = client.post(
        "/api/delegatees",
        json={
            "name": "Roommate",
            "kind": "human",
            "lead_time_minutes": 1440,
            "metadata": {"personality": "type_a"},
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["created"] is True
    slug = body["delegatee"]["slug"]
    r2 = client.post("/api/delegatees", json={"name": "Roommate Bob", "slug": slug, "lead_time_minutes": 60})
    assert r2.json()["created"] is False
    found = client.get("/api/delegatees/search", params={"q": "room"}).json()
    assert any(d["slug"] == slug for d in found)


def test_goal_assignment_calendar_and_assign(client: TestClient) -> None:
    _auth(client)
    goal = client.post("/api/goals", json={"title": "Ship app"}).json()
    note = client.post("/api/notes", json={"body": "an idea"}).json()
    assert (
        client.post(f"/api/goals/{goal['id']}/notes", json={"note_ids": [note["id"]]}).json()["linked"] == 1
    )

    a = client.post(
        "/api/assignments",
        json={
            "title": "Standup",
            "schedule_kind": "routine",
            "rrule": "FREQ=WEEKLY;BYDAY=MO,WE,FR",
            "scheduled_start": "2026-06-15T09:00:00+00:00",
            "goal_id": goal["id"],
        },
    ).json()
    occ = client.get(
        "/api/assignments/calendar",
        params={"start": "2026-06-15T00:00:00+00:00", "end": "2026-06-21T23:59:59+00:00"},
    ).json()
    assert [o["occurs_at"][:10] for o in occ] == ["2026-06-15", "2026-06-17", "2026-06-19"]

    d = client.post("/api/delegatees", json={"name": "Teammate", "lead_time_minutes": 30}).json()["delegatee"]
    res = client.post(f"/api/assignments/{a['id']}/assign", json={"assignee_slug": d["slug"]}).json()
    assert res["assignment"]["assignee_id"] == d["id"]


def test_activities_flow(client: TestClient) -> None:
    _auth(client)
    # Log a spontaneous fact; actor defaults to the hidden "Me".
    r = client.post("/api/activities", json={"title": "Cleaned garage", "category": "chores"})
    assert r.status_code == 201
    a = r.json()
    assert a["actor_slug"] == "me" and a["source"] == "manual"
    assert client.get("/api/activities").json()["items"][0]["id"] == a["id"]

    # Completing an assignment auto-logs a completion activity (visible over REST).
    asg = client.post("/api/assignments", json={"title": "Fix sink"}).json()
    client.post(f"/api/assignments/{asg['id']}/status", json={"status": "done"})
    by_asg = client.get("/api/activities", params={"assignment_id": asg["id"]}).json()["items"]
    assert len(by_asg) == 1 and by_asg[0]["source"] == "assignment_completion"

    # Audit summary buckets by actor+category.
    summary = client.get("/api/activities/summary").json()
    assert any(b["category"] == "chores" and b["count"] == 1 for b in summary)

    # Delete is a real route here (unlike notes).
    assert client.delete(f"/api/activities/{a['id']}").status_code == 200


def test_settings_notes_backstop(client: TestClient) -> None:
    _auth(client)
    client.put(
        "/api/settings/mcp-permissions", json={"permissions": {"notes": {"delete": True, "update": True}}}
    )
    perms = client.get("/api/settings").json()["mcp_permissions"]
    assert perms["notes"]["delete"] is False
    assert perms["notes"]["update"] is False
    assert perms["delegatees"]["delete"] is True


def test_auth_required_on_domain(client: TestClient) -> None:
    assert client.get("/api/notes").status_code == 401
    assert client.get("/api/assignments").status_code == 401
    assert client.get("/api/delegatees").status_code == 401
