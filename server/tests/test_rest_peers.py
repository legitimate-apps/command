"""Peer-management REST tests — auth, CRUD, token secrecy, SSRF error mapping."""

import pytest

from command.core.peers import registry
from command.core.peers.safefetch import PeerFetchError

CARD = {
    "name": "Pantry",
    "description": "Home food inventory agent.",
    "supportedInterfaces": [
        {"url": "https://pantry.example.com/a2a", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}
    ],
    "version": "1.0.0",
    "capabilities": {"streaming": False},
    "defaultInputModes": ["text/plain"],
    "defaultOutputModes": ["text/plain"],
    "skills": [],
}


@pytest.fixture
def logged_in(client):
    r = client.post("/api/auth/register", json={"username": "peerrest", "password": "pw12345678"})
    assert r.status_code in (200, 201), r.text
    return client


@pytest.fixture
def card_fetch(monkeypatch):
    def fetch(url, **kwargs):
        return dict(CARD)

    monkeypatch.setattr(registry, "safe_https_json", fetch)
    return fetch


def test_peers_require_auth(client):
    assert client.get("/api/peers").status_code in (401, 403)


def test_add_list_get_update_delete(logged_in, card_fetch):
    c = logged_in
    r = c.post("/api/peers", json={"card_url": "https://pantry.example.com", "token": "tok-x"})
    assert r.status_code == 201, r.text
    peer = r.json()
    assert peer["name"] == "pantry"
    assert peer["has_token"] is True
    assert "tok-x" not in r.text

    r = c.get("/api/peers")
    assert [p["name"] for p in r.json()] == ["pantry"]
    assert "tok-x" not in r.text

    r = c.get("/api/peers/pantry")
    assert r.json()["card"]["description"] == "Home food inventory agent."

    r = c.patch("/api/peers/pantry", json={"enabled": False})
    assert r.json()["enabled"] is False
    r = c.patch("/api/peers/pantry", json={"token": None})
    assert r.json()["has_token"] is False

    assert c.delete("/api/peers/pantry").status_code == 204
    assert c.get("/api/peers/pantry").status_code == 404


def test_blocked_url_is_422_with_friendly_message(logged_in, monkeypatch):
    def fetch(url, **kwargs):
        raise PeerFetchError("blocked_url", "nope")

    monkeypatch.setattr(registry, "safe_https_json", fetch)
    r = logged_in.post("/api/peers", json={"card_url": "https://10.0.0.5"})
    assert r.status_code == 422
    assert "public HTTPS" in r.text


def test_inbound_info_has_urls_but_no_token(logged_in):
    r = logged_in.get("/api/peers/inbound-info")
    assert r.status_code == 200
    body = r.json()
    assert body["a2a_url"].endswith("/a2a")
    assert body["card_url"].endswith("/.well-known/agent-card.json")
    assert "cmd_" not in r.text  # access token never echoed here
