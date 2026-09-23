from __future__ import annotations

import sqlite3

import pytest
from fastapi.testclient import TestClient

from command.core import accounts, delegatee_access, delegatees
from command.errors import AuthFailed


def _register(client: TestClient, username: str = "owner") -> str:
    response = client.post(
        "/api/auth/register",
        json={"username": username, "password": "password1", "display_name": "Household"},
    )
    assert response.status_code == 200, response.text
    return client.cookies.get("command_session") or ""


def _operator_auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _person(client: TestClient, operator_token: str, name: str = "Helper") -> dict:
    response = client.post(
        "/api/delegatees", json={"name": name, "kind": "human"},
        headers=_operator_auth(operator_token),
    )
    assert response.status_code == 200, response.text
    return response.json()["delegatee"]


def _invite(client: TestClient, operator_token: str, delegatee_id: int) -> str:
    response = client.post(
        f"/api/delegatees/{delegatee_id}/invite", headers=_operator_auth(operator_token)
    )
    assert response.status_code == 200, response.text
    token = response.json()["invite_token"]
    assert token.startswith("inv-")
    # Follows the constant rather than restating it: widening the invite is a security
    # change, and a hard-coded 5 here would turn that into a test failure to "fix".
    assert len(token.split("-")) == delegatee_access._INVITE_WORDS + 1
    return token


def _redeem(client: TestClient, token: str) -> str:
    response = client.post("/api/auth/invite", json={"token": token})
    assert response.status_code == 200, response.text
    return client.cookies.get("command_session") or ""


def test_invite_stores_only_hash_and_is_single_use(conn: sqlite3.Connection) -> None:
    """Invites are single-use (2026-09 audit): a code left in a message thread used to be a
    standing key that minted a fresh 30-day session per redemption."""
    account = accounts.register(conn, "owner", "password1")
    person, _ = delegatees.upsert(conn, account.id, name="Helper")
    raw = delegatee_access.create_invite(conn, account.id, person.id)
    stored = conn.execute("SELECT token_hash FROM delegatee_invites").fetchone()["token_hash"]
    assert raw not in stored
    delegatee_access.redeem_invite(conn, raw)
    with pytest.raises(AuthFailed, match="already been used"):
        delegatee_access.redeem_invite(conn, raw)
    assert conn.execute(
        "SELECT COUNT(*) AS n FROM sessions WHERE delegatee_id = ?", (person.id,)
    ).fetchone()["n"] == 1


def test_invite_expires(conn: sqlite3.Connection, monkeypatch: pytest.MonkeyPatch) -> None:
    from datetime import timedelta

    from command.core import clock

    account = accounts.register(conn, "owner", "password1")
    person, _ = delegatees.upsert(conn, account.id, name="Helper")
    raw = delegatee_access.create_invite(conn, account.id, person.id)
    later = clock.now() + delegatee_access.INVITE_TTL + timedelta(minutes=1)
    monkeypatch.setattr(clock, "now", lambda tz=None: later)
    with pytest.raises(AuthFailed, match="expired"):
        delegatee_access.redeem_invite(conn, raw)


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", "/api/notes"),
        ("POST", "/api/notes"),
        ("GET", "/api/goals"),
        ("POST", "/api/goals"),
        ("GET", "/api/delegatees"),
        ("POST", "/api/delegatees"),
        ("GET", "/api/assignments"),
        ("POST", "/api/assignments"),
        ("GET", "/api/activities"),
        ("POST", "/api/activities"),
        ("GET", "/api/agent/threads"),
        ("POST", "/api/agent/chat"),
        ("GET", "/api/peers"),
        ("POST", "/api/peers"),
        ("GET", "/api/access-token"),
        ("POST", "/api/access-token/regenerate"),
        ("GET", "/api/calendar/subscription"),
    ],
)
def test_delegatee_session_is_closed_out_of_operator_surface(
    client: TestClient, method: str, path: str
) -> None:
    owner = _register(client)
    person = _person(client, owner)
    scoped = _redeem(client, _invite(client, owner, person["id"]))
    json_body = {"message": "hello"} if path == "/api/agent/chat" else None
    response = client.request(method, path, headers=_operator_auth(scoped), json=json_body)
    assert response.status_code in (401, 404), response.text


