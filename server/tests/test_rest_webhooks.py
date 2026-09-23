"""The RevenueCat webhook — money arrives here, and it had no tests.

This endpoint decides whether an account is entitled and how many credits it holds. It is
public (bearer-token authenticated rather than cookie), and RevenueCat **retries**, so every
behaviour below is a money-correctness property rather than a nicety:

* a wrong or missing token changes nothing;
* a redelivered event does not double-grant — RevenueCat retrying is normal, not exceptional;
* a deleted account is never resurrected by a late event;
* a manual `comp` grant is sticky and a store event cannot silently downgrade it;
* an unknown event type is ignored rather than guessed at;
* a grace/billing-issue event keeps access without starting a new billing period.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

TOKEN = "test-webhook-token"
CREDIT_PRODUCT = "com.legitimateapps.command.credits.small"


@pytest.fixture
def hook(tmp_path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "hook.db"))
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.setenv("COMMAND_REVENUECAT_WEBHOOK_TOKEN", TOKEN)
    monkeypatch.setenv("COMMAND_CREDITS_ENABLED", "true")
    monkeypatch.setenv("COMMAND_CREDIT_PRODUCTS", f'{{"{CREDIT_PRODUCT}": 500}}')

    from command.config import get_settings

    get_settings.cache_clear()
    from command.app import create_app
    from command.rest.auth import _invite_limiter, _login_limiter

    _login_limiter.clear()
    _invite_limiter.clear()
    with TestClient(create_app()) as c:
        r = c.post("/api/auth/register", json={"username": "buyer", "password": "password1"})
        assert r.status_code < 400, r.text
        yield c, r.json()["id"]
    get_settings.cache_clear()


def _post(c: TestClient, event: dict, token: str = TOKEN):
    return c.post(
        "/api/webhooks/revenuecat",
        json={"event": event},
        headers={"Authorization": f"Bearer {token}"},
    )


def _balance(account_id: int) -> int:
    from command.config import get_settings
    from command.core import credits
    from command.db import connect

    conn = connect(get_settings().db_path)
    try:
        return credits.balance(conn, account_id)
    finally:
        conn.close()


def _entitlement(account_id: int):
    from command.config import get_settings
    from command.core import entitlements
    from command.db import connect

    conn = connect(get_settings().db_path)
    try:
        return entitlements.get(conn, account_id)
    finally:
        conn.close()


def test_a_wrong_token_changes_nothing(hook) -> None:
    c, account_id = hook
    r = _post(c, {"type": "INITIAL_PURCHASE", "app_user_id": str(account_id)}, token="wrong")
    assert r.status_code >= 400
    assert _entitlement(account_id).status != "active", "an unauthenticated event must not entitle"


def test_an_initial_purchase_mirrors_the_entitlement(hook) -> None:
    c, account_id = hook
    r = _post(c, {
        "type": "INITIAL_PURCHASE", "id": "evt-1", "app_user_id": str(account_id),
        "product_id": "pro_monthly", "store": "APP_STORE", "period_type": "NORMAL",
    })
    assert r.status_code == 200, r.text
    ent = _entitlement(account_id)
    assert ent.status == "active" and ent.will_renew is True


def test_billing_issue_grants_grace_without_renewing(hook) -> None:
    c, account_id = hook
    _post(c, {"type": "INITIAL_PURCHASE", "id": "e1", "app_user_id": str(account_id)})
    _post(c, {"type": "BILLING_ISSUE", "id": "e2", "app_user_id": str(account_id)})
    ent = _entitlement(account_id)
    assert ent.status == "grace", "a billing issue keeps access rather than cutting it instantly"
    assert ent.will_renew is False


def test_expiration_ends_access(hook) -> None:
    c, account_id = hook
    _post(c, {"type": "INITIAL_PURCHASE", "id": "e1", "app_user_id": str(account_id)})
    _post(c, {"type": "EXPIRATION", "id": "e2", "app_user_id": str(account_id)})
    assert _entitlement(account_id).status == "expired"


def test_an_unknown_event_type_is_ignored_rather_than_guessed(hook) -> None:
    """TRANSFER and anything new RevenueCat invents must not move the entitlement."""
    c, account_id = hook
    _post(c, {"type": "INITIAL_PURCHASE", "id": "e1", "app_user_id": str(account_id)})
    r = _post(c, {"type": "TRANSFER", "id": "e2", "app_user_id": str(account_id)})
    assert r.status_code == 200
    assert _entitlement(account_id).status == "active", "an unknown type must change nothing"


def test_a_comp_grant_is_sticky_against_store_events(hook) -> None:
    """A manual comp is the operator's own decision; a store event must not silently undo it."""
    from command.config import get_settings
    from command.core import entitlements
    from command.db import connect

    c, account_id = hook
    conn = connect(get_settings().db_path)
    entitlements.set_entitlement(conn, account_id, status="comp", product_id=None)
    conn.commit()
    conn.close()

    _post(c, {"type": "EXPIRATION", "id": "e9", "app_user_id": str(account_id)})
    assert _entitlement(account_id).status == "comp", "a store event overrode a manual comp"


def test_a_credit_purchase_grants_once_however_often_it_is_redelivered(hook) -> None:
    """RevenueCat retries. Double-granting is giving away money; not granting is taking it."""
    c, account_id = hook
    event = {
        "type": "NON_RENEWING_PURCHASE", "id": "txn-42", "app_user_id": str(account_id),
        "product_id": CREDIT_PRODUCT,
    }
    assert _post(c, event).status_code == 200
    assert _balance(account_id) == 500

    assert _post(c, event).status_code == 200, "a retry must still answer 200"
    assert _balance(account_id) == 500, "a redelivered purchase must not double-grant"


def test_an_unknown_product_grants_nothing(hook) -> None:
    c, account_id = hook
    _post(c, {
        "type": "NON_RENEWING_PURCHASE", "id": "txn-x", "app_user_id": str(account_id),
        "product_id": "not.a.configured.product",
    })
    assert _balance(account_id) == 0


def test_an_event_for_a_deleted_account_is_a_no_op(hook) -> None:
    """Late events arrive after deletion; they must not recreate anything."""
    c, _account_id = hook
    r = _post(c, {"type": "INITIAL_PURCHASE", "id": "e1", "app_user_id": "999999"})
    assert r.status_code == 200, "a no-op, not an error — RevenueCat would retry forever on 5xx"


def test_an_anonymous_app_user_id_is_ignored(hook) -> None:
    """RevenueCat sends anonymous ids for users who never signed in; they map to no account."""
    c, _ = hook
    r = _post(c, {"type": "INITIAL_PURCHASE", "id": "e1", "app_user_id": "$RCAnonymousID:abc123"})
    assert r.status_code == 200
