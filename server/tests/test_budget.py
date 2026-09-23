"""E4 — the real-USD agent budget: grant (reset each period), debit per turn, gate.

The backend always tracks real USD; "credits" are a x3 display concept on the client.
Everything here is inert unless `credits_enabled` is set, so these tests flip it on
explicitly. No test hits the network — /chat either short-circuits at a gate or runs a
monkeypatched stream.
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


def _owner_id(db_path: str) -> int:
    with connection(db_path) as conn:
        return int(conn.execute("SELECT id FROM accounts WHERE username = 'owner'").fetchone()[0])


def _future_iso() -> str:
    return (datetime.now(UTC) + timedelta(days=30)).isoformat()


def _ms(days_from_now: int) -> int:
    return int((datetime.now(UTC) + timedelta(days=days_from_now)).timestamp() * 1000)


# --- core: grant / debit / governance ---------------------------------------------

def test_budget_grant_resets_and_is_idempotent(conn: object) -> None:
    aid = accounts.register(conn, "b-owner", "password1").id  # type: ignore[arg-type]
    assert entitlements.budget_remaining(conn, aid) == 0.0  # type: ignore[arg-type]

    # First grant for a period sets the balance.
    assert entitlements.grant_budget(conn, aid, 6.66, ref="evt-1") is True  # type: ignore[arg-type]
    assert entitlements.budget_remaining(conn, aid) == 6.66  # type: ignore[arg-type]

    # Spend into the period, then a redelivered webhook (same ref) must NOT re-grant.
    entitlements.debit_budget(conn, aid, 4.0)  # type: ignore[arg-type]
    assert abs(entitlements.budget_remaining(conn, aid) - 2.66) < 1e-9  # type: ignore[arg-type]
    assert entitlements.grant_budget(conn, aid, 6.66, ref="evt-1") is False  # type: ignore[arg-type]
    assert abs(entitlements.budget_remaining(conn, aid) - 2.66) < 1e-9  # type: ignore[arg-type]

    # A genuinely new period (new ref) RESETS (not accumulates) the balance.
    assert entitlements.grant_budget(conn, aid, 6.66, ref="evt-2") is True  # type: ignore[arg-type]
    assert entitlements.budget_remaining(conn, aid) == 6.66  # type: ignore[arg-type]

    # A None ref always applies (manual/testing path).
    assert entitlements.grant_budget(conn, aid, 1.0, ref=None) is True  # type: ignore[arg-type]
    assert entitlements.budget_remaining(conn, aid) == 1.0  # type: ignore[arg-type]

    with pytest.raises(ValueError, match="non-negative"):
        entitlements.grant_budget(conn, aid, -1.0, ref="x")  # type: ignore[arg-type]


def test_budget_debit_returns_remaining_and_allows_one_overshoot(conn: object) -> None:
    aid = accounts.register(conn, "b-owner2", "password1").id  # type: ignore[arg-type]
    entitlements.grant_budget(conn, aid, 0.30, ref="p1")  # type: ignore[arg-type]
    assert entitlements.debit_budget(conn, aid, 0.10) == pytest.approx(0.20)  # type: ignore[arg-type]
    # A non-positive cost is a no-op.
    assert entitlements.debit_budget(conn, aid, 0.0) == pytest.approx(0.20)  # type: ignore[arg-type]
    # The final turn may push the balance slightly negative (overshoot bounded by one turn).
    assert entitlements.debit_budget(conn, aid, 0.50) == pytest.approx(-0.30)  # type: ignore[arg-type]


def test_is_store_subscribed_excludes_comp_and_expired(conn: object) -> None:
    aid = accounts.register(conn, "b-owner3", "password1").id  # type: ignore[arg-type]
    assert entitlements.is_store_subscribed(conn, aid) is False  # none  # type: ignore[arg-type]

    entitlements.set_entitlement(  # type: ignore[arg-type]
        conn, aid, product_id="p", status="active", expires_at=_future_iso(), will_renew=True
    )
    assert entitlements.is_store_subscribed(conn, aid) is True  # type: ignore[arg-type]

    past = (datetime.now(UTC) - timedelta(days=1)).isoformat()
    entitlements.set_entitlement(conn, aid, product_id="p", status="active", expires_at=past)  # type: ignore[arg-type]
    assert entitlements.is_store_subscribed(conn, aid) is False  # expired  # type: ignore[arg-type]

    # A comp grant is entitled but NOT budget-governed (stays on the flat cap).
    entitlements.grant_comp(conn, aid)  # type: ignore[arg-type]
    assert entitlements.is_active(conn, aid) is True  # type: ignore[arg-type]
    assert entitlements.is_store_subscribed(conn, aid) is False  # type: ignore[arg-type]


# --- webhook: budget refresh on paid-period events --------------------------------

def test_webhook_resets_budget_on_purchase_and_renewal(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _auth(client)
    s = get_settings()
    monkeypatch.setattr(s, "revenuecat_webhook_token", "wh-secret")
    monkeypatch.setattr(s, "credits_enabled", True)
    monkeypatch.setattr(s, "agent_subscription_price_usd", 19.99)
    aid = _owner_id(s.db_path)
    hdr = {"Authorization": "Bearer wh-secret"}
    grant = round(19.99 / 3, 4)  # 6.6633

    ev = {"event": {
        "id": "evt-1", "type": "INITIAL_PURCHASE", "app_user_id": str(aid),
        "product_id": "command_pro_monthly", "period_type": "NORMAL",
        "store": "APP_STORE", "expiration_at_ms": _ms(30),
    }}
    assert client.post("/api/webhooks/revenuecat", json=ev, headers=hdr).status_code == 200
    with connection(s.db_path) as conn:
        assert entitlements.budget_remaining(conn, aid) == grant

    # Spend, then a REDELIVERED INITIAL_PURCHASE (same id) must not refund.
    with connection(s.db_path) as conn:
        entitlements.debit_budget(conn, aid, 3.0)
    assert client.post("/api/webhooks/revenuecat", json=ev, headers=hdr).status_code == 200
    with connection(s.db_path) as conn:
        assert entitlements.budget_remaining(conn, aid) == pytest.approx(grant - 3.0)

    # A RENEWAL (new id) resets the budget for the new period.
    ren = {"event": {
        "id": "evt-2", "type": "RENEWAL", "app_user_id": str(aid),
        "product_id": "command_pro_monthly", "store": "APP_STORE", "expiration_at_ms": _ms(60),
    }}
    assert client.post("/api/webhooks/revenuecat", json=ren, headers=hdr).status_code == 200
    with connection(s.db_path) as conn:
        assert entitlements.budget_remaining(conn, aid) == grant


def test_webhook_no_budget_when_credits_disabled(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _auth(client)
    s = get_settings()
    monkeypatch.setattr(s, "revenuecat_webhook_token", "wh-secret")
    # credits_enabled defaults False → the budget stays inert (0) even on a purchase.
    aid = _owner_id(s.db_path)
    ev = {"event": {
        "id": "evt-x", "type": "INITIAL_PURCHASE", "app_user_id": str(aid),
        "product_id": "command_pro_monthly", "store": "APP_STORE", "expiration_at_ms": _ms(30),
    }}
    assert client.post(
        "/api/webhooks/revenuecat", json=ev, headers={"Authorization": "Bearer wh-secret"}
    ).status_code == 200
    with connection(s.db_path) as conn:
        assert entitlements.budget_remaining(conn, aid) == 0.0


# --- /chat gate + per-turn debit --------------------------------------------------

def _subscribe_with_budget(db_path: str, aid: int, budget: float) -> None:
    with connection(db_path) as conn:
        entitlements.record_consent(conn, aid)
        entitlements.set_entitlement(
            conn, aid, product_id="command_pro_monthly", status="active",
            expires_at=_future_iso(), will_renew=True,
        )
        entitlements.grant_budget(conn, aid, budget, ref="seed")


def test_chat_blocks_when_budget_exhausted(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _auth(client)
    s = get_settings()
    monkeypatch.setattr(s, "ai_api_key", "test-key-not-real")
    monkeypatch.setattr(s, "credits_enabled", True)
    aid = _owner_id(s.db_path)
    _subscribe_with_budget(s.db_path, aid, 0.0)  # depleted

    r = client.post("/api/agent/chat", json={"message": "hi"})
    assert r.status_code == 200
    assert "budget_exhausted" in r.text and "cap_reached" not in r.text


def test_chat_debits_budget_per_turn_not_flat_cap(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A budget-governed subscriber is metered against the per-period USD budget: a run
    debits its real cost from the budget, and the flat monthly cap does NOT block even
    when month-to-date usage already exceeds $10 (the budget governs, not the cap)."""
    _auth(client)
    from command.core.agent import runner

    s = get_settings()
    monkeypatch.setattr(s, "ai_api_key", "test-key-not-real")
    monkeypatch.setattr(s, "credits_enabled", True)
    aid = _owner_id(s.db_path)
    _subscribe_with_budget(s.db_path, aid, 5.0)
    # Pile month-to-date agent_usage well past the $10 flat cap; the budget must still govern.
    with connection(s.db_path) as conn:
        usage.record(conn, aid, "anthropic/claude-opus-5", 4_000_000, 0)  # ~$20
        assert usage.over_cap(conn, aid, 10.0) is True

    async def fake_stream(*args: object, **kwargs: object):  # type: ignore[no-untyped-def]
        yield {"type": "start", "model": "anthropic/claude-haiku-4.5"}
        yield {
            "type": "done", "output": "ok", "model": "anthropic/claude-haiku-4.5",
            "input_tokens": 1_000_000, "output_tokens": 0, "extra_cost_usd": 0.0, "searches": 0,
        }

    monkeypatch.setattr(runner, "stream", fake_stream)
    r = client.post("/api/agent/chat", json={"message": "hi"})
    assert r.status_code == 200
    assert "cap_reached" not in r.text and "budget_exhausted" not in r.text
    assert '"type": "done"' in r.text

    # The haiku turn cost $1.00 (1M input @ $1/M); budget 5.0 → 4.0.
    with connection(s.db_path) as conn:
        assert entitlements.budget_remaining(conn, aid) == pytest.approx(4.0)


def test_usage_endpoint_reports_budget_when_governed(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _auth(client)
    s = get_settings()
    monkeypatch.setattr(s, "credits_enabled", True)
    monkeypatch.setattr(s, "agent_subscription_price_usd", 19.99)
    aid = _owner_id(s.db_path)
    _subscribe_with_budget(s.db_path, aid, 4.5)

    u = client.get("/api/agent/usage").json()
    assert u["budget_governed"] is True and u["credits_enabled"] is True
    assert u["remaining_usd"] == 4.5
    assert u["cap_usd"] == round(19.99 / 3, 4)  # governing total = per-period budget

    e = client.get("/api/agent/entitlement").json()
    assert e["credits_enabled"] is True and e["budget_usd_remaining"] == 4.5
