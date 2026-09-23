"""The REST half of the UNSET contract: over the wire, an omitted field must stay
unchanged while an explicit JSON `null` clears the column.

This is what `model_dump(exclude_unset=True)` buys. Dumping every field would forward
`None` for each omitted one — which now means "clear" — and a PATCH of one field would
silently wipe the rest of the record.
"""

from __future__ import annotations

from fastapi.testclient import TestClient


def _auth(client: TestClient) -> None:
    assert (
        client.post("/api/auth/register", json={"username": "owner", "password": "password1"}).status_code
        == 200
    )


def _goal(client: TestClient, title: str = "Ship it", **kw: object) -> int:
    r = client.post("/api/goals", json={"title": title, **kw})
    assert r.status_code in (200, 201), r.text
    return int(r.json()["id"])


def _assignment(client: TestClient, **kw: object) -> int:
    r = client.post("/api/assignments", json={"title": "Draft post", **kw})
    assert r.status_code in (200, 201), r.text
    return int(r.json()["id"])


def test_patch_one_field_leaves_the_others_alone(client: TestClient) -> None:
    """The regression guard: a narrow PATCH must not wipe omitted fields."""
    _auth(client)
    gid = _goal(client)
    aid = _assignment(client, goal_id=gid, scheduled_start="2026-06-20T09:00:00+00:00",
                      lead_time_minutes=120, details="context")

    r = client.patch(f"/api/assignments/{aid}", json={"title": "Renamed"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["title"] == "Renamed"
    assert body["goal_id"] == gid, "omitted goal_id must not be cleared"
    assert body["scheduled_start"] == "2026-06-20T09:00:00+00:00"
    assert body["lead_time_minutes"] == 120
    assert body["details"] == "context"


def test_explicit_null_unlinks_the_goal(client: TestClient) -> None:
    _auth(client)
    gid = _goal(client)
    aid = _assignment(client, goal_id=gid)

    r = client.patch(f"/api/assignments/{aid}", json={"goal_id": None})
    assert r.status_code == 200, r.text
    assert r.json()["goal_id"] is None


def test_explicit_null_clears_a_goal_target_date(client: TestClient) -> None:
    _auth(client)
    gid = _goal(client, target_date="2026-10-21")
    assert client.get(f"/api/goals/{gid}").json()["target_date"] == "2026-10-21"

    r = client.patch(f"/api/goals/{gid}", json={"target_date": None})
    assert r.status_code == 200, r.text
    assert r.json()["target_date"] is None


def test_goal_patch_of_status_keeps_target_date(client: TestClient) -> None:
    _auth(client)
    gid = _goal(client, target_date="2026-10-21", description="why")
    r = client.patch(f"/api/goals/{gid}", json={"status": "in_progress"})
    assert r.status_code == 200, r.text
    assert r.json()["target_date"] == "2026-10-21"
    assert r.json()["description"] == "why"
