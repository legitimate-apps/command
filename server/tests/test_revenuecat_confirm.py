"""Entitlement confirmation through RevenueCat's REST API (COMMAND_REVENUECAT_API_KEY).

The HTTP layer is stubbed at `revenuecat.fetch_subscriber`; the body shapes follow RevenueCat's
v1 "Get or Create Customer" reference (`GET /v1/subscribers/{app_user_id}`).
"""

from __future__ import annotations

import logging
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from command.config import Settings, get_settings
from command.core import entitlements, revenuecat

SECRET = "sk_test_secret_revenuecat_key_0000"
PASSWORD = "correct-horse-battery"


def _iso(delta: timedelta) -> str:
    return (datetime.now(UTC) + delta).strftime("%Y-%m-%dT%H:%M:%SZ")


def _body(*, expires: str | None, purchase: str | None = None, unsubscribed: bool = False,
          billing_issue: bool = False, grace: str | None = None, entitlement: str = "pro") -> dict[str, Any]:
    purchase = purchase or _iso(timedelta(days=-1))
    return {
        "request_date": _iso(timedelta()),
        "request_date_ms": int(datetime.now(UTC).timestamp() * 1000),
        "subscriber": {
            "entitlements": {
                entitlement: {
                    "expires_date": expires, "grace_period_expires_date": grace,
                    "product_identifier": "command_pro_monthly", "purchase_date": purchase,
                }
            },
            "subscriptions": {
                "command_pro_monthly": {
                    "expires_date": expires, "purchase_date": purchase, "period_type": "normal",
                    "store": "app_store", "is_sandbox": True,
                    "unsubscribe_detected_at": _iso(timedelta(hours=-1)) if unsubscribed else None,
                    "billing_issues_detected_at": _iso(timedelta(hours=-1)) if billing_issue else None,
                    "grace_period_expires_date": grace,
                }
            },
        },
    }


# ---------------------------------------------------------------- interpret


def test_active_renewing() -> None:
    c = revenuecat.interpret(_body(expires=_iso(timedelta(days=20))), "pro")
    assert (c.status, c.will_renew, c.store, c.period_type) == ("active", True, "app_store", "normal")
    assert c.product_id == "command_pro_monthly" and c.period_start_ms is not None


def test_active_but_cancelled_does_not_renew() -> None:
    c = revenuecat.interpret(_body(expires=_iso(timedelta(days=20)), unsubscribed=True), "pro")
    assert (c.status, c.will_renew) == ("active", False)


def test_billing_issue_inside_grace() -> None:
    c = revenuecat.interpret(
        _body(expires=_iso(timedelta(hours=-2)), billing_issue=True, grace=_iso(timedelta(days=3))), "pro"
    )
    assert c.status == "grace"
    assert c.expires_at is not None and datetime.fromisoformat(c.expires_at) > datetime.now(UTC)


def test_expired() -> None:
    assert revenuecat.interpret(_body(expires=_iso(timedelta(days=-2))), "pro").status == "expired"


def test_lifetime_grant_never_expires() -> None:
    c = revenuecat.interpret(_body(expires=None), "pro")
    assert c.status == "active" and c.expires_at is None


def test_other_entitlement_is_none() -> None:
    body = _body(expires=_iso(timedelta(days=5)), entitlement="other")
    assert revenuecat.interpret(body, "pro").status == "none"


# ---------------------------------------------------------------- through the endpoint


@pytest.fixture
def rc(tmp_path, monkeypatch: pytest.MonkeyPatch) -> Iterator[dict[str, Any]]:
    """A server with a RevenueCat key, a signed-in account, and a stubbed RevenueCat."""
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "rc.db"))
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.setenv("COMMAND_REVENUECAT_API_KEY", SECRET)
    get_settings.cache_clear()
    revenuecat.reset()
    state: dict[str, Any] = {"calls": [], "body": {"subscriber": {"entitlements": {}}}}

    def fake_fetch(settings: Settings, app_user_id: str) -> dict[str, Any]:
        state["calls"].append(app_user_id)
        if "raise" in state:
            raise state["raise"]
        return dict(state["body"])

    monkeypatch.setattr(revenuecat, "fetch_subscriber", fake_fetch)
    from command.app import create_app

    with TestClient(create_app()) as c:
        r = c.post("/api/auth/register", json={"username": "payer", "password": PASSWORD})
        state["client"] = c
        state["account_id"] = r.json()["id"]
        yield state
    revenuecat.reset()
    get_settings.cache_clear()


def _entitlement(state: dict[str, Any]) -> dict[str, Any]:
    r = state["client"].get("/api/agent/entitlement")
    assert r.status_code == 200, r.text
    return r.json()


