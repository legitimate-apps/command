"""Subscription entitlements + AI-disclosure consent for the agent.

One row per account, mirrored from RevenueCat webhooks (the store is the source of
truth; this is a fast local cache so the agent endpoint can gate without a network
call). `is_active` is the single gate the REST layer consults. Gating itself is
governed by `agent_require_subscription` in settings (default off) — this module
just answers "is this account entitled / has it consented".
"""

from __future__ import annotations

import re
import secrets
import sqlite3
from datetime import datetime

from pydantic import BaseModel

from ..db import now_iso
from . import clock

# Statuses that count as entitled. A store subscription in `active`/`grace` must
# also be unexpired; `comp` (a manual grant) never expires.
ACTIVE_STATUSES = {"active", "grace", "comp"}
# A *paid store* subscription (excludes `comp`) — these accounts are governed by the
# per-period USD budget below rather than the flat monthly cap (decision 2026-07-06).
STORE_SUBSCRIBED_STATUSES = {"active", "grace"}

# Credits are a *display* multiple of the real backend USD budget: the client shows
# `budget_usd x CREDIT_MULTIPLIER` with a `$`, and each renewal grants
# `subscription_price / CREDIT_MULTIPLIER` of real budget, so a fresh subscriber sees
# a credit figure equal to what they paid. The backend is ALWAYS real USD; this constant
# lives here only because the grant math divides by it. See
# docs/decisions/2026-07-06-credits-usd-model.md.
CREDIT_MULTIPLIER = 3


class Entitlement(BaseModel):
    account_id: int
    product_id: str | None = None
    status: str = "none"
    period_type: str | None = None
    store: str | None = None
    expires_at: str | None = None
    will_renew: bool = False
    consent_at: str | None = None
    updated_at: str | None = None
    # Real-USD agent budget (E4). Reset to price/3 each renewal, debited per turn.
    ai_budget_usd_remaining: float = 0.0
    budget_period_ref: str | None = None
    # Store-event ordering (migration 0026): newest applied event, and the paid period the
    # current budget belongs to — both RevenueCat epoch-milliseconds.
    last_event_ms: int | None = None
    budget_period_start_ms: int | None = None


def _row(r: sqlite3.Row) -> Entitlement:
    return Entitlement(
        account_id=r["account_id"], product_id=r["product_id"], status=r["status"],
        period_type=r["period_type"], store=r["store"], expires_at=r["expires_at"],
        will_renew=bool(r["will_renew"]), consent_at=r["consent_at"], updated_at=r["updated_at"],
        ai_budget_usd_remaining=float(r["ai_budget_usd_remaining"] or 0.0),
        budget_period_ref=r["budget_period_ref"],
        last_event_ms=r["last_event_ms"], budget_period_start_ms=r["budget_period_start_ms"],
    )


# --- Billing identity -------------------------------------------------------------
#
# RevenueCat's app_user_id for an account is `<instance_id>:<account_id>`. RevenueCat allows
# any string up to 100 characters except those containing '/' (and a short block-list of
# placeholder values); its own anonymous ids use ':' too (`$RCAnonymousID:<hex>`). 32 hex +
# ':' + digits is ~40 characters.

BILLING_ID_SEPARATOR = ":"
_BILLING_ID_RE = re.compile(r"^([0-9a-f]{32}):([0-9]+)$")


def instance_id(conn: sqlite3.Connection) -> str:
    """This server's permanent identity (migration 0025). Created here too if missing, so a
    database that somehow lost the row still gets exactly one."""
    row = conn.execute("SELECT value FROM instance_meta WHERE key = 'instance_id'").fetchone()
    if row is not None:
        return str(row["value"])
    conn.execute(
        "INSERT OR IGNORE INTO instance_meta (key, value) VALUES ('instance_id', ?)",
        (secrets.token_hex(16),),
    )
    return str(
        conn.execute("SELECT value FROM instance_meta WHERE key = 'instance_id'").fetchone()["value"]
    )


def billing_user_id(conn: sqlite3.Connection, account_id: int) -> str:
    """The RevenueCat app_user_id the iOS app must `Purchases.logIn` with for this account."""
    return f"{instance_id(conn)}{BILLING_ID_SEPARATOR}{account_id}"


