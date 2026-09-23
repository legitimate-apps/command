"""RevenueCat identity + event ordering (2026-09 audit). Each test failed on the pre-fix code.

- The RevenueCat customer was the bare account id, and every self-hosted instance has an
  account 1 — so customers collided across instances. The app now logs in as
  `billing_user_id` = `<instance_id>:<account_id>`, served on GET /api/agent/entitlement.
- UNCANCELLATION / PRODUCT_CHANGE refilled the budget; a redelivery with a new event id did
  too; and an older event arriving late overwrote a newer one.
"""

from __future__ import annotations

import re
from typing import Any

import pytest
from fastapi.testclient import TestClient

from command.config import get_settings
from command.core import entitlements
from command.db import connect, connection, init_db

TOKEN = "test-webhook-token"
ID_RE = re.compile(r"^([0-9a-f]{32}):([0-9]+)$")


@pytest.fixture
def hook(tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "bill.db"))
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.setenv("COMMAND_REVENUECAT_WEBHOOK_TOKEN", TOKEN)
    monkeypatch.setenv("COMMAND_CREDITS_ENABLED", "true")
    get_settings.cache_clear()
    from command.app import create_app
    from command.rest.auth import _invite_limiter, _login_limiter

    _login_limiter.clear()
    _invite_limiter.clear()
    with TestClient(create_app()) as c:
        r = c.post("/api/auth/register", json={"username": "buyer", "password": "password1"})
        assert r.status_code == 200
        yield c, r.json()["id"]
    get_settings.cache_clear()


def _post(c: TestClient, **event: Any) -> Any:
    r = c.post("/api/webhooks/revenuecat", json={"event": event},
               headers={"Authorization": f"Bearer {TOKEN}"})
    assert r.status_code == 200, r.text
    return r


def _ent(account_id: int) -> entitlements.Entitlement:
    with connection(get_settings().db_path) as conn:
        return entitlements.get(conn, account_id)


def test_entitlement_serves_a_stable_instance_scoped_billing_id(hook: Any) -> None:
    c, aid = hook
    first = c.get("/api/agent/entitlement").json()["billing_user_id"]
    m = ID_RE.match(first)
    assert m is not None and int(m.group(2)) == aid
    assert "/" not in first and len(first) <= 100          # RevenueCat's constraints
    assert c.get("/api/agent/entitlement").json()["billing_user_id"] == first
    init_db(get_settings().db_path)                        # re-running migrations never rotates it
    assert c.get("/api/agent/entitlement").json()["billing_user_id"] == first


def test_two_instances_get_different_ids(tmp_path: Any) -> None:
    ids = []
    for name in ("a.db", "b.db"):
        path = str(tmp_path / name)
        init_db(path)
        ids.append(entitlements.billing_user_id(connect(path), 1))
    assert ids[0] != ids[1]


def test_webhook_accepts_this_instance_and_legacy_ids_and_ignores_others(hook: Any) -> None:
    c, aid = hook
    mine = c.get("/api/agent/entitlement").json()["billing_user_id"]
    _post(c, type="INITIAL_PURCHASE", app_user_id=mine, id="e1", event_timestamp_ms=1000,
          purchased_at_ms=1000, expiration_at_ms=4102444800000)
    assert _ent(aid).status == "active"

    foreign = "0" * 32 + f":{aid}"   # the same account NUMBER on someone else's server
    _post(c, type="EXPIRATION", app_user_id=foreign, id="e2", event_timestamp_ms=2000)
    assert _ent(aid).status == "active", "another instance's customer changed this account"

    _post(c, type="EXPIRATION", app_user_id=str(aid), id="e3", event_timestamp_ms=3000)
    assert _ent(aid).status == "expired"   # legacy bare id still honoured


def test_alias_resolves_a_customer_who_bought_before_logging_in(hook: Any) -> None:
    c, aid = hook
    mine = c.get("/api/agent/entitlement").json()["billing_user_id"]
    _post(c, type="INITIAL_PURCHASE", app_user_id="$RCAnonymousID:abc",
          original_app_user_id="$RCAnonymousID:abc", aliases=["$RCAnonymousID:abc", mine],
          id="e1", event_timestamp_ms=1000, purchased_at_ms=1000, expiration_at_ms=4102444800000)
    assert _ent(aid).status == "active"


def test_out_of_order_events_are_ignored(hook: Any) -> None:
    c, aid = hook
    _post(c, type="RENEWAL", app_user_id=str(aid), id="new", event_timestamp_ms=2000,
          purchased_at_ms=2000, expiration_at_ms=4102444800000)
    _post(c, type="EXPIRATION", app_user_id=str(aid), id="old", event_timestamp_ms=1000)
    assert _ent(aid).status == "active", "a late, older EXPIRATION undid a newer RENEWAL"


def test_budget_refills_once_per_paid_period_only(hook: Any) -> None:
    c, aid = hook
    base: dict[str, Any] = {"app_user_id": str(aid), "expiration_at_ms": 4102444800000}
    _post(c, type="INITIAL_PURCHASE", id="p1", event_timestamp_ms=1000, purchased_at_ms=1000, **base)
    full = _ent(aid).ai_budget_usd_remaining
    assert full > 0
    with connection(get_settings().db_path) as conn:
        entitlements.debit_budget(conn, aid, full / 2)
    spent = _ent(aid).ai_budget_usd_remaining

    # Not a new period: none of these may refill.
    _post(c, type="UNCANCELLATION", id="u1", event_timestamp_ms=1100, **base)
    _post(c, type="PRODUCT_CHANGE", id="c1", event_timestamp_ms=1200, **base)
    _post(c, type="INITIAL_PURCHASE", id="p1-dup-new-id", event_timestamp_ms=1300,
          purchased_at_ms=1000, **base)
    assert _ent(aid).ai_budget_usd_remaining == pytest.approx(spent)

    # A genuine renewal (a new period) does.
    _post(c, type="RENEWAL", id="r2", event_timestamp_ms=5000, purchased_at_ms=5000, **base)
    assert _ent(aid).ai_budget_usd_remaining == pytest.approx(full)