def test_my_assignments_and_calendar_are_sql_scoped_and_hidden_excluded(
    client: TestClient,
) -> None:
    owner = _register(client)
    mine = _person(client, owner, "Mine")
    other = _person(client, owner, "Other")
    base = {
        "schedule_kind": "sporadic",
        "scheduled_start": "2026-07-20T09:00:00+00:00",
    }
    mine_id = client.post(
        "/api/assignments", json={**base, "title": "Mine", "assignee_id": mine["id"]},
        headers=_operator_auth(owner),
    ).json()["id"]
    client.post(
        "/api/assignments", json={**base, "title": "Other", "assignee_id": other["id"]},
        headers=_operator_auth(owner),
    )
    client.post(
        "/api/assignments",
        json={**base, "title": "Hidden", "assignee_id": mine["id"], "hidden": True},
        headers=_operator_auth(owner),
    )
    client.post(
        "/api/assignments", json={**base, "title": "Unassigned"}, headers=_operator_auth(owner)
    )
    scoped = _redeem(client, _invite(client, owner, mine["id"]))
    headers = _operator_auth(scoped)
    profile = client.get("/api/my/profile", headers=headers).json()
    assert profile == {
        "delegatee_id": mine["id"], "delegatee_name": "Mine", "operator_display_name": "Household"
    }
    assert [item["id"] for item in client.get("/api/my/assignments", headers=headers).json()] == [mine_id]
    calendar = client.get(
        "/api/my/calendar", headers=headers,
        params={"start": "2026-07-20T00:00:00+00:00", "end": "2026-07-21T00:00:00+00:00"},
    ).json()
    assert [item["assignment_id"] for item in calendar] == [mine_id]


def test_scoped_status_writes_and_activity_actor(client: TestClient) -> None:
    owner = _register(client)
    mine = _person(client, owner, "Mine")
    other = _person(client, owner, "Other")
    mine_id = client.post(
        "/api/assignments", json={"title": "Mine", "assignee_id": mine["id"]},
        headers=_operator_auth(owner),
    ).json()["id"]
    other_id = client.post(
        "/api/assignments", json={"title": "Other", "assignee_id": other["id"]},
        headers=_operator_auth(owner),
    ).json()["id"]
    scoped = _redeem(client, _invite(client, owner, mine["id"]))
    headers = _operator_auth(scoped)
    assert client.post(
        f"/api/my/assignments/{mine_id}/status", json={"status": "blocked"}, headers=headers
    ).status_code == 200
    assert client.post(
        f"/api/my/assignments/{other_id}/status", json={"status": "done"}, headers=headers
    ).status_code == 404
    assert client.post(
        f"/api/my/assignments/{mine_id}/status", json={"status": "cancelled"}, headers=headers
    ).status_code == 422
    activities_body = client.get(
        "/api/activities", params={"assignment_id": mine_id}, headers=_operator_auth(owner)
    ).json()
    assert activities_body["items"][0]["actor_id"] == mine["id"]


def test_occurrence_status_is_scoped_and_appends_actor_activity(client: TestClient) -> None:
    owner = _register(client)
    mine = _person(client, owner, "Mine")
    other = _person(client, owner, "Other")
    routine = {
        "schedule_kind": "routine", "rrule": "FREQ=DAILY",
        "scheduled_start": "2026-07-20T09:00:00+00:00",
    }
    mine_id = client.post(
        "/api/assignments", json={**routine, "title": "Mine", "assignee_id": mine["id"]},
        headers=_operator_auth(owner),
    ).json()["id"]
    other_id = client.post(
        "/api/assignments", json={**routine, "title": "Other", "assignee_id": other["id"]},
        headers=_operator_auth(owner),
    ).json()["id"]
    scoped = _redeem(client, _invite(client, owner, mine["id"]))
    headers = _operator_auth(scoped)
    path = f"/api/my/assignments/{mine_id}/occurrences/2026-07-20/status"
    assert client.post(path, json={"status": "done"}, headers=headers).status_code == 200
    assert client.post(
        f"/api/my/assignments/{other_id}/occurrences/2026-07-20/status",
        json={"status": "done"}, headers=headers,
    ).status_code == 404
    activity = client.get(
        "/api/activities", params={"assignment_id": mine_id}, headers=_operator_auth(owner)
    ).json()["items"][0]
    assert activity["actor_id"] == mine["id"] and activity["occurrence_date"] == "2026-07-20"


