from __future__ import annotations

import sqlite3
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def conn(tmp_path: object) -> Iterator[sqlite3.Connection]:
    from command.db import connect, init_db

    db = str(tmp_path / "t.db")  # type: ignore[operator]
    init_db(db)
    c = connect(db)
    try:
        yield c
    finally:
        c.close()


@pytest.fixture
def client(tmp_path: object, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "app.db"))  # type: ignore[operator]
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")

    from command.config import get_settings

    get_settings.cache_clear()
    from command.app import create_app
    from command.rest.auth import _invite_limiter, _login_limiter

    _login_limiter.clear()  # isolate the module-level login rate limiter between tests
    _invite_limiter.clear()
    with TestClient(create_app()) as c:
        yield c
    get_settings.cache_clear()


@pytest.fixture
def open_signup_client(tmp_path: object, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    """A server with signup deliberately reopened (`COMMAND_ALLOW_REGISTRATION=true`).

    The default is first-user-only, so anything testing multi-account signup has to opt in the
    same way an operator would.
    """
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "open.db"))  # type: ignore[operator]
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.setenv("COMMAND_ALLOW_REGISTRATION", "true")

    from command.config import get_settings

    get_settings.cache_clear()
    from command.app import create_app
    from command.rest.auth import _invite_limiter, _login_limiter

    _login_limiter.clear()
    _invite_limiter.clear()
    with TestClient(create_app()) as c:
        yield c
    get_settings.cache_clear()
