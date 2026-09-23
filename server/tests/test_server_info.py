"""GET /api/server/info and the owner-set model key (PUT/DELETE /api/server/ai-key).

The contract is docs/specs/2026-09-23-command-cloud.md ("Server contract"); the iOS onboarding
is built against these exact shapes.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Callable, Iterator
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from command import __version__
from command.config import Settings, get_settings
from command.core.ai import client as ai_client
from command.core.ai import key as ai_key

REAL_LOOKING_KEY = "sk-or-v1-" + "0123456789abcdef" * 4
PASSWORD = "correct-horse-battery"

ClientFactory = Callable[..., TestClient]


@pytest.fixture
def make_client(tmp_path, monkeypatch: pytest.MonkeyPatch) -> Iterator[ClientFactory]:
    """Build a server from env, as an operator would configure one."""
    opened: list[Any] = []

    def factory(**env: str) -> TestClient:
        monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "srv.db"))
        monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
        monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
        monkeypatch.delenv("COMMAND_AI_API_KEY", raising=False)
        for k, v in env.items():
            monkeypatch.setenv(f"COMMAND_{k.upper()}", v)
        get_settings.cache_clear()
        from command.app import create_app

        cm = TestClient(create_app())
        opened.append(cm)
        return cm.__enter__()

    yield factory
    for cm in opened:
        cm.__exit__(None, None, None)
    get_settings.cache_clear()


@pytest.fixture
def provider(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Stub the provider check: `statuses` maps a path suffix to the HTTP status it answers."""
    state: dict[str, Any] = {"statuses": {"/key": 200}, "calls": []}

    def fake_status(url: str, key: str) -> int:
        state["calls"].append((url, key))
        if "raise" in state:
            raise state["raise"]
        for suffix, status in state["statuses"].items():
            if url.endswith(suffix):
                return int(status)
        return 404

    monkeypatch.setattr(ai_key, "_status", fake_status)
    return state


def _register(c: TestClient, username: str) -> dict[str, str]:
    r = c.post("/api/auth/register", json={"username": username, "password": PASSWORD})
    assert r.status_code == 200, r.text
    token = r.cookies.get("command_session")
    c.cookies.clear()
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------- /api/server/info


def test_info_exact_shape_on_a_fresh_self_hosted_server(make_client) -> None:
    c = make_client()
    r = c.get("/api/server/info")  # public: no credentials
    assert r.status_code == 200
    assert r.json() == {
        "service": "command",
        "version": __version__,
        "kind": "self",
        "registration_open": True,
        "ai": {"configured": False, "requires_subscription": False, "key_settable": True},
    }
    assert __version__ == "1.1.0"


def test_self_hosted_registration_closes_once_the_owner_exists(make_client) -> None:
    c = make_client()
    _register(c, "owner")
    assert c.get("/api/server/info").json()["registration_open"] is False
    r = c.post("/api/auth/register", json={"username": "second", "password": PASSWORD})
    assert r.status_code == 403


def test_self_hosted_reopened_registration_is_reported(make_client) -> None:
    c = make_client(allow_registration="true")
    _register(c, "owner")
    assert c.get("/api/server/info").json()["registration_open"] is True


def test_cloud_follows_allow_registration(make_client) -> None:
    c = make_client(server_kind="cloud", allow_registration="true",
                    agent_require_subscription="true", ai_api_key="operator-key")
    body = c.get("/api/server/info").json()
    assert body["kind"] == "cloud"
    assert body["registration_open"] is True
    assert body["ai"] == {"configured": True, "requires_subscription": True, "key_settable": False}
    _register(c, "one")
    _register(c, "two")  # still open: Cloud is multi-tenant
    assert c.get("/api/server/info").json()["registration_open"] is True


def test_closed_cloud_refuses_even_the_first_account(make_client) -> None:
    c = make_client(server_kind="cloud")
    assert c.get("/api/server/info").json()["registration_open"] is False
    r = c.post("/api/auth/register", json={"username": "first", "password": PASSWORD})
    assert r.status_code == 403
    assert "isn't accepting new accounts" in r.json()["error"]["message"]


def test_env_key_makes_ai_configured_and_not_settable(make_client) -> None:
    c = make_client(ai_api_key="env-key")
    assert c.get("/api/server/info").json()["ai"] == {
        "configured": True, "requires_subscription": False, "key_settable": False,
    }


def test_server_kind_is_validated() -> None:
    assert Settings(server_kind=" Cloud ").server_kind == "cloud"
    assert Settings(server_kind="").server_kind == "self"
    with pytest.raises(ValueError, match="COMMAND_SERVER_KIND"):
        Settings(server_kind="hosted")


# ---------------------------------------------------------------- PUT/DELETE /api/server/ai-key


