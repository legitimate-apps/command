"""Confirm a subscriber directly with RevenueCat's REST API.

The webhook (rest/webhooks.py) is the fast path, but a RevenueCat project has ONE webhook URL:
every other server sharing that project — every self-hosted instance using the published app,
and Command Cloud beside the operator's own server — never hears about its customers'
purchases. With `COMMAND_REVENUECAT_API_KEY` (a v1 key) set, the entitlement read the
app makes on launch and after a purchase also asks RevenueCat, debounced per account, and
mirrors the answer into the same local cache the agent gate reads.

API: `GET {revenuecat_api_base}/subscribers/{app_user_id}` with `Authorization: Bearer <key>`
(RevenueCat REST API v1, "Get or Create Customer"). It accepts a v1 secret key or the app's
public SDK key, which is public anyway (it ships in the app) and suffices for this read; v2
secret keys get 403 code 7723, verified 2026-09-23. `subscriber.entitlements[<id>]`
carries `expires_date` (null = lifetime), `grace_period_expires_date`, `product_identifier` and
`purchase_date`; `subscriber.subscriptions[<product>]` adds `period_type`, `store`,
`unsubscribe_detected_at` and `billing_issues_detected_at`. The endpoint creates an empty
customer for an unknown id — harmless here, since the app has already logged RevenueCat in
with the same `billing_user_id`.

The key is sent only in the Authorization header and never logged or echoed.
"""

from __future__ import annotations

import logging
import sqlite3
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.parse import quote

import httpx

from ..config import Settings
from . import clock, entitlements

logger = logging.getLogger(__name__)

TIMEOUT_SECONDS = 5.0
# A not-yet-entitled account re-checks sooner: it is the one that may have just paid.
INACTIVE_REFRESH_SECONDS = 60

_last_checked: dict[int, float] = {}  # account_id -> monotonic time of the last attempt
_last_checked_lock = threading.Lock()
MAX_TRACKED = 50_000


@dataclass(frozen=True)
class Confirmed:
    """RevenueCat's view of one account's entitlement."""

    status: str                  # active | grace | expired | none
    product_id: str | None = None
    period_type: str | None = None
    store: str | None = None
    expires_at: str | None = None
    will_renew: bool = False
    period_start_ms: int | None = None  # purchase_date of the current paid period
    as_of_ms: int | None = None         # RevenueCat's request_date_ms


def fetch_subscriber(settings: Settings, app_user_id: str) -> dict[str, Any]:
    """The raw customer-info body. Seam for tests; raises httpx.HTTPError on failure."""
    url = f"{settings.revenuecat_api_base.rstrip('/')}/subscribers/{quote(app_user_id, safe='')}"
    resp = httpx.get(
        url,
        headers={"Authorization": f"Bearer {settings.revenuecat_api_key}"},
        timeout=TIMEOUT_SECONDS,
    )
    resp.raise_for_status()
    body = resp.json()
    if not isinstance(body, dict):
        raise httpx.DecodingError("RevenueCat returned a non-object body")
    return body


