"""Inbound store webhooks → entitlement mirror.

RevenueCat is the source of truth for subscriptions; it POSTs events here and we
mirror the resulting entitlement into the local `entitlements` cache so the agent
endpoint can gate on a fast local read. Authenticated by a shared bearer token the
operator sets in both the RevenueCat dashboard and `deploy/.env`. We never *create*
an account from a webhook. The app logs RevenueCat in as `billing_user_id`
(`<instance_id>:<account_id>`, from GET /api/agent/entitlement); a legacy bare account id is
still accepted, another instance's id is acknowledged and ignored, and an unknown/anonymous
id is a no-op. Events older than the last one applied are ignored.
"""

from __future__ import annotations

import hmac
import logging
import sqlite3
from datetime import UTC, datetime
from typing import Any

from fastapi import APIRouter, Request

from ..config import get_settings
from ..core import credits, entitlements
from ..db import connection
from ..errors import AuthFailed

router = APIRouter(prefix="/api/webhooks", tags=["webhooks"])
logger = logging.getLogger(__name__)

# RevenueCat event types → entitlement status.
_ACTIVE_RENEWING = {
    "INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE",
    "NON_RENEWING_PURCHASE", "SUBSCRIPTION_EXTENDED", "TEMPORARY_ENTITLEMENT_GRANT",
}
_ACTIVE_NOT_RENEWING = {"CANCELLATION"}   # access continues until expiry, won't renew
_GRACE = {"BILLING_ISSUE"}
_EXPIRED = {"EXPIRATION", "SUBSCRIPTION_PAUSED"}

# Events that begin a fresh paid period → reset the real-USD agent budget (decision
# 2026-07-06). Only these two: UNCANCELLATION just re-enables auto-renew mid-period, and
# PRODUCT_CHANGE announces a change whose new period arrives as its own RENEWAL — both used to
# refill a budget the user had already spent into. Grace/extension events keep entitlement
# active without a new period. Idempotent per period (purchased_at_ms), not per event id.
_BUDGET_REFRESH = {"INITIAL_PURCHASE", "RENEWAL"}


def _iso_from_ms(ms: Any) -> str | None:
    try:
        return datetime.fromtimestamp(int(ms) / 1000, UTC).isoformat()
    except (TypeError, ValueError):
        return None


def _is_web_store(store: str) -> bool:
    """Web/direct billing (no Apple cut). Currently never true from an App Store webhook —
    the web purchase path isn't built yet — so the +15% bonus below stays dormant."""
    return store in {"stripe", "rc_billing", "web", "paddle"}


def _budget_grant_usd(price_usd: float, store: str) -> float:
    """Real-USD budget granted for one paid period: price / CREDIT_MULTIPLIER.

    Web (+15%) bonus hook — DEFERRED (decision 2026-07-06): a subscription bought outside
    Apple absorbs no store cut, so it gets a larger budget. `_is_web_store` returns False
    for every store an App Store webhook can send today, so this branch is intentionally
    unreached until the web phase adds a non-Apple purchase path."""
    grant = price_usd / entitlements.CREDIT_MULTIPLIER
    if _is_web_store(store):
        grant *= 1.15
    return round(grant, 4)


