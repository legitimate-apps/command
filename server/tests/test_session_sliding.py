"""Sliding (rolling) app sessions.

The original design gave a session a *fixed* 30-day life: `expires_at` was stamped at
login and never moved again, so an account in daily use was signed out exactly 30x24h
after logging in — per device, staggered by whenever each device last logged in. This
suite pins the replacement contract:

  * an *active* session slides forward and never hits a wall (idle timeout, not a fixed one);
  * the client's cookie slides with it (a server-side-only slide would still die at the
    cookie's own `max-age`), including on endpoints that return a Response object directly;
  * the renewal is throttled, so we don't write the DB + re-cookie on every request;
  * an *idle* session still expires, and an absolute cap still forces periodic re-auth.

Time travel is the server's own scenario clock (`COMMAND_FAKE_NOW_FILE`), so these are
real end-to-end HTTP assertions rather than unit-mocked clocks.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

T0 = datetime(2026, 3, 1, 12, 0, 0, tzinfo=UTC)


class Scenario:
    """A TestClient plus a dial that moves the server's notion of `now`."""

    def __init__(self, client: TestClient, clock_file: Path, db_path: str) -> None:
        self.client = client
        self._clock_file = clock_file
        self.db_path = db_path

    def travel_to(self, when: datetime) -> None:
        self._clock_file.write_text(when.isoformat())

    def advance(self, **delta: float) -> None:
        self.travel_to(self.now + timedelta(**delta))

    @property
    def now(self) -> datetime:
        return datetime.fromisoformat(self._clock_file.read_text().strip())

    def sessions(self) -> list[sqlite3.Row]:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try:
            return list(conn.execute("SELECT * FROM sessions ORDER BY created_at"))
        finally:
            conn.close()

    def expires_at(self) -> datetime:
        rows = self.sessions()
        assert len(rows) == 1, f"expected exactly one session, got {len(rows)}"
        return datetime.fromisoformat(rows[0]["expires_at"])


def _make_scenario(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, **env: str
) -> Iterator[Scenario]:
    clock_file = tmp_path / "now.txt"
    clock_file.write_text(T0.isoformat())
    db_path = str(tmp_path / "app.db")

    monkeypatch.setenv("COMMAND_FAKE_NOW_FILE", str(clock_file))
    monkeypatch.setenv("COMMAND_DB_PATH", db_path)
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    for key, value in env.items():
        monkeypatch.setenv(key, value)

    from command.config import get_settings

    get_settings.cache_clear()
    from command.app import create_app
    from command.rest.auth import _invite_limiter, _login_limiter

    _login_limiter.clear()
    _invite_limiter.clear()
    with TestClient(create_app()) as client:
        yield Scenario(client, clock_file, db_path)
    get_settings.cache_clear()


@pytest.fixture
def scenario(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Scenario]:
    yield from _make_scenario(tmp_path, monkeypatch)


def _register(scenario: Scenario, username: str = "sam") -> None:
    r = scenario.client.post(
        "/api/auth/register", json={"username": username, "password": "supersecret"}
    )
    assert r.status_code == 200, r.text


def _session_cookie_header(response) -> str | None:
    for name, value in response.headers.multi_items():
        if name.lower() == "set-cookie" and value.startswith("command_session="):
            return value
    return None


# ---------- the fix ----------

def test_active_session_never_hits_the_fixed_wall(scenario: Scenario) -> None:
    """A session used regularly stays valid indefinitely — the original bug, inverted.

    Under the fixed-window design the T0+40d call below returned 401 and dumped the user
    to the sign-in screen mid-use.
    """
    _register(scenario)
    assert scenario.expires_at() == T0 + timedelta(days=30)

    scenario.advance(days=20)
    r = scenario.client.get("/api/auth/me")
    assert r.status_code == 200, r.text
    # expiry slid to now + the idle window, so 30 days of runway starts over
    assert scenario.expires_at() == T0 + timedelta(days=50)

    for _ in range(6):  # ~4 months of ordinary use, well past the old 30-day wall
        scenario.advance(days=20)
        assert scenario.client.get("/api/auth/me").status_code == 200
    assert scenario.expires_at() == T0 + timedelta(days=170)


def test_slide_reissues_the_cookie_so_the_client_expiry_moves_too(scenario: Scenario) -> None:
    """Server-side renewal alone is not enough: URLSession/the browser drops the cookie at
    its own `max-age`, which was also stamped once at login."""
    _register(scenario)

    scenario.advance(days=20)
    r = scenario.client.get("/api/auth/me")
    assert r.status_code == 200
    cookie = _session_cookie_header(r)
    assert cookie is not None, "renewed session must re-issue the cookie"
    assert "Max-Age=2592000" in cookie  # a fresh 30 days, not the remainder of the old one
    assert "HttpOnly" in cookie and "Path=/" in cookie