def _parse_dt(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def interpret(body: dict[str, Any], entitlement_id: str) -> Confirmed:
    """Map a customer-info body onto this server's entitlement vocabulary."""
    subscriber = body.get("subscriber") or {}
    as_of = body.get("request_date_ms")
    as_of_ms = int(as_of) if isinstance(as_of, int) else None
    ent = (subscriber.get("entitlements") or {}).get(entitlement_id)
    if not isinstance(ent, dict):
        return Confirmed(status="none", as_of_ms=as_of_ms)
    product = ent.get("product_identifier")
    sub = (subscriber.get("subscriptions") or {}).get(product) or {}
    now = clock.now()
    expires = _parse_dt(ent.get("expires_date"))
    grace_until = _parse_dt(ent.get("grace_period_expires_date") or sub.get("grace_period_expires_date"))
    purchased = _parse_dt(ent.get("purchase_date") or sub.get("purchase_date"))
    billing_issue = sub.get("billing_issues_detected_at") is not None
    if expires is None:
        status, will_renew = "active", False  # lifetime / non-expiring grant
    elif expires > now:
        status = "grace" if billing_issue else "active"
        will_renew = not billing_issue and sub.get("unsubscribe_detected_at") is None
    elif grace_until is not None and grace_until > now:
        status, will_renew, expires = "grace", False, grace_until
    else:
        status, will_renew = "expired", False
    return Confirmed(
        status=status,
        product_id=str(product) if product else None,
        period_type=(str(sub.get("period_type") or "").lower() or None),
        store=(str(sub.get("store") or "").lower() or None),
        expires_at=expires.isoformat() if expires else None,
        will_renew=will_renew,
        period_start_ms=int(purchased.timestamp() * 1000) if purchased else None,
        as_of_ms=as_of_ms,
    )


def apply(conn: sqlite3.Connection, account_id: int, c: Confirmed, settings: Settings) -> bool:
    """Mirror a confirmation into the local cache. Returns whether anything changed.

    A manual `comp` grant is sticky, as it is for webhooks. "No such entitlement" only demotes
    an account the store had marked entitled — it never invents an `expired` row for someone
    who never subscribed."""
    current = entitlements.get(conn, account_id)
    if current.status == "comp":
        return False
    if c.status == "none":
        if current.status not in entitlements.STORE_SUBSCRIBED_STATUSES:
            return False
        c = Confirmed(status="expired", as_of_ms=c.as_of_ms)
    if entitlements.is_stale_event(conn, account_id, c.as_of_ms):
        return False
    entitlements.set_entitlement(
        conn, account_id,
        product_id=c.product_id or current.product_id,
        status=c.status,
        period_type=c.period_type,
        store=c.store or current.store,
        expires_at=c.expires_at,
        will_renew=c.will_renew,
        event_ms=c.as_of_ms,
    )
    # The same per-period budget refill the webhook does on INITIAL_PURCHASE/RENEWAL, keyed on
    # the same purchase timestamp — so whichever path sees a new period first grants it, once.
    if (
        settings.credits_enabled
        and c.status in entitlements.STORE_SUBSCRIBED_STATUSES
        and c.period_start_ms is not None
    ):
        grant = round(settings.agent_subscription_price_usd / entitlements.CREDIT_MULTIPLIER, 4)
        entitlements.grant_budget(
            conn, account_id, grant,
            ref=f"rc-rest:{c.period_start_ms}", period_start_ms=c.period_start_ms,
        )
    return True


def _due(account_id: int, interval: float) -> bool:
    """Claim the account's refresh slot if its last attempt is older than `interval`."""
    now = time.monotonic()
    with _last_checked_lock:
        last = _last_checked.get(account_id)
        if last is not None and now - last < interval:
            return False
        if len(_last_checked) >= MAX_TRACKED:
            _last_checked.clear()  # bounded memory; the cost is one extra check per account
        _last_checked[account_id] = now
        return True


def refresh_if_due(conn: sqlite3.Connection, account_id: int, settings: Settings) -> None:
    """Confirm this account with RevenueCat unless it was checked recently. Never raises:
    RevenueCat being slow or down leaves the cached entitlement exactly as it was."""
    if not settings.revenuecat_api_key:
        return
    active = entitlements.is_active(conn, account_id)
    interval = float(settings.revenuecat_refresh_seconds)
    if not active:
        interval = min(interval, INACTIVE_REFRESH_SECONDS)
    if not _due(account_id, interval):
        return
    app_user_id = entitlements.billing_user_id(conn, account_id)
    # Don't hold a write transaction (the session slide, instance_id creation) open across a
    # network call: every other writer would queue behind it for up to the timeout.
    conn.commit()
    try:
        body = fetch_subscriber(settings, app_user_id)
    except (httpx.HTTPError, ValueError) as exc:
        # The exception text can include the URL, never the Authorization header.
        logger.warning("RevenueCat confirmation for account %s failed: %s", account_id,
                       type(exc).__name__)
        return
    apply(conn, account_id, interpret(body, settings.revenuecat_entitlement_id), settings)


def reset() -> None:
    """Forget debounce state (tests)."""
    with _last_checked_lock:
        _last_checked.clear()
