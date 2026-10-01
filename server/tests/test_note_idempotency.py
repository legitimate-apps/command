"""Retry contracts and visibility at the actual ASGI response boundary."""
from __future__ import annotations

import asyncio
import json

import httpx
import pytest
from fastapi.testclient import TestClient


def _auth(client: TestClient, username: str = "owner") -> None:
    assert client.post(
        "/api/auth/register", json={"username": username, "password": "password1"}
    ).status_code == 200


def test_note_replay_returns_current_row_regardless_of_body(client: TestClient) -> None:
    _auth(client)
    headers = {"Idempotency-Key": "capture-1"}
    first = client.post("/api/notes", headers=headers, json={"body": "draft"})
    assert first.status_code == 201
    note_id = first.json()["id"]
    client.patch(f"/api/notes/{note_id}", json={"body": "edited", "title": "Final"})
    replay = client.post("/api/notes", headers=headers, json={"body": "different"})
    assert replay.status_code == 201
    assert replay.json()["id"] == note_id
    assert replay.json()["body"] == "edited"
    assert replay.json()["title"] == "Final"
    assert len(client.get("/api/notes").json()["items"]) == 1
    assert client.post(
        "/api/notes", headers=headers, json={"body": "", "source": "invalid"}
    ).json()["id"] == note_id


def test_note_without_key_still_creates_each_time(client: TestClient) -> None:
    _auth(client)
    ids = [client.post("/api/notes", json={"body": "same"}).json()["id"] for _ in range(2)]
    assert ids[0] != ids[1]
    assert len(client.get("/api/notes").json()["items"]) == 2