def test_a_purchase_is_confirmed_without_any_webhook(rc) -> None:
    rc["body"] = _body(expires=_iso(timedelta(days=30)))
    body = _entitlement(rc)
    assert body["active"] is True and body["status"] == "active" and body["will_renew"] is True
    # Asked about exactly this account's instance-scoped billing id.
    assert rc["calls"] == [body["billing_user_id"]]


def test_refresh_is_debounced_per_account(rc) -> None:
    rc["body"] = _body(expires=_iso(timedelta(days=30)))
    _entitlement(rc)
    _entitlement(rc)
    _entitlement(rc)
    assert len(rc["calls"]) == 1


def test_an_unentitled_account_rechecks_sooner(rc, monkeypatch) -> None:
    _entitlement(rc)  # nothing bought: status none
    assert len(rc["calls"]) == 1
    _entitlement(rc)
    assert len(rc["calls"]) == 1  # inside the short window
    monkeypatch.setattr(revenuecat, "INACTIVE_REFRESH_SECONDS", 0)
    rc["body"] = _body(expires=_iso(timedelta(days=30)))
    assert _entitlement(rc)["active"] is True  # the purchase shows up on the next launch
    assert len(rc["calls"]) == 2


def test_revenuecat_expiry_demotes_a_store_subscriber(rc, monkeypatch) -> None:
    rc["body"] = _body(expires=_iso(timedelta(days=30)))
    assert _entitlement(rc)["active"] is True
    monkeypatch.setattr(get_settings(), "revenuecat_refresh_seconds", 0)
    rc["body"] = {"subscriber": {"entitlements": {}}}  # refunded / revoked: no entitlement at all
    body = _entitlement(rc)
    assert body["active"] is False and body["status"] == "expired"


def test_never_subscribed_gets_no_invented_row(rc) -> None:
    assert _entitlement(rc)["status"] == "none"


def test_comp_grants_are_sticky(rc, monkeypatch) -> None:
    from command.db import connection

    with connection(get_settings().db_path) as conn:
        entitlements.grant_comp(conn, rc["account_id"])
    rc["body"] = _body(expires=_iso(timedelta(days=-3)))
    body = _entitlement(rc)
    assert body["status"] == "comp" and body["active"] is True


def test_revenuecat_down_keeps_the_cache_and_never_logs_the_key(rc, caplog) -> None:
    rc["raise"] = httpx.ConnectError(f"boom Authorization: Bearer {SECRET}")
    with caplog.at_level(logging.DEBUG):
        body = _entitlement(rc)
    assert body["status"] == "none"
    assert SECRET not in caplog.text
    assert "RevenueCat confirmation" in caplog.text


def test_without_a_key_revenuecat_is_never_called(rc, monkeypatch) -> None:
    monkeypatch.setattr(get_settings(), "revenuecat_api_key", None)
    _entitlement(rc)
    assert rc["calls"] == []


def test_confirmation_refills_the_budget_once_per_period(rc, monkeypatch) -> None:
    monkeypatch.setattr(get_settings(), "credits_enabled", True)
    monkeypatch.setattr(get_settings(), "revenuecat_refresh_seconds", 0)
    purchase = _iso(timedelta(days=-2))
    rc["body"] = _body(expires=_iso(timedelta(days=28)), purchase=purchase)
    grant = round(get_settings().agent_subscription_price_usd / entitlements.CREDIT_MULTIPLIER, 4)
    assert _entitlement(rc)["budget_usd_remaining"] == grant
    from command.db import connection

    with connection(get_settings().db_path) as conn:
        entitlements.debit_budget(conn, rc["account_id"], 1.0)
    # Same period seen again: no refill.
    assert _entitlement(rc)["budget_usd_remaining"] == round(grant - 1.0, 4)
    # The next period (a renewal) refills.
    rc["body"] = _body(expires=_iso(timedelta(days=58)), purchase=_iso(timedelta(minutes=-5)))
    assert _entitlement(rc)["budget_usd_remaining"] == grant


def test_fetch_sends_the_key_only_as_a_bearer(monkeypatch) -> None:
    seen: dict[str, Any] = {}

    def fake_get(url: str, **kw: Any) -> httpx.Response:
        seen["url"], seen["headers"] = url, kw["headers"]
        return httpx.Response(200, json={"subscriber": {}}, request=httpx.Request("GET", url))

    monkeypatch.setattr(revenuecat.httpx, "get", fake_get)
    settings = Settings(revenuecat_api_key=SECRET)
    revenuecat.fetch_subscriber(settings, "0123456789abcdef0123456789abcdef:7")
    assert seen["url"] == ("https://api.revenuecat.com/v1/subscribers/"
                           "0123456789abcdef0123456789abcdef%3A7")
    assert seen["headers"] == {"Authorization": f"Bearer {SECRET}"}
