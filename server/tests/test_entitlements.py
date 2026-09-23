"""Entitlements + AI consent + subscription gate + the RevenueCat webhook.

Gating defaults OFF, so the agent is never locked out before billing is live; these
tests drive the flag explicitly. No network — the gate short-circuits before any
model call.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from command.config import get_settings
from command.core import accounts, entitlements
from command.core.agent import usage
from command.db import connection


def _auth(client: TestClient) -> None:
    assert client.post(
        "/api/auth/register", json={"username": "owner", "password": "password1"}
    ).status_code == 200


def _future_iso() -> str:
    return (datetime.now(UTC) + timedelta(days=7)).isoformat()


def _past_iso() -> str:
    return (datetime.now(UTC) - timedelta(days=1)).isoformat()


def _ms(days_from_now: int) -> int:
    return int((datetime.now(UTC) + timedelta(days=days_from_now)).timestamp() * 1000)


def test_entitlement_core(conn: object) -> None:
    aid = accounts.register(conn, "ent-owner", "password1").id  # type: ignore[arg-type]
    assert entitlements.get(conn, aid).status == "none"  # type: ignore[arg-type]
    assert entitlements.is_active(conn, aid) is False  # type: ignore[arg-type]

    entitlements.set_entitlement(  # type: ignore[arg-type]
        conn, aid, product_id="p", status="active", expires_at=_future_iso(), will_renew=True
    )
    assert entitlements.is_active(conn, aid) is True  # type: ignore[arg-type]

    entitlements.set_entitlement(conn, aid, product_id="p", status="active", expires_at=_past_iso())  # type: ignore[arg-type]
    assert entitlements.is_active(conn, aid) is False  # expired  # type: ignore[arg-type]

    entitlements.set_entitlement(conn, aid, product_id="p", status="grace", expires_at=_future_iso())  # type: ignore[arg-type]
    assert entitlements.is_active(conn, aid) is True  # grace, unexpired  # type: ignore[arg-type]

    entitlements.grant_comp(conn, aid)  # type: ignore[arg-type]
    assert entitlements.is_active(conn, aid) is True  # comp never expires  # type: ignore[arg-type]

    first = entitlements.record_consent(conn, aid).consent_at  # type: ignore[arg-type]
    assert first is not None
    assert entitlements.record_consent(conn, aid).consent_at == first  # idempotent  # type: ignore[arg-type]
    assert entitlements.has_consent(conn, aid) is True  # type: ignore[arg-type]


def test_entitlement_endpoint_and_consent(client: TestClient) -> None:
    _auth(client)
    e = client.get("/api/agent/entitlement").json()
    assert e["active"] is False and e["requires_subscription"] is False
    assert e["product_id"] and e["price_display"] and e["trial_days"] == 7
    assert e["consent_given"] is False

    e2 = client.post("/api/agent/consent").json()
    assert e2["consent_given"] is True
    # idempotent over the wire
    assert client.post("/api/agent/consent").json()["consent_given"] is True


def test_chat_subscription_gate(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    _auth(client)
    s = get_settings()
    monkeypatch.setattr(s, "ai_api_key", "test-key-not-real")
    monkeypatch.setattr(s, "agent_require_subscription", True)

    # consent is a hard precondition of /chat (checked before the subscription gate)
    with connection(s.db_path) as conn:
        owner = conn.execute("SELECT id FROM accounts WHERE username = 'owner'").fetchone()[0]
        entitlements.record_consent(conn, owner)

    # inactive account -> blocked, no model call
    r = client.post("/api/agent/chat", json={"message": "hi"})
    assert r.status_code == 200 and "subscription_required" in r.text

    # entitled (comp) -> gate passes; force over-cap so it returns cap_reached (still no network)
    with connection(s.db_path) as conn:
        aid = conn.execute("SELECT id FROM accounts WHERE username = 'owner'").fetchone()[0]
        entitlements.grant_comp(conn, aid)
        usage.record(conn, aid, "anthropic/claude-opus-5", 4_000_000, 0)  # > $10 cap
    r2 = client.post("/api/agent/chat", json={"message": "hi"})
    assert "cap_reached" in r2.text and "subscription_required" not in r2.text


def test_revenuecat_webhook(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    _auth(client)
    s = get_settings()
    monkeypatch.setattr(s, "revenuecat_webhook_token", "wh-secret")
    with connection(s.db_path) as conn:
        aid = conn.execute("SELECT id FROM accounts WHERE username = 'owner'").fetchone()[0]

    hdr = {"Authorization": "Bearer wh-secret"}
    # missing / wrong token -> 401
    assert client.post("/api/webhooks/revenuecat", json={"event": {}}).status_code == 401
    assert client.post(
        "/api/webhooks/revenuecat", json={"event": {}}, headers={"Authorization": "Bearer nope"}
    ).status_code == 401

    # INITIAL_PURCHASE (trial) -> active
    ev = {"event": {
        "type": "INITIAL_PURCHASE", "app_user_id": str(aid), "product_id": "command_pro_monthly",
        "period_type": "TRIAL", "store": "APP_STORE", "expiration_at_ms": _ms(7),
    }}
    r = client.post("/api/webhooks/revenuecat", json=ev, headers=hdr)
    assert r.status_code == 200 and r.json()["ok"] is True
    ent = client.get("/api/agent/entitlement").json()
    assert ent["active"] is True and ent["status"] == "active" and ent["period_type"] == "trial"

    # EXPIRATION -> inactive
    ev2 = {"event": {
        "type": "EXPIRATION", "app_user_id": str(aid),
        "product_id": "command_pro_monthly", "expiration_at_ms": _ms(-1),
    }}
    assert client.post("/api/webhooks/revenuecat", json=ev2, headers=hdr).status_code == 200
    assert client.get("/api/agent/entitlement").json()["active"] is False

    # anonymous subject -> 200 no-op
    anon = {"event": {"type": "INITIAL_PURCHASE", "app_user_id": "$RCAnonymousID:abc"}}
    assert client.post("/api/webhooks/revenuecat", json=anon, headers=hdr).status_code == 200