class BillingSubject(BaseModel):
    """What a webhook's app_user_id refers to, from this instance's point of view."""

    account_id: int | None = None
    kind: str   # 'this_instance' | 'legacy' | 'other_instance' | 'unrecognised'


def resolve_billing_user_id(conn: sqlite3.Connection, app_user_id: str) -> BillingSubject:
    """Map a RevenueCat app_user_id to an account on THIS instance.

    Accepts this instance's `<instance_id>:<account_id>` and — for the sandbox purchases made
    before the change — a legacy bare integer. Another instance's id is recognised as such so
    the webhook can acknowledge and ignore it rather than touch a local account with the same
    number."""
    value = (app_user_id or "").strip()
    if value.isdigit():
        return BillingSubject(account_id=int(value), kind="legacy")
    m = _BILLING_ID_RE.match(value)
    if m is None:
        return BillingSubject(kind="unrecognised")
    if m.group(1) != instance_id(conn):
        return BillingSubject(kind="other_instance")
    return BillingSubject(account_id=int(m.group(2)), kind="this_instance")


def get(conn: sqlite3.Connection, account_id: int) -> Entitlement:
    r = conn.execute("SELECT * FROM entitlements WHERE account_id = ?", (account_id,)).fetchone()
    return _row(r) if r is not None else Entitlement(account_id=account_id)


def _not_expired(expires_at: str | None) -> bool:
    if not expires_at:
        return True  # comp / no expiry
    try:
        return datetime.fromisoformat(expires_at) > clock.now()
    except ValueError:
        return False


def is_active(conn: sqlite3.Connection, account_id: int) -> bool:
    e = get(conn, account_id)
    return e.status in ACTIVE_STATUSES and _not_expired(e.expires_at)


def has_consent(conn: sqlite3.Connection, account_id: int) -> bool:
    return get(conn, account_id).consent_at is not None


def can_use_agent(
    conn: sqlite3.Connection, account_id: int, *, require_subscription: bool
) -> bool:
    """The single access gate for agent work — chat AND anything proactive.

    Both surfaces must ask the same question. A stricter gate on the proactive path (e.g.
    `is_active()` alone) would be silently wrong for **self-hosted** instances, where
    `agent_require_subscription` is false and nobody is subscribed: they would simply never
    receive a briefing, with no error to explain it.

    Consent gates first regardless of billing — Apple requires the AI disclosure before any
    user data reaches a third-party model.

    This is also the seam where bring-your-own-key lands later: an account supplying its own
    key becomes one more clause here, not a second gate somewhere else.
    """
    if not has_consent(conn, account_id):
        return False
    return not require_subscription or is_active(conn, account_id)


def is_store_subscribed(conn: sqlite3.Connection, account_id: int) -> bool:
    """True for a live *paid* store subscription (active/grace, unexpired) — the accounts
    governed by the per-period USD budget. Excludes `comp` (operator grants), which keep
    the flat monthly cap. Independent of the `credits_enabled` flag — callers combine it."""
    e = get(conn, account_id)
    return e.status in STORE_SUBSCRIBED_STATUSES and _not_expired(e.expires_at)


# --- Real-USD agent budget (E4) ---------------------------------------------------
# The budget lives on the entitlement row; these helpers reset / draw it down. They do
# not commit (the request-scoped `connection()` context manager does), matching the rest
# of core/.

def budget_remaining(conn: sqlite3.Connection, account_id: int) -> float:
    return get(conn, account_id).ai_budget_usd_remaining