@router.post("/revenuecat")
async def revenuecat(request: Request) -> dict[str, bool]:
    settings = get_settings()
    token = settings.revenuecat_webhook_token
    if not token:
        raise AuthFailed("Webhook not configured.")
    auth = request.headers.get("Authorization", "")
    presented = auth[7:].strip() if auth.lower().startswith("bearer ") else auth.strip()
    if not hmac.compare_digest(presented, token):
        raise AuthFailed("Bad webhook token.")

    body = await request.json()
    event = (body or {}).get("event") or {}
    etype = str(event.get("type") or "").upper()
    event_ms = _int_or_none(event.get("event_timestamp_ms"))

    with connection(settings.db_path) as conn:
        subject = _subject(conn, event)
    if subject.account_id is None:
        if subject.kind == "other_instance":
            # Another self-hosted Command server's customer. RevenueCat projects can be shared
            # across instances, so this is expected — acknowledge (no retries) and touch nothing.
            logger.info("RevenueCat %s for another instance's customer ignored", etype or "event")
        return {"ok": True}  # anonymous / non-account subject — nothing to mirror
    account_id = subject.account_id

    # Consumable credit pack? Grant token-credits and stop — it isn't a subscription event.
    # Idempotent on the RevenueCat event id so a redelivered webhook never double-grants.
    if settings.credits_enabled and etype == "NON_RENEWING_PURCHASE":
        product_id = str(event.get("product_id") or "")
        amount = settings.credit_products.get(product_id)
        if amount:
            with connection(settings.db_path) as conn:
                if conn.execute("SELECT 1 FROM accounts WHERE id = ?", (account_id,)).fetchone():
                    credits.grant(conn, account_id, amount, reason="purchase",
                                  ref=str(event.get("id") or f"{account_id}:{product_id}"))
            return {"ok": True}

    if etype in _EXPIRED:
        status, will_renew = "expired", False
    elif etype in _GRACE:
        status, will_renew = "grace", False
    elif etype in _ACTIVE_NOT_RENEWING:
        status, will_renew = "active", False
    elif etype in _ACTIVE_RENEWING:
        status, will_renew = "active", True
    else:
        return {"ok": True}  # TRANSFER / unknown — don't guess

    with connection(settings.db_path) as conn:
        if conn.execute("SELECT 1 FROM accounts WHERE id = ?", (account_id,)).fetchone() is None:
            return {"ok": True}  # don't resurrect a deleted account
        if entitlements.get(conn, account_id).status == "comp":
            return {"ok": True}  # a manual comp grant is sticky — store events never override it
        if entitlements.is_stale_event(conn, account_id, event_ms):
            # A newer event already landed; this one is a late retry / out-of-order delivery.
            logger.info("RevenueCat %s for account %s is older than the last applied event; "
                        "ignored", etype, account_id)
            return {"ok": True}
        store = str(event.get("store") or "").lower() or "app_store"
        entitlements.set_entitlement(
            conn, account_id,
            product_id=event.get("product_id"),
            status=status,
            period_type=(str(event.get("period_type") or "").lower() or None),
            store=store,
            expires_at=_iso_from_ms(event.get("expiration_at_ms")),
            will_renew=will_renew,
            event_ms=event_ms,
        )
        # E4: reset the real-USD agent budget at the start of each paid period, once per
        # period (keyed on the period's purchased_at, so redeliveries and duplicate events
        # for the same period are no-ops). Inert unless credits are live.
        if settings.credits_enabled and etype in _BUDGET_REFRESH:
            grant = _budget_grant_usd(settings.agent_subscription_price_usd, store)
            period_ms = _int_or_none(event.get("purchased_at_ms"))
            entitlements.grant_budget(
                conn, account_id, grant,
                ref=str(event.get("id") or f"{account_id}:{etype}"),
                period_start_ms=period_ms,
            )
    return {"ok": True}


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _subject(conn: sqlite3.Connection, event: dict[str, Any]) -> entitlements.BillingSubject:
    """Which local account (if any) an event is about. Checks `app_user_id`, then
    `original_app_user_id`, then `aliases` — a customer who bought before logging in carries
    the account id only as an alias. The first id that is THIS instance's (or a legacy bare
    integer) wins; if none is, but one belongs to another instance, say so."""
    candidates: list[str] = []
    for key in ("app_user_id", "original_app_user_id"):
        if event.get(key):
            candidates.append(str(event[key]))
    aliases = event.get("aliases")
    if isinstance(aliases, list):
        candidates += [str(a) for a in aliases if a]
    other = False
    for candidate in candidates:
        subject = entitlements.resolve_billing_user_id(conn, candidate)
        if subject.account_id is not None:
            return subject
        other = other or subject.kind == "other_instance"
    return entitlements.BillingSubject(kind="other_instance" if other else "unrecognised")