def test_regenerate_and_revoke_kill_sessions_and_old_invite(client: TestClient) -> None:
    owner = _register(client)
    person = _person(client, owner)
    old_invite = _invite(client, owner, person["id"])
    old_session = _redeem(client, old_invite)
    new_invite = _invite(client, owner, person["id"])
    assert client.get("/api/my/profile", headers=_operator_auth(old_session)).status_code == 401
    assert client.post("/api/auth/invite", json={"token": old_invite}).status_code == 401
    new_session = _redeem(client, new_invite)
    assert client.delete(
        f"/api/delegatees/{person['id']}/invite", headers=_operator_auth(owner)
    ).status_code == 204
    assert client.get("/api/my/profile", headers=_operator_auth(new_session)).status_code == 401
    assert client.post("/api/auth/invite", json={"token": new_invite}).status_code == 401


@pytest.mark.parametrize("action", ["deactivate", "delete"])
def test_deactivate_or_delete_delegatee_kills_access(client: TestClient, action: str) -> None:
    owner = _register(client)
    person = _person(client, owner)
    invite = _invite(client, owner, person["id"])
    scoped = _redeem(client, invite)
    if action == "deactivate":
        response = client.post(
            "/api/delegatees",
            json={"name": person["name"], "slug": person["slug"], "kind": "human", "active": False},
            headers=_operator_auth(owner),
        )
    else:
        response = client.delete(
            f"/api/delegatees/{person['id']}", headers=_operator_auth(owner)
        )
    assert response.status_code == 200
    assert client.get("/api/my/profile", headers=_operator_auth(scoped)).status_code == 401
    assert client.post("/api/auth/invite", json={"token": invite}).status_code == 401


def test_invite_creation_is_operator_only_human_only_and_active_only(client: TestClient) -> None:
    owner = _register(client)
    human = _person(client, owner)
    scoped = _redeem(client, _invite(client, owner, human["id"]))
    assert client.post(
        f"/api/delegatees/{human['id']}/invite", headers=_operator_auth(scoped)
    ).status_code == 404
    ai = client.post(
        "/api/delegatees", json={"name": "Bot", "kind": "ai_model"},
        headers=_operator_auth(owner),
    ).json()["delegatee"]
    assert client.post(
        f"/api/delegatees/{ai['id']}/invite", headers=_operator_auth(owner)
    ).status_code == 422
    client.post(
        "/api/delegatees", json={"name": human["name"], "slug": human["slug"], "active": False},
        headers=_operator_auth(owner),
    )
    assert client.post(
        f"/api/delegatees/{human['id']}/invite", headers=_operator_auth(owner)
    ).status_code == 422


def test_invite_redeem_rate_limit_matches_login(client: TestClient) -> None:
    from command.config import get_settings

    for _ in range(get_settings().login_max_attempts):
        assert client.post("/api/auth/invite", json={"token": "inv-invalid"}).status_code == 401
    assert client.post("/api/auth/invite", json={"token": "inv-invalid"}).status_code == 429


def test_delegatee_push_register_stamps_delegatee_id(client: TestClient) -> None:
    operator_token = _register(client, "push-owner")
    person = _person(client, operator_token, name="Pusher")
    invite = _invite(client, operator_token, person["id"])
    session = _redeem(client, invite)

    response = client.post(
        "/api/my/push/register",
        json={"token": "DELEGATEE_DEVICE", "environment": "sandbox"},
        headers={"Authorization": f"Bearer {session}"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["delegatee_id"] == person["id"]

    # The operator push surface stays closed to delegatee sessions...
    closed = client.post(
        "/api/push/register",
        json={"token": "X"},
        headers={"Authorization": f"Bearer {session}"},
    )
    assert closed.status_code == 404
    # ...and /api/my/push is closed to operator sessions (no delegatee bound).
    reverse = client.post(
        "/api/my/push/register",
        json={"token": "Y"},
        headers={"Authorization": f"Bearer {operator_token}"},
    )
    assert reverse.status_code in (401, 403, 404)

    # Unregister removes it.
    removed = client.post(
        "/api/my/push/unregister",
        json={"token": "DELEGATEE_DEVICE"},
        headers={"Authorization": f"Bearer {session}"},
    )
    assert removed.status_code == 200 and removed.json()["removed"] is True