def test_owner_sets_a_validated_key_and_it_applies_live(make_client, provider, monkeypatch) -> None:
    c = make_client()
    owner = _register(c, "owner")
    r = c.put("/api/server/ai-key", json={"api_key": f"  {REAL_LOOKING_KEY}\n"}, headers=owner)
    assert r.status_code == 200, r.text
    assert r.json()["ai"] == {"configured": True, "requires_subscription": False, "key_settable": True}
    # Validated against the authenticated endpoint, with the trimmed key.
    assert provider["calls"] == [("https://openrouter.ai/api/v1/key", REAL_LOOKING_KEY)]
    assert c.get("/api/server/info").json()["ai"]["configured"] is True

    # Live: the very next model call carries the stored key — no restart.
    sent: dict[str, Any] = {}

    def fake_post(url: str, **kw: Any) -> httpx.Response:
        sent["auth"] = kw["headers"]["Authorization"]
        return httpx.Response(200, json={"choices": [{"message": {"content": "A title"}}]},
                              request=httpx.Request("POST", url))

    monkeypatch.setattr(ai_client.httpx, "post", fake_post)
    assert ai_client.complete([{"role": "user", "content": "hi"}]) == "A title"
    assert sent["auth"] == f"Bearer {REAL_LOOKING_KEY}"


def test_stored_key_is_sealed_at_rest_and_never_returned(make_client, provider) -> None:
    c = make_client()
    owner = _register(c, "owner")
    responses = [c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)]
    for path in ("/api/server/info", "/api/settings", "/api/auth/me", "/api/agent/entitlement"):
        responses.append(c.get(path, headers=owner))
    assert all(REAL_LOOKING_KEY not in r.text for r in responses)
    conn = sqlite3.connect(get_settings().db_path)
    try:
        rows = conn.execute("SELECT key, value FROM instance_meta").fetchall()
    finally:
        conn.close()
    stored = dict(rows)[ai_key.META_KEY]
    assert REAL_LOOKING_KEY not in stored and "sk-or" not in stored
    # And it opens back up to exactly the key (fresh process: empty cache).
    ai_key.reset_cache()
    assert ai_key.api_key() == REAL_LOOKING_KEY


def test_delete_clears_the_key(make_client, provider) -> None:
    c = make_client()
    owner = _register(c, "owner")
    c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)
    r = c.delete("/api/server/ai-key", headers=owner)
    assert r.status_code == 200
    assert r.json()["ai"]["configured"] is False
    assert ai_key.api_key() is None
    assert c.delete("/api/server/ai-key", headers=owner).status_code == 200  # idempotent


def test_rejected_key_is_invalid_key_and_not_stored(make_client, provider) -> None:
    provider["statuses"] = {"/key": 401}
    c = make_client()
    owner = _register(c, "owner")
    r = c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "invalid_key"
    assert r.json()["error"]["hint"]
    assert c.get("/api/server/info").json()["ai"]["configured"] is False


def test_malformed_key_is_refused_before_any_provider_call(make_client, provider) -> None:
    c = make_client()
    owner = _register(c, "owner")
    r = c.put("/api/server/ai-key", json={"api_key": "sk-or two words"}, headers=owner)
    assert r.json()["error"]["code"] == "invalid_key"
    assert provider["calls"] == []


def test_providers_without_a_key_endpoint_fall_back_to_models(make_client, provider) -> None:
    provider["statuses"] = {"/models": 200}  # /key answers 404
    c = make_client(ai_base_url="https://llm.example.com/v1")
    owner = _register(c, "owner")
    r = c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)
    assert r.status_code == 200, r.text
    assert [u for u, _ in provider["calls"]] == [
        "https://llm.example.com/v1/key", "https://llm.example.com/v1/models",
    ]


def test_unreachable_provider_is_502_and_nothing_stored(make_client, provider) -> None:
    provider["raise"] = httpx.ConnectError("no route")
    c = make_client()
    owner = _register(c, "owner")
    r = c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)
    assert r.status_code == 502
    assert r.json()["error"]["code"] == "provider_unavailable"
    assert ai_key.api_key() is None


def test_only_the_owner_may_set_the_key(make_client, provider) -> None:
    c = make_client(allow_registration="true")
    _register(c, "owner")
    second = _register(c, "second")
    for r in (
        c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=second),
        c.delete("/api/server/ai-key", headers=second),
    ):
        assert r.status_code == 403
        assert r.json()["error"]["code"] == "not_owner"
    assert provider["calls"] == []


def test_env_key_is_managed_by_env(make_client, provider) -> None:
    c = make_client(ai_api_key="env-key")
    owner = _register(c, "owner")
    r = c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "managed_by_env"
    assert c.delete("/api/server/ai-key", headers=owner).json()["error"]["code"] == "managed_by_env"


def test_cloud_key_is_never_settable_from_the_app(make_client, provider) -> None:
    c = make_client(server_kind="cloud", allow_registration="true")  # even with no env key
    owner = _register(c, "first")
    r = c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "managed_by_env"


def test_ai_key_requires_a_session(make_client) -> None:
    c = make_client()
    assert c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}).status_code == 401


def test_env_key_wins_over_a_stored_one(make_client, provider, monkeypatch) -> None:
    c = make_client()
    owner = _register(c, "owner")
    c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)
    monkeypatch.setattr(get_settings(), "ai_api_key", "env-key")
    assert ai_key.api_key() == "env-key"


def test_a_key_sealed_under_another_instance_secret_reads_as_unset(
    make_client, provider, monkeypatch
) -> None:
    c = make_client()
    owner = _register(c, "owner")
    c.put("/api/server/ai-key", json={"api_key": REAL_LOOKING_KEY}, headers=owner)
    monkeypatch.setattr(get_settings(), "peer_token_key", "a-different-instance-secret")
    ai_key.reset_cache()
    assert ai_key.api_key() is None
    assert c.get("/api/server/info").json()["ai"]["configured"] is False
