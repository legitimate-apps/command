"""The scheduled reminder-delivery job (B4).

Periodically walks each account's upcoming reminders, and for any whose `remind_at` has arrived
(and hasn't been pushed yet) sends an APNs alert to that account's devices, recording the send so
it fires at most once. Dead tokens (APNs 410 / bad token) are pruned. The loop only runs when APNs
is configured; the core `send_account_reminders` is sync + sender-injectable so it unit-tests
without touching the network.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import sqlite3
from collections.abc import Callable
from datetime import UTC, datetime

from ..db import connection
from . import apns, clock, push
from . import reminders as reminders_core

Sender = Callable[..., apns.PushResult]
logger = logging.getLogger(__name__)


def _occurrence_key(occurs_at: str) -> str:
    """Return the occurrence instant normalized to UTC for the send-once ledger."""
    return reminders_core._parse(occurs_at).astimezone(UTC).isoformat()


def send_account_reminders(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    now: datetime,
    sender: Sender = apns.send,
) -> int:
    """Push every due, not-yet-sent reminder for one account. Returns how many reminders were sent
    (an occurrence counts once regardless of device count). Pure/sync + injectable for testing."""
    tokens = push.list_tokens(conn, account_id)
    if not tokens:
        return 0
    due = [r for r in reminders_core.upcoming_reminders(conn, account_id, now=now) if r.due]
    sent = 0
    for r in due:
        occurrence_key = _occurrence_key(r.occurs_at)
        if push.already_sent(conn, account_id, r.assignment_id, occurrence_key):
            continue
        # Routing: operator devices (delegatee_id NULL) get everything (safety net); a
        # delegatee's devices get ONLY the assignments assigned to that delegatee — never
        # another delegatee's (or unassigned) reminders.
        targets = [
            tok
            for tok in tokens
            if tok.delegatee_id is None or tok.delegatee_id == r.assignee_id
        ]
        delivered = False
        for tok in targets:
            # Never hold a write transaction across network I/O. An APNs call can take up to
            # 10 s, and a pending write (the previous reminder's mark_sent, a pruned token)
            # held SQLite's single write lock for the whole of it — REST writes meanwhile
            # waited out their busy timeout and failed with "database is locked".
            conn.commit()
            res = sender(tok.token, title="Reminder", body=r.title, environment=tok.environment)
            if res.ok:
                delivered = True
            elif res.unregistered:
                push.delete_by_token(conn, tok.token)
        # This job has one sequential worker, so recording only after successful delivery is safe
        # and lets a transient all-device failure retry on the next sweep.
        if delivered and push.mark_sent(
            conn, account_id, r.assignment_id, occurrence_key, r.remind_at
        ):
            sent += 1
        # Durable per send: a crash later in the sweep must not forget this one was delivered.
        conn.commit()
    return sent


def run_once(
    db_path: str, *, now: datetime | None = None, sender: Sender = apns.send
) -> int:
    """One sweep across all accounts with device tokens. Returns total reminders sent."""
    now = now or clock.now()
    total = 0
    with connection(db_path) as conn:
        for account_id in push.accounts_with_tokens(conn):
            try:
                total += send_account_reminders(conn, account_id, now=now, sender=sender)
                conn.commit()
            except Exception:
                # Drop this account's uncommitted half-work rather than carry it into (and
                # hold the write lock through) the next account's sends.
                conn.rollback()
                logger.exception("Reminder sweep failed for account_id=%s", account_id)
    return total


async def run_loop(db_path: str, *, poll_seconds: int, stop: asyncio.Event) -> None:
    """Background loop: sweep every `poll_seconds` until `stop` is set. Errors are swallowed per
    tick so one bad sweep never kills the loop (it's best-effort delivery)."""
    while not stop.is_set():
        with contextlib.suppress(Exception):  # never let the loop die on one bad sweep
            await asyncio.to_thread(run_once, db_path)
        # Proactive briefings ride this same loop rather than adding a second daemon. Its
        # own gates (preferences, cadence, entitlement, churn budget) decide whether anything
        # actually goes out, so running it every tick is cheap and idempotent.
        with contextlib.suppress(Exception):
            await asyncio.to_thread(_briefing_sweep, db_path)
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=poll_seconds)


def _briefing_sweep(db_path: str) -> int:
    from ..config import get_settings
    from . import briefing_job

    settings = get_settings()
    with connection(db_path) as conn:
        return briefing_job.run_once(
            conn,
            now=clock.now(),
            sender=apns.send,
            cap=settings.max_llm_sends_before_open,
            require_subscription=settings.agent_require_subscription,
        )
