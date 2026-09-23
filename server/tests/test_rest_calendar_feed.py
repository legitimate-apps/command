"""The iCal subscription feed — the most exposed surface in the app, and it had no REST tests.

`/api/calendar.ics` authenticates on a token in the *query string*, because Apple Calendar sends
no cookie. That makes it the one endpoint whose credential lives in a URL, gets stored in a
calendar client, and is polled unattended forever. Coverage put `rest/calendar_ics.py` at 56%
with the whole feed body unexercised.

What has to hold, and now does under test:

* a forged or foreign token yields nothing, and says nothing about whether the account exists;
* the feed is scoped to exactly the account its token names;
* **hidden items never appear** — the veil matters more here than anywhere else in the codebase,
  because unlike an agent read this output is a long-lived URL sitting in someone's calendar app;
* with export unconfigured the endpoint is simply absent rather than half-working.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

SECRET = "test-calendar-export-secret"


@pytest.fixture
def feed_client(tmp_path, monkeypatch: pytest.MonkeyPatch):
    """The standard client, plus calendar export switched on."""
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "feed.db"))
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.setenv("COMMAND_CALENDAR_EXPORT_SECRET", SECRET)
    monkeypatch.setenv("COMMAND_PUBLIC_BASE_URL", "https://example.invalid")
    # The cross-account test below needs a second account; signup is first-user-only now.
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


def _register(c: TestClient, username: str) -> None:
    r = c.post("/api/auth/register", json={"username": username, "password": "password1"})
    assert r.status_code < 400, r.text


def _subscribe_url(c: TestClient) -> str:
    r = c.get("/api/calendar/subscription")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["enabled"] == "true"
    return body["url"]


def test_the_subscription_url_is_issued_and_the_feed_serves_ical(feed_client: TestClient) -> None:
    _register(feed_client, "cal-owner")
    feed_client.post("/api/assignments", json={
        "title": "Dentist", "schedule_kind": "sporadic",
        "scheduled_start": "2026-09-01T14:00:00+00:00",
    })
    url = _subscribe_url(feed_client)
    assert url.startswith("https://example.invalid/api/calendar.ics?token=")

    r = feed_client.get(url.removeprefix("https://example.invalid"))
    assert r.status_code == 200, r.text
    assert r.headers["content-type"].startswith("text/calendar")
    assert "BEGIN:VCALENDAR" in r.text
    assert "Dentist" in r.text


def test_a_hidden_assignment_is_never_exported(feed_client: TestClient) -> None:
    """The veil, on a long-lived public URL rather than an agent read.

    An agent leak is bounded by a conversation; this output is stored by a calendar client and
    re-fetched unattended for as long as the subscription exists.
    """
    _register(feed_client, "cal-veil")
    created = feed_client.post("/api/assignments", json={
        "title": "SECRET therapy appointment", "schedule_kind": "sporadic",
        "scheduled_start": "2026-09-02T10:00:00+00:00", "hidden": True,
    })
    assert created.status_code < 400, created.text
    assert created.json()["hidden"] is True, "precondition: the assignment really is veiled"

    body = feed_client.get(_subscribe_url(feed_client).removeprefix("https://example.invalid")).text
    assert "SECRET" not in body, "a hidden assignment must never reach the exported calendar"


def test_a_forged_token_reveals_nothing(feed_client: TestClient) -> None:
    _register(feed_client, "cal-forge")
    r = feed_client.get("/api/calendar.ics?token=not-a-real-token")
    assert r.status_code == 404
    assert "SECRET" not in r.text


def test_one_accounts_token_never_serves_another_accounts_calendar(feed_client: TestClient) -> None:
    _register(feed_client, "cal-a")
    feed_client.post("/api/assignments", json={
        "title": "Alpha private meeting", "schedule_kind": "sporadic",
        "scheduled_start": "2026-09-03T10:00:00+00:00",
    })
    a_url = _subscribe_url(feed_client).removeprefix("https://example.invalid")
    feed_client.post("/api/auth/logout")

    _register(feed_client, "cal-b")
    feed_client.post("/api/assignments", json={
        "title": "Bravo other meeting", "schedule_kind": "sporadic",
        "scheduled_start": "2026-09-03T11:00:00+00:00",
    })
    b_url = _subscribe_url(feed_client).removeprefix("https://example.invalid")

    assert a_url != b_url, "each account must get its own token"
    a_body = feed_client.get(a_url).text
    b_body = feed_client.get(b_url).text
    assert "Alpha private meeting" in a_body and "Bravo other meeting" not in a_body
    assert "Bravo other meeting" in b_body and "Alpha private meeting" not in b_body


def test_the_feed_is_absent_when_export_is_not_configured(client: TestClient) -> None:
    """The default `client` fixture sets no export secret — the feature must be off, not broken."""
    r = client.post("/api/auth/register", json={"username": "cal-off", "password": "password1"})
    assert r.status_code < 400, r.text
    assert client.get("/api/calendar/subscription").json() == {"enabled": "false", "url": None}
    assert client.get("/api/calendar.ics?token=anything").status_code == 404
