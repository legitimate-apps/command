"""Inbound A2A surface tests — card, auth, turn execution, context threading,
metering, rate limit. The model is faked by monkeypatching runner.run."""

import json
import uuid

import pytest

from command.core.agent.runner import AgentResult
from command.core.peers import inbound

FORBIDDEN_PII = ("<operator>", "<surname>", "<prior-handle>")


def _register(client, username="a2auser", consent=True):
    r = client.post(
        "/api/auth/register", json={"username": username, "password": "pw12345678"}
    )
    assert r.status_code in (200, 201), r.text
    if consent:
        assert client.post("/api/agent/consent", json={}).status_code == 200
    r = client.get("/api/access-token")
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def _rpc(client, token, text, context_id=None):
    message = {
        "messageId": str(uuid.uuid4()),
        "role": "ROLE_USER",
        "parts": [{"text": text}],
    }
    if context_id:
        message["contextId"] = context_id
    return client.post(
        "/a2a",
        json={
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "SendMessage",
            "params": {"message": message},
        },
        headers={"Authorization": f"Bearer {token}"} if token else {},
    )


@pytest.fixture
def fake_runner(monkeypatch):
    calls = []

    async def fake_run(db_path, account_id, message, **kwargs):
        calls.append({"message": message, "history": kwargs.get("history")})
        return AgentResult(
            output=f"echo: {message}", model="test-model", input_tokens=10, output_tokens=5
        )

    from command.core.agent import runner

    monkeypatch.setattr(runner, "run", fake_run)
    inbound._rate.clear()
    return calls


def test_card_served_and_pii_free(client):
    r = client.get("/.well-known/agent-card.json")
    assert r.status_code == 200
    card = r.json()
    assert card["name"] == "Command"
    assert card["supportedInterfaces"][0]["protocolBinding"] == "JSONRPC"
    assert card["capabilities"]["streaming"] is False
    lowered = json.dumps(card).lower()
    for token in FORBIDDEN_PII:
        assert token not in lowered


def test_missing_or_bad_token_401(client, fake_runner):
    r = _rpc(client, None, "hi")
    assert r.status_code == 401
    r = _rpc(client, "cmd_not-a-real-token-0000", "hi")
    assert r.status_code == 401
    # No account-existence hints in the body.
    assert "account" not in r.text.lower()


def test_send_message_runs_turn_and_replies(client, fake_runner):
    token = _register(client)
    r = _rpc(client, token, "what's planned today?")
    assert r.status_code == 200, r.text
    result = r.json()["result"]
    reply = result["message"]
    assert reply["role"] == "ROLE_AGENT"
    assert reply["parts"] == [{"text": "echo: what's planned today?"}]
    assert reply["contextId"].startswith(inbound.CONTEXT_PREFIX)


def test_context_continues_same_thread(client, fake_runner):
    token = _register(client)
    first = _rpc(client, token, "first").json()["result"]["message"]
    ctx = first["contextId"]
    second = _rpc(client, token, "second", context_id=ctx).json()["result"]["message"]
    assert second["contextId"] == ctx
    # Second run saw the first exchange as history.
    assert fake_runner[1]["history"] == [("user", "first"), ("assistant", "echo: first")]


def test_unknown_context_is_actionable_error(client, fake_runner):
    token = _register(client)
    r = _rpc(client, token, "hi", context_id="cmd-thread-99999")
    body = r.json()
    assert "error" in body
    assert "context" in body["error"]["message"].lower()


def test_turn_is_metered_and_logged(client, fake_runner):
    token = _register(client)
    _rpc(client, token, "meter me")
    r = client.get("/api/agent/usage")
    assert r.status_code == 200
    assert r.json()["cost_usd"] > 0

    from command.config import get_settings
    from command.db import connection

    with connection(get_settings().db_path) as conn:
        row = conn.execute(
            "SELECT direction, status, request_text, response_text FROM peer_exchanges"
        ).fetchone()
    assert (row["direction"], row["status"]) == ("in", "ok")
    assert row["request_text"] == "meter me"
    assert row["response_text"] == "echo: meter me"


def test_consent_required_before_inbound_turns(client, fake_runner):
    token = _register(client, username="noconsent", consent=False)
    r = _rpc(client, token, "hi")
    body = r.json()
    assert "error" in body
    assert "disclosure" in body["error"]["message"].lower()
    # After consent, the turn runs.
    r = client.post("/api/agent/consent", json={})
    assert r.status_code == 200
    r = _rpc(client, token, "hi again")
    assert "result" in r.json()


def test_rate_limit_is_actionable(client, fake_runner, monkeypatch):
    token = _register(client)
    monkeypatch.setattr(inbound._rate, "_max", 2)
    _rpc(client, token, "one")
    _rpc(client, token, "two")
    r = _rpc(client, token, "three")
    body = r.json()
    assert "error" in body
    assert "rate limit" in body["error"]["message"].lower()
