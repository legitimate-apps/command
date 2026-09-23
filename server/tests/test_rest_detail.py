from __future__ import annotations

from fastapi.testclient import TestClient


def _auth(client: TestClient, name: str = "owner") -> None:
    r = client.post("/api/auth/register", json={"username": name, "password": "password1"})
    assert r.status_code == 200


def test_assignment_notes_and_origin(client: TestClient) -> None:
    _auth(client)
    a = client.post("/api/assignments", json={"title": "Plan party"}).json()
    assert a["origin"] == "manual"
    assert a["notes"] is None
    r = client.patch(f"/api/assignments/{a['id']}", json={"notes": "venue: home; budget 200"})
    assert r.status_code == 200
    assert r.json()["notes"] == "venue: home; budget 200"
    # round-trips on read
    assert client.get(f"/api/assignments/{a['id']}").json()["notes"] == "venue: home; budget 200"


def test_goal_notes(client: TestClient) -> None:
    _auth(client)
    g = client.post("/api/goals", json={"title": "Get fit"}).json()
    assert g["notes"] is None
    r = client.patch(f"/api/goals/{g['id']}", json={"notes": "3x/week, log every session"})
    assert r.status_code == 200
    assert r.json()["notes"] == "3x/week, log every session"


def test_checklist_crud_and_reorder(client: TestClient) -> None:
    _auth(client)
    aid = client.post("/api/assignments", json={"title": "Plan party"}).json()["id"]
    i1 = client.post("/api/items", json={"parent_type": "assignment", "parent_id": aid, "text": "buy cups"})
    assert i1.status_code == 201
    i1 = i1.json()
    i2 = client.post(
        "/api/items", json={"parent_type": "assignment", "parent_id": aid, "text": "book venue"}
    ).json()

    items = client.get("/api/items", params={"parent_type": "assignment", "parent_id": aid}).json()
    assert [x["text"] for x in items] == ["buy cups", "book venue"]
    assert all(x["source"] == "user" and not x["done"] for x in items)

    done = client.patch(f"/api/items/{i1['id']}", json={"done": True}).json()
    assert done["done"] is True

    reordered = client.post("/api/items/reorder", json={
        "parent_type": "assignment", "parent_id": aid, "ordered_ids": [i2["id"], i1["id"]],
    }).json()
    assert [x["text"] for x in reordered] == ["book venue", "buy cups"]

    assert client.delete(f"/api/items/{i1['id']}").status_code == 204
    items = client.get("/api/items", params={"parent_type": "assignment", "parent_id": aid}).json()
    assert [x["text"] for x in items] == ["book venue"]


def test_checklist_scoped_to_account(open_signup_client: TestClient) -> None:
    # Two accounts on one server, so signup has to be open the way an operator would set it.
    client = open_signup_client
    _auth(client, "owner_a")
    aid = client.post("/api/assignments", json={"title": "A"}).json()["id"]
    item_id = client.post(
        "/api/items", json={"parent_type": "assignment", "parent_id": aid, "text": "mine"}
    ).json()["id"]
    # Register a second account (new session cookie) — it must not see or touch the first's items.
    _auth(client, "owner_b")
    assert client.get("/api/items", params={"parent_type": "assignment", "parent_id": aid}).json() == []
    assert client.patch(f"/api/items/{item_id}", json={"done": True}).status_code == 404
    assert client.delete(f"/api/items/{item_id}").status_code == 404