def test_renewal_is_throttled_not_per_request(scenario: Scenario) -> None:
    """One DB write + one Set-Cookie per renew interval, not on every call."""
    _register(scenario)
    baseline = scenario.expires_at()

    scenario.advance(hours=1)
    r = scenario.client.get("/api/auth/me")
    assert r.status_code == 200
    assert _session_cookie_header(r) is None, "should not re-cookie within the renew interval"
    assert scenario.expires_at() == baseline

    scenario.advance(hours=25)  # now past the 24h renew interval
    r = scenario.client.get("/api/auth/me")
    assert r.status_code == 200
    assert _session_cookie_header(r) is not None
    assert scenario.expires_at() > baseline


def test_the_slide_reaches_endpoints_that_return_a_response_object(scenario: Scenario) -> None:
    """The refresh is injected at the ASGI layer, so FileResponse/StreamingResponse
    endpoints (attachment downloads, the agent SSE stream) refresh the cookie too — a
    dependency-injected `Response` would silently drop it for exactly these."""
    _register(scenario)
    client = scenario.client

    note_id = client.post("/api/notes", json={"body": "with an attachment"}).json()["id"]
    up = client.post(
        "/api/attachments",
        data={"entity_kind": "note", "entity_id": str(note_id)},
        files={"file": ("doc.txt", b"hello", "text/plain")},
    )
    assert up.status_code == 200, up.text
    attachment_id = up.json()["id"]

    scenario.advance(days=2)
    r = client.get(f"/api/attachments/{attachment_id}/download")
    assert r.status_code == 200, r.text
    assert r.content == b"hello"
    assert _session_cookie_header(r) is not None, "FileResponse must carry the refreshed cookie"


def test_delegatee_sessions_slide_too(scenario: Scenario) -> None:
    """Delegatees are other people; a silent 30-day logout is how a delegatee stops using
    the app altogether."""
    client = scenario.client
    _register(scenario)
    delegatee_id = client.post("/api/delegatees", json={"name": "Dana", "kind": "human"}).json()[
        "delegatee"
    ]["id"]
    token = client.post(f"/api/delegatees/{delegatee_id}/invite").json()["invite_token"]

    client.cookies.clear()  # the delegatee is a different device
    assert client.post("/api/auth/invite", json={"token": token}).status_code == 200

    scenario.advance(days=25)
    r = client.get("/api/my/profile")
    assert r.status_code == 200, r.text
    assert _session_cookie_header(r) is not None

    scenario.advance(days=25)  # past the original fixed 30-day window
    assert client.get("/api/my/profile").status_code == 200


# ---------- what must still expire ----------

def test_idle_session_still_expires(scenario: Scenario) -> None:
    """Sliding is an *idle* timeout, not immortality."""
    _register(scenario)
    scenario.advance(days=31)
    assert scenario.client.get("/api/auth/me").status_code == 401


def test_expired_rows_are_reaped_at_the_next_login(scenario: Scenario) -> None:
    """The read path's own DELETE is rolled back with the 401 transaction, so expired rows
    would otherwise accumulate forever for a device that never signs in again."""
    _register(scenario)
    scenario.advance(days=31)
    assert scenario.client.get("/api/auth/me").status_code == 401
    assert len(scenario.sessions()) == 1  # still there — the 401 rolled the delete back

    r = scenario.client.post("/api/auth/login", json={"username": "sam", "password": "supersecret"})
    assert r.status_code == 200, r.text
    rows = scenario.sessions()
    assert len(rows) == 1, "the stale row is gone; only the fresh session remains"
    assert datetime.fromisoformat(rows[0]["created_at"]) == scenario.now


def test_absolute_cap_forces_periodic_reauth(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A stolen cookie must not be usable forever just because it's being used."""
    gen = _make_scenario(tmp_path, monkeypatch, COMMAND_SESSION_ABSOLUTE_DAYS="60")
    scenario = next(gen)
    try:
        _register(scenario)
        scenario.advance(days=20)
        assert scenario.client.get("/api/auth/me").status_code == 200
        scenario.advance(days=20)  # T0+40d, still inside the 60-day cap
        assert scenario.client.get("/api/auth/me").status_code == 200
        scenario.advance(days=21)  # T0+61d — past the cap despite continuous use
        assert scenario.client.get("/api/auth/me").status_code == 401
    finally:
        next(gen, None)


def test_absolute_cap_of_zero_disables_the_cap(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    gen = _make_scenario(tmp_path, monkeypatch, COMMAND_SESSION_ABSOLUTE_DAYS="0")
    scenario = next(gen)
    try:
        _register(scenario)
        for _ in range(30):  # ~2 years of use
            scenario.advance(days=25)
            assert scenario.client.get("/api/auth/me").status_code == 200
    finally:
        next(gen, None)


def test_logout_still_kills_the_session_immediately(scenario: Scenario) -> None:
    _register(scenario)
    assert scenario.client.post("/api/auth/logout").status_code == 200
    assert scenario.sessions() == []
    assert scenario.client.get("/api/auth/me").status_code == 401
