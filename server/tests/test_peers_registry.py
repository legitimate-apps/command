"""Peers registry tests — card fetch/store, CRUD, token secrecy, exchange log."""

import sqlite3

import pytest

from command.core import accounts
from command.core.peers import registry
from command.core.peers.safefetch import PeerFetchError
from command.errors import NotFound, ValidationError

CARD = {
    "name": "Pantry",
    "description": "Home food inventory agent.",
    "supportedInterfaces": [
        {
            "url": "https://pantry.example.com/a2a",
            "protocolBinding": "JSONRPC",
            "protocolVersion": "1.0",
        }
    ],
    "version": "1.0.0",
    "capabilities": {"streaming": False, "pushNotifications": False},
    "defaultInputModes": ["text/plain"],
    "defaultOutputModes": ["text/plain"],
    "skills": [{"id": "pantry", "name": "Pantry", "description": "Inventory", "tags": []}],
}


@pytest.fixture
def account_id(conn: sqlite3.Connection) -> int:
    return accounts.register(conn, "peeruser", "pw12345678").id


def _fake_fetch(card=CARD):
    calls = []

    def fetch(url, **kwargs):
        calls.append(url)
        return dict(card)

    fetch.calls = calls
    return fetch


def test_add_peer_fetches_card_and_stores(conn, account_id):
    fetch = _fake_fetch()
    peer = registry.add_peer(
        conn, account_id, "https://pantry.example.com", token="tok-1", _fetch=fetch
    )
    assert peer.name == "pantry"
    assert peer.url == "https://pantry.example.com/a2a"
    assert peer.card["description"] == "Home food inventory agent."
    assert peer.has_token is True
    assert peer.enabled is True
    # Bare base URL gets the well-known path appended.
    assert fetch.calls == ["https://pantry.example.com/.well-known/agent-card.json"]


def test_add_peer_full_card_url_used_verbatim(conn, account_id):
    fetch = _fake_fetch()
    registry.add_peer(
        conn,
        account_id,
        "https://pantry.example.com/.well-known/agent-card.json",
        token=None,
        _fetch=fetch,
    )
    assert fetch.calls == ["https://pantry.example.com/.well-known/agent-card.json"]


def test_add_peer_duplicate_names_get_suffix(conn, account_id):
    fetch = _fake_fetch()
    first = registry.add_peer(conn, account_id, "https://a.example.com", token=None, _fetch=fetch)
    second = registry.add_peer(conn, account_id, "https://b.example.com", token=None, _fetch=fetch)
    assert first.name == "pantry"
    assert second.name == "pantry-2"


def test_add_peer_invalid_card_rejected(conn, account_id):
    bad = {"name": "X"}  # no supportedInterfaces
    with pytest.raises(ValidationError):
        registry.add_peer(
            conn, account_id, "https://x.example.com", token=None, _fetch=_fake_fetch(bad)
        )


def test_add_peer_fetch_error_propagates(conn, account_id):
    def fetch(url, **kwargs):
        raise PeerFetchError("blocked_url", "public HTTPS only")

    with pytest.raises(PeerFetchError):
        registry.add_peer(conn, account_id, "https://10.0.0.1", token=None, _fetch=fetch)


def test_token_never_in_peer_model_and_encrypted_at_rest(conn, account_id):
    registry.add_peer(
        conn, account_id, "https://pantry.example.com", token="tok-secret", _fetch=_fake_fetch()
    )
    peers = registry.list_peers(conn, account_id)
    assert peers[0].has_token is True
    assert "tok-secret" not in peers[0].model_dump_json()
    row = conn.execute("SELECT token_ciphertext FROM peers").fetchone()
    assert row["token_ciphertext"] is not None
    assert "tok-secret" not in row["token_ciphertext"]
    # But the outbound path can recover it.
    assert registry.get_token(conn, account_id, "pantry") == "tok-secret"


def test_get_update_delete_and_scoping(conn, account_id):
    other = accounts.register(conn, "other", "pw12345678").id
    registry.add_peer(conn, account_id, "https://pantry.example.com", token=None, _fetch=_fake_fetch())

    assert registry.get_peer(conn, account_id, "pantry").name == "pantry"
    with pytest.raises(NotFound):
        registry.get_peer(conn, other, "pantry")

    updated = registry.update_peer(conn, account_id, "pantry", enabled=False)
    assert updated.enabled is False
    updated = registry.update_peer(conn, account_id, "pantry", token="tok-new")
    assert updated.has_token is True
    assert registry.get_token(conn, account_id, "pantry") == "tok-new"
    updated = registry.update_peer(conn, account_id, "pantry", token=None)
    assert updated.has_token is False

    registry.delete_peer(conn, account_id, "pantry")
    with pytest.raises(NotFound):
        registry.get_peer(conn, account_id, "pantry")


def test_refresh_card(conn, account_id):
    registry.add_peer(conn, account_id, "https://pantry.example.com", token=None, _fetch=_fake_fetch())
    newer = dict(CARD, description="Now with price book.")
    refreshed = registry.refresh_card(conn, account_id, "pantry", _fetch=_fake_fetch(newer))
    assert refreshed.card["description"] == "Now with price book."


def test_log_exchange_and_scoping(conn, account_id):
    peer = registry.add_peer(
        conn, account_id, "https://pantry.example.com", token=None, _fetch=_fake_fetch()
    )
    registry.log_exchange(
        conn,
        account_id,
        peer_id=peer.id,
        direction="out",
        context_id="ctx-1",
        request_text="do we have tomatoes?",
        response_text="yes, 3",
        status="ok",
    )
    registry.log_exchange(
        conn,
        account_id,
        peer_id=None,
        direction="in",
        context_id=None,
        request_text="what's on the calendar?",
        response_text=None,
        status="error:busy",
    )
    rows = conn.execute(
        "SELECT direction, status FROM peer_exchanges WHERE account_id = ? ORDER BY id",
        (account_id,),
    ).fetchall()
    assert [(r["direction"], r["status"]) for r in rows] == [("out", "ok"), ("in", "error:busy")]


def test_allow_http_hosts_parsing(monkeypatch):
    from command.config import get_settings

    monkeypatch.setenv("COMMAND_PEER_ALLOW_HTTP_HOSTS", "10.0.0.5, localhost")
    get_settings.cache_clear()
    try:
        assert registry._allow_http_hosts() == frozenset({"10.0.0.5", "localhost"})
    finally:
        get_settings.cache_clear()


def test_prod_refuses_missing_or_dev_token_key(monkeypatch):
    # get_settings() fills a generated key in prod (test_config_instance); this guards the
    # key derivation itself, so a Settings that somehow skipped that step still fails closed.
    from command.config import Settings
    from command.core import sealed

    for bad in ("", "dev-insecure-peer-token-key"):
        s = Settings(environment="prod", peer_token_key=bad)
        monkeypatch.setattr(sealed, "get_settings", lambda s=s: s)
        with pytest.raises(RuntimeError):
            registry._encrypt_token("a-token")
