"""Per-client-IP limits on registration and login, and how the client IP is chosen."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from starlette.requests import Request

from command.config import get_settings
from command.rest.client_ip import client_ip

PASSWORD = "correct-horse-battery"


def _request(peer: str, *xff: str) -> Request:
    headers = [(b"x-forwarded-for", v.encode()) for v in xff]
    return Request({"type": "http", "headers": headers, "client": (peer, 5000)})


def test_zero_hops_ignores_forwarded_for() -> None:
    assert client_ip(_request("10.0.0.9", "192.168.1.66"), 0) == "10.0.0.9"


def test_one_hop_takes_the_entry_the_proxy_added() -> None:
    # The client forged "1.2.3.4"; the proxy appended the address it really saw.
    assert client_ip(_request("10.0.0.1", "1.2.3.4, 192.168.1.66"), 1) == "192.168.1.66"


def test_two_hops_and_multiple_headers() -> None:
    req = _request("10.0.0.1", "1.2.3.4", "192.168.1.66, 10.0.0.2")
    assert client_ip(req, 2) == "192.168.1.66"


def test_fewer_entries_than_hops_uses_the_first_real_one() -> None:
    assert client_ip(_request("10.0.0.1", "192.168.1.66"), 2) == "192.168.1.66"


def test_no_header_falls_back_to_the_peer() -> None:
    assert client_ip(_request("10.0.0.9"), 1) == "10.0.0.9"


def _client(tmp_path, monkeypatch: pytest.MonkeyPatch, **env: str) -> TestClient:
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "ip.db"))
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.setenv("COMMAND_ALLOW_REGISTRATION", "true")
    for k, v in env.items():
        monkeypatch.setenv(f"COMMAND_{k.upper()}", v)
    get_settings.cache_clear()
    from command.app import create_app

    return TestClient(create_app())


def test_registration_is_limited_per_address(tmp_path, monkeypatch) -> None:
    limit = get_settings().register_ip_max_attempts
    with _client(tmp_path, monkeypatch) as c:
        for i in range(limit):
            r = c.post("/api/auth/register", json={"username": f"user{i}", "password": PASSWORD})
            assert r.status_code == 200, r.text
            c.cookies.clear()
        r = c.post("/api/auth/register", json={"username": "one-more", "password": PASSWORD})
        assert r.status_code == 429
        assert r.json()["error"]["code"] == "rate_limited"
        # Forging X-Forwarded-For does not buy a new bucket when no proxy is trusted.
        r = c.post("/api/auth/register", json={"username": "forged", "password": PASSWORD},
                   headers={"X-Forwarded-For": "192.168.1.77"})
        assert r.status_code == 429
    get_settings.cache_clear()


def test_behind_a_trusted_proxy_each_client_has_its_own_bucket(tmp_path, monkeypatch) -> None:
    limit = get_settings().register_ip_max_attempts
    with _client(tmp_path, monkeypatch, trusted_proxy_hops="1") as c:
        for i in range(limit):
            r = c.post("/api/auth/register", json={"username": f"user{i}", "password": PASSWORD},
                       headers={"X-Forwarded-For": "192.168.1.10"})
            assert r.status_code == 200
            c.cookies.clear()
        blocked = c.post("/api/auth/register", json={"username": "extra-one", "password": PASSWORD},
                         headers={"X-Forwarded-For": "192.168.1.10"})
        other = c.post("/api/auth/register", json={"username": "extra-two", "password": PASSWORD},
                       headers={"X-Forwarded-For": "192.168.1.11"})
        assert blocked.status_code == 429
        assert other.status_code == 200
    get_settings.cache_clear()


def test_failed_logins_are_limited_per_address_across_usernames(tmp_path, monkeypatch) -> None:
    with _client(tmp_path, monkeypatch) as c:
        c.post("/api/auth/register", json={"username": "victim", "password": PASSWORD})
        c.cookies.clear()
        limit = get_settings().login_ip_max_failures
        per_user = get_settings().login_max_attempts
        # Spray: never more than the per-username limit on any one name.
        for i in range(limit):
            r = c.post("/api/auth/login", json={"username": f"name{i // per_user}", "password": "wrong"})
            assert r.status_code == 401
        # The address is now blocked, even for a correct password on an untouched username.
        r = c.post("/api/auth/login", json={"username": "victim", "password": PASSWORD})
        assert r.status_code == 429
    get_settings.cache_clear()