def test_note_replay_does_not_queue_title_again(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    from command.core import ai

    _auth(client)
    monkeypatch.setattr(ai, "enabled", lambda: True)
    jobs: list[tuple[int, int]] = []
    monkeypatch.setattr(ai, "generate_and_save_title", lambda nid, aid: jobs.append((nid, aid)))
    client.post("/api/agent/consent")
    headers = {"Idempotency-Key": "title-job-1"}
    first = client.post("/api/notes", headers=headers, json={"body": "draft"})
    replay = client.post("/api/notes", headers=headers, json={"body": "draft"})
    assert replay.json()["id"] == first.json()["id"]
    assert len(jobs) == 1


@pytest.mark.parametrize("key", ["", "x" * 256])
def test_note_invalid_key_is_actionable_422(client: TestClient, key: str) -> None:
    _auth(client)
    result = client.post("/api/notes", headers={"Idempotency-Key": key}, json={"body": "draft"})
    assert result.status_code == 422
    assert "255" in result.json()["error"]["message"]
    assert result.json()["error"]["hint"]
    assert client.get("/api/notes").json()["items"] == []


async def test_note_is_visible_to_immediate_get_at_response_send(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TestClient alone waits for dependency cleanup and masks this race.

    Inspect an independent DB connection while ASGI sends the create body, BEFORE
    request cleanup. Also start immediate authenticated list/detail requests. No
    mocked dependency or artificial commit delay.
    """
    from command.core import ai

    _auth(client)
    monkeypatch.setattr(ai, "enabled", lambda: False)
    from command.config import get_settings
    from command.db import connection

    observed: list[list[int]] = []
    pending: list[asyncio.Task[httpx.Response]] = []
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=client.app), base_url="http://testserver",
        cookies=dict(client.cookies),
    ) as reader:
        async def probe(scope, receive, send):
            async def inspect_send(message):
                if message["type"] == "http.response.body" and message.get("body"):
                    note_id = json.loads(message["body"])["id"]
                    with connection(get_settings().db_path) as conn:
                        observed.append([row[0] for row in conn.execute("SELECT id FROM notes")])
                    # Do not await here: on main, the GET's session touch waits
                    # for this POST to commit, so awaiting it would deadlock.
                    pending.append(asyncio.create_task(reader.get("/api/notes")))
                    pending.append(asyncio.create_task(reader.get(f"/api/notes/{note_id}")))
                await send(message)
            await client.app(scope, receive, inspect_send)

        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=probe), base_url="http://testserver",
            cookies=dict(client.cookies)
        ) as writer:
            response = await writer.post("/api/notes", json={"body": "commit boundary"})
        listed, detail = await asyncio.gather(*pending)
    assert response.status_code == 201
    assert listed.status_code == detail.status_code == 200
    assert [item["id"] for item in listed.json()["items"]] == [response.json()["id"]]
    assert detail.json()["id"] == response.json()["id"]
    assert observed == [[response.json()["id"]]]


def test_note_same_key_is_scoped_per_account(open_signup_client: TestClient) -> None:
    client = open_signup_client
    _auth(client, "owner-one")
    headers = {"Idempotency-Key": "shared-key"}
    first = client.post("/api/notes", headers=headers, json={"body": "one"}).json()
    client.post("/api/auth/logout")
    _auth(client, "owner-two")
    second = client.post("/api/notes", headers=headers, json={"body": "two"}).json()
    assert first["id"] != second["id"]
    assert first["account_id"] != second["account_id"]
    replay = client.post("/api/notes", headers=headers, json={"body": "one"}).json()
    assert replay["id"] == second["id"]
    assert replay["body"] == "two"
    assert [n["id"] for n in client.get("/api/notes").json()["items"]] == [second["id"]]


async def test_note_concurrent_rest_retries_create_one_row(client: TestClient) -> None:
    _auth(client)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=client.app), base_url="http://testserver",
        cookies=dict(client.cookies),
    ) as concurrent:
        responses = await asyncio.gather(*[
            concurrent.post(
                "/api/notes", headers={"Idempotency-Key": "parallel-key"}, json={"body": f"draft {i}"}
            ) for i in range(8)
        ])
    assert {r.status_code for r in responses} == {201}
    assert len({r.json()["id"] for r in responses}) == 1
    assert len({r.json()["body"] for r in responses}) == 1
    assert len(client.get("/api/notes").json()["items"]) == 1


def test_note_replay_survives_archive_hidden_and_full_quota(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    from command.config import get_settings
    from command.core import settings as settings_core
    from command.db import connection

    _auth(client)
    headers = {"Idempotency-Key": "x" * 255}
    first = client.post("/api/notes", headers=headers, json={"body": "private draft"}).json()
    client.patch(f"/api/notes/{first['id']}", json={"body": "edited by owner"})
    with connection(get_settings().db_path) as conn:
        settings_core.set_value(conn, first["account_id"], "mcp_permissions", {
            "notes": {"create": False, "read": False},
        })
    client.post(f"/api/notes/{first['id']}/archive")
    client.post(f"/api/notes/{first['id']}/hidden")
    monkeypatch.setattr(get_settings(), "max_notes_per_account", 1)
    replay = client.post("/api/notes", headers=headers, json={"body": ""})
    assert replay.status_code == 201
    assert replay.json()["id"] == first["id"]
    assert replay.json()["archived_at"] is not None
    assert replay.json()["hidden"] is True
    assert replay.json()["body"] == "edited by owner"  # app ownership, not MCP permissions
    assert "idempotency_key" not in replay.json()
    assert client.post("/api/notes", json={"body": "new"}).status_code == 403


@pytest.mark.parametrize("endpoint", ["activities", "assignments"])
def test_other_capture_creates_support_key_and_keep_unkeyed_behavior(
    client: TestClient, endpoint: str
) -> None:
    _auth(client)
    path = f"/api/{endpoint}"
    headers = {"Idempotency-Key": "capture-key"}
    first = client.post(path, headers=headers, json={"title": "original"})
    assert first.status_code == 201
    replay = client.post(path, headers=headers, json={"title": ""})
    assert replay.status_code == 201
    assert replay.json() == first.json()
    ids = [client.post(path, json={"title": "original"}).json()["id"] for _ in range(2)]
    assert len({first.json()["id"], *ids}) == 3
    invalid = client.post(path, headers={"Idempotency-Key": "x" * 256}, json={"title": "new"})
    assert invalid.status_code == 422


async def test_commit_failure_cannot_send_201_and_rolls_back(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    import sqlite3

    from command.core import ai
    from command.db import CommandConnection

    _auth(client)
    monkeypatch.setattr(ai, "enabled", lambda: False)
    commit = CommandConnection.commit
    sent: list[int] = []

    def fail_commit(conn):
        if conn.in_transaction and conn.execute("SELECT COUNT(*) FROM notes").fetchone()[0]:
            raise sqlite3.OperationalError("injected commit failure")
        commit(conn)

    async def probe(scope, receive, send):
        async def inspect_send(message):
            if message["type"] == "http.response.start":
                sent.append(message["status"])
            await send(message)
        await client.app(scope, receive, inspect_send)

    with monkeypatch.context() as patch:
        patch.setattr(CommandConnection, "commit", fail_commit)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=probe), base_url="http://testserver",
            cookies=dict(client.cookies),
        ) as writer:
            with pytest.raises(sqlite3.OperationalError, match="injected commit failure"):
                await writer.post(
                    "/api/notes", headers={"Idempotency-Key": "failed-commit"}, json={"body": "draft"}
                )
    assert sent == [500]
    assert client.get("/api/notes").json()["items"] == []
    retry = client.post(
        "/api/notes", headers={"Idempotency-Key": "failed-commit"}, json={"body": "retry"}
    )
    assert retry.status_code == 201
    assert retry.json()["body"] == "retry"
