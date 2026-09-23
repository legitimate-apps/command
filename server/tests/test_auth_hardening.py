"""Auth + outbound-fetch hardening (2026-09 audit). Each test failed on the pre-fix code.

- fetch_url validated a hostname's DNS answer and then let httpx resolve it AGAIN to connect,
  so a rebinding host could pass the check with a public IP and connect to loopback. It and the
  peer fetcher also accepted 100.64.0.0/10 (neither "private" nor global).
- The login limiter tracked every username ever tried, forever.
- An unknown username skipped bcrypt entirely — a timing oracle for which usernames exist.
- A password over bcrypt's 72-byte limit made register / account deletion 500.
"""

from __future__ import annotations

import socket
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from command.core import accounts
from command.core.agent import tools
from command.core.peers import safefetch
from command.core.ratelimit import SlidingWindowLimiter
from command.errors import AuthFailed

PUBLIC = "93.184.216.34"


def _addrinfo(ip: str) -> list[Any]:
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 443))]


def test_fetch_url_connects_to_the_address_it_validated(monkeypatch: pytest.MonkeyPatch) -> None:
    answers = iter([PUBLIC, "127.0.0.1", "127.0.0.1"])   # rebinding: public first, then loopback
    lookups: list[str] = []

    def fake_getaddrinfo(host: str, *args: Any, **kwargs: Any) -> list[Any]:
        lookups.append(host)
        return _addrinfo(next(answers))

    monkeypatch.setattr(socket, "getaddrinfo", fake_getaddrinfo)
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, text="hello", headers={"content-type": "text/plain"})

    real_client = httpx.Client
    monkeypatch.setattr(
        tools.httpx, "Client", lambda **kw: real_client(transport=httpx.MockTransport(handler), **kw)
    )
    final, text = tools._fetch_public_url("https://rebind.example/page?q=1")
    assert text == "hello" and final == "https://rebind.example/page?q=1"
    req = seen[0]
    assert req.url.host == PUBLIC, "dialled a name that can be re-resolved, not the checked IP"
    assert req.headers["host"] == "rebind.example"
    assert req.extensions.get("sni_hostname") == "rebind.example"
    assert req.url.path == "/page" and req.url.query == b"q=1"
    assert lookups == ["rebind.example"], "resolved more than once"


@pytest.mark.parametrize("ip", ["100.64.1.1", "100.127.255.254", "::ffff:100.64.0.1"])
def test_cgnat_is_not_public(monkeypatch: pytest.MonkeyPatch, ip: str) -> None:
    assert not safefetch.is_public_ip(ip)
    assert not safefetch._is_public_ip(ip)
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: _addrinfo(ip))
    with pytest.raises(ValueError, match="non-public"):
        tools._validate_public_url("http://tailnet.example/")


def test_public_addresses_still_pass() -> None:
    assert safefetch.is_public_ip(PUBLIC)
    assert safefetch.is_public_ip("2606:4700:4700::1111")
    assert not safefetch.is_public_ip("224.0.0.1")


def test_rate_limiter_table_is_bounded() -> None:
    limiter = SlidingWindowLimiter(max_attempts=3, window_seconds=600, max_keys=100)
    for i in range(1000):
        limiter.record_failure(f"user{i}")
    assert len(limiter) <= 100
    # Still does its job for a key under attack.
    for _ in range(3):
        limiter.record_failure("victim")
    assert not limiter.allowed("victim")


def test_unknown_username_still_pays_for_bcrypt(conn: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    accounts.register(conn, "real-user", "password1")
    calls: list[int] = []
    real = accounts.bcrypt.checkpw

    def counting(pw: bytes, hashed: bytes) -> bool:
        calls.append(1)
        return bool(real(pw, hashed))

    monkeypatch.setattr(accounts.bcrypt, "checkpw", counting)
    with pytest.raises(AuthFailed):
        accounts.login(conn, "nobody-here", "password1")
    assert calls == [1], "an unknown username returned without the bcrypt work"


def test_password_over_72_bytes_is_a_422_not_a_500(client: TestClient) -> None:
    long_pw = "é" * 40   # 40 characters, 80 bytes of UTF-8
    r = client.post("/api/auth/register", json={"username": "casey", "password": long_pw})
    assert r.status_code == 422 and "72 bytes" in r.json()["error"]["message"]
    assert client.post("/api/auth/register",
                       json={"username": "casey", "password": "password123"}).status_code == 200
    r = client.post("/api/account/delete", json={"password": "x" * 100})
    assert r.status_code == 422
    r = client.post("/api/auth/login", json={"username": "casey", "password": "x" * 100})
    assert r.status_code == 401
