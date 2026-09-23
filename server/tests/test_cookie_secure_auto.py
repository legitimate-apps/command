"""The session cookie's Secure flag follows the transport unless it is pinned.

One published image has to work for `docker run` on a plain-http LAN and behind a TLS proxy
(Railway, a tunnel). A Secure cookie is never sent back over http, so a LAN server that set it
would accept a sign-in and then reject the very next request.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient


def _client(tmp_path, monkeypatch: pytest.MonkeyPatch, secure: str | None) -> TestClient:
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "app.db"))
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    if secure is None:
        monkeypatch.delenv("COMMAND_COOKIE_SECURE", raising=False)
    else:
        monkeypatch.setenv("COMMAND_COOKIE_SECURE", secure)
    from command.config import get_settings

    get_settings.cache_clear()
    from command.app import create_app
    from command.rest.auth import _login_limiter

    _login_limiter.clear()
    return TestClient(create_app())


@pytest.fixture(autouse=True)
def _reset() -> Iterator[None]:
    yield
    from command.config import get_settings

    get_settings.cache_clear()


def _register_cookie(client: TestClient, headers: dict[str, str] | None = None) -> str:
    r = client.post(
        "/api/auth/register",
        json={"username": "sam", "password": "supersecret"},
        headers=headers or {},
    )
    assert r.status_code == 200, r.text
    return r.headers["set-cookie"]


@pytest.mark.parametrize("value", [None, "", "auto"])
def test_plain_http_gets_a_cookie_it_can_send_back(tmp_path, monkeypatch, value) -> None:
    with _client(tmp_path, monkeypatch, value) as c:
        assert "secure" not in _register_cookie(c).lower()
        # The whole point: the next request on the same http origin is still signed in.
        assert c.get("/api/auth/me").status_code == 200


def test_https_via_proxy_header_is_secure(tmp_path, monkeypatch) -> None:
    with _client(tmp_path, monkeypatch, None) as c:
        cookie = _register_cookie(c, {"X-Forwarded-Proto": "https"})
        assert "secure" in cookie.lower()


def test_direct_https_is_secure(tmp_path, monkeypatch) -> None:
    with _client(tmp_path, monkeypatch, None) as c:
        c.base_url = c.base_url.copy_with(scheme="https")
        assert "secure" in _register_cookie(c).lower()


def test_explicit_false_wins_over_https(tmp_path, monkeypatch) -> None:
    with _client(tmp_path, monkeypatch, "false") as c:
        cookie = _register_cookie(c, {"X-Forwarded-Proto": "https"})
        assert "secure" not in cookie.lower()


def test_explicit_true_wins_over_http(tmp_path, monkeypatch) -> None:
    with _client(tmp_path, monkeypatch, "true") as c:
        assert "secure" in _register_cookie(c).lower()
