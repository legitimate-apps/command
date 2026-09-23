"""Deciding whether to send one account's briefing, and sending it.

Split out from `reminder_job` because the gates are entirely different. A reminder is
something the user explicitly created and is always delivered; a briefing is unsolicited,
costs model tokens, and has to earn its way past consent, entitlement, preferences, cadence
and the churn budget before anything expensive happens.

Gate order is deliberate and load-bearing: everything cheap and disqualifying runs FIRST, so
an ineligible account never reaches the digest build or the model.
"""

from __future__ import annotations

import logging
import sqlite3
from collections.abc import Callable
from datetime import UTC, datetime

from . import accounts as accounts_core
from . import apns, entitlements, llm_budget, push
from . import briefings as briefings_core
from . import settings as settings_core

logger = logging.getLogger(__name__)

Sender = Callable[..., apns.PushResult]

LAST_SENT_KEY = "agent_briefing_last_sent"


def _last_sent_at(conn: sqlite3.Connection, account_id: int) -> str | None:
    stored = settings_core.get_value(conn, account_id, LAST_SENT_KEY) or {}
    value = stored.get("at")
    return value if isinstance(value, str) else None


def _mark_sent(conn: sqlite3.Connection, account_id: int, when: str) -> None:
    settings_core.set_value(conn, account_id, LAST_SENT_KEY, {"at": when})


def send_briefing_if_due(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    now: datetime,
    sender: Sender = apns.send,
    cap: int,
    require_subscription: bool,
) -> bool:
    """Send this account's briefing when everything says it should. Returns whether it went.

    Cheap disqualifiers first — preferences, cadence, consent/entitlement, budget, device —
    then the digest, then the send. The budget is spent only when a notification actually
    leaves, so an empty day costs nothing.
    """
    prefs = briefings_core.get_prefs(conn, account_id)
    if not prefs.enabled:
        return False

    account = accounts_core.get_account(conn, account_id)
    timezone = getattr(account, "timezone", None)
    if not briefings_core.is_due(
        prefs, now=now, last_sent_at=_last_sent_at(conn, account_id), timezone=timezone
    ):
        return False

    # Consent + entitlement, via the SAME predicate the chat surface uses — a stricter gate
    # here would silently exclude every self-hosted instance.
    if not entitlements.can_use_agent(
        conn, account_id, require_subscription=require_subscription
    ):
        return False

    # The churn guard, checked BEFORE the digest so an ineligible account costs nothing.
    if not llm_budget.may_spend(conn, account_id, cap=cap):
        return False

    tokens = [t for t in push.list_tokens(conn, account_id) if t.delegatee_id is None]
    if not tokens:
        return False

    # Same zone `is_due` just used — it decides where "today" ends in the digest, so passing
    # it is what keeps `due_today` from reaching into tomorrow.
    digest = briefings_core.build_digest(
        conn, account_id, now=now, prefs=prefs, timezone=timezone
    )
    if digest.is_empty:
        # Nothing worth saying. Don't buzz the phone and don't spend the budget on it.
        return False

    delivered = False
    for token in tokens:
        # Never hold a write transaction across the APNs call (up to 10 s) — see reminder_job.
        conn.commit()
        result = sender(
            token.token,
            title="Your briefing",
            body=digest.headline,
            environment=token.environment,
        )
        if getattr(result, "ok", False):
            delivered = True
        elif getattr(result, "unregistered", False):
            push.delete_by_token(conn, token.token)

    if not delivered:
        return False

    # Stamp the marker with the SAME instant every gate above was judged against, not a fresh
    # wall-clock reading. `is_due` compares this marker's local date to `now`'s local date, so
    # two clocks deciding one question is a bug even when they usually agree: a send at
    # 23:59:59.9 (reachable with hour_local=23) records tomorrow's local date and suppresses
    # tomorrow's briefing entirely. It also made the suite calendar-dependent — the
    # one-per-day test injects a fixed `now` and passed only on the day that date came round.
    _mark_sent(conn, account_id, now.astimezone(UTC).isoformat())
    llm_budget.record_send(conn, account_id)
    return True


def run_once(
    conn: sqlite3.Connection,
    *,
    now: datetime,
    sender: Sender = apns.send,
    cap: int,
    require_subscription: bool,
) -> int:
    """One briefing sweep across every account with a device. Returns how many went out."""
    sent = 0
    for account_id in push.accounts_with_tokens(conn):
        try:
            if send_briefing_if_due(
                conn,
                account_id,
                now=now,
                sender=sender,
                cap=cap,
                require_subscription=require_subscription,
            ):
                sent += 1
            # Per account, so the next account's network call doesn't run inside this one's
            # write transaction (the sent-marker and budget row).
            conn.commit()
        except Exception:
            # One account's bad data must never stop the sweep for everyone else.
            conn.rollback()
            logger.exception("Briefing sweep failed for account_id=%s", account_id)
    return sent