def grant_budget(
    conn: sqlite3.Connection, account_id: int, amount_usd: float, *, ref: str | None,
    period_start_ms: int | None = None,
) -> bool:
    """Reset (NOT accumulate) the account's real-USD agent budget to `amount_usd`.

    Idempotent per PAID PERIOD when `period_start_ms` (the store's purchased_at for the
    period) is given: a grant for the period the budget already belongs to — or an earlier
    one, arriving late — is a no-op, whatever its event id. Otherwise idempotent on `ref`
    alone (a redelivery of the same event). A `None` ref and period always applies
    (manual/testing). Returns whether it applied."""
    if amount_usd < 0:
        raise ValueError("budget grant must be non-negative")
    existing = get(conn, account_id)
    if (
        period_start_ms is not None
        and existing.budget_period_start_ms is not None
        and period_start_ms <= existing.budget_period_start_ms
    ):
        return False  # this period (or a newer one) already set the budget
    if ref is not None and existing.budget_period_ref == ref:
        return False  # this exact event already set the budget
    fields: dict[str, object] = {"ai_budget_usd_remaining": amount_usd, "budget_period_ref": ref}
    if period_start_ms is not None:
        fields["budget_period_start_ms"] = period_start_ms
    _upsert(conn, account_id, **fields)
    return True


def debit_budget(conn: sqlite3.Connection, account_id: int, amount_usd: float) -> float:
    """Subtract a turn's real-USD cost from the budget and return the new remaining.

    A non-positive cost is a no-op. The balance may dip slightly below zero on the final
    turn (its cost isn't known until it finishes); the next turn is then gated, so the
    overshoot is bounded by one turn — the same behavior as the flat monthly cap."""
    if amount_usd <= 0:
        return budget_remaining(conn, account_id)
    new_balance = budget_remaining(conn, account_id) - amount_usd
    _upsert(conn, account_id, ai_budget_usd_remaining=new_balance)
    return new_balance


def _upsert(conn: sqlite3.Connection, account_id: int, **fields: object) -> Entitlement:
    """Insert-or-update the account's single entitlement row with the given columns."""
    existing = conn.execute(
        "SELECT 1 FROM entitlements WHERE account_id = ?", (account_id,)
    ).fetchone()
    fields["updated_at"] = now_iso()
    if existing is None:
        cols = ["account_id", *fields.keys()]
        conn.execute(
            f"INSERT INTO entitlements ({', '.join(cols)}) "
            f"VALUES ({', '.join('?' for _ in cols)})",
            (account_id, *fields.values()),
        )
    else:
        sets = ", ".join(f"{k} = ?" for k in fields)
        conn.execute(
            f"UPDATE entitlements SET {sets} WHERE account_id = ?",
            (*fields.values(), account_id),
        )
    return get(conn, account_id)


def record_consent(conn: sqlite3.Connection, account_id: int) -> Entitlement:
    """Stamp AI-disclosure consent (idempotent — keeps the first timestamp)."""
    if has_consent(conn, account_id):
        return get(conn, account_id)
    return _upsert(conn, account_id, consent_at=now_iso())


def set_entitlement(
    conn: sqlite3.Connection, account_id: int, *,
    product_id: str | None, status: str, period_type: str | None = None,
    store: str | None = None, expires_at: str | None = None, will_renew: bool = False,
    event_ms: int | None = None,
) -> Entitlement:
    """Mirror a store event. `event_ms` (the event's own timestamp) is recorded so the webhook
    can ignore anything older that arrives later — see `is_stale_event`."""
    fields: dict[str, object] = {
        "product_id": product_id, "status": status, "period_type": period_type,
        "store": store, "expires_at": expires_at, "will_renew": 1 if will_renew else 0,
    }
    if event_ms is not None:
        fields["last_event_ms"] = event_ms
    return _upsert(conn, account_id, **fields)


def is_stale_event(conn: sqlite3.Connection, account_id: int, event_ms: int | None) -> bool:
    """True when a newer store event has already been applied to this account. Webhooks are
    retried and can arrive out of order; applying them in arrival order let a delayed
    EXPIRATION undo a newer RENEWAL. An event with no timestamp can't be ordered and applies."""
    if event_ms is None:
        return False
    last = get(conn, account_id).last_event_ms
    return last is not None and event_ms < last


def grant_comp(conn: sqlite3.Connection, account_id: int) -> Entitlement:
    """Manually entitle an account (e.g. the operator) with no expiry."""
    return _upsert(
        conn, account_id, product_id="comp", status="comp",
        period_type="normal", store="comp", expires_at=None, will_renew=0,
    )
