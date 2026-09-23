"""Per-account run serialization + post-run settlement.

Shared by every surface that runs a paid agent turn (the REST chat endpoint and
the inbound A2A peer surface): one asyncio lock per account closes the
cap-check/record race, and `record_run` meters the run's real provider spend —
ALWAYS, even when the run errored after billing tokens — debiting the per-period
budget for governed subscribers and appending the assistant turn, all in one
transaction with lock-contention retries.
"""

from __future__ import annotations

import asyncio
import logging
import sqlite3
from typing import Any

from ...db import connection
from .. import entitlements
from . import threads, usage

logger = logging.getLogger(__name__)

_account_locks: dict[int, asyncio.Lock] = {}


def account_lock(account_id: int) -> asyncio.Lock:
    lock = _account_locks.get(account_id)
    if lock is None:
        lock = asyncio.Lock()
        _account_locks[account_id] = lock
    return lock


async def record_run(
    db_path: str, account_id: int, model: str, final: dict[str, Any], cap: float,
    *, output: str | None, thread_id: int, set_title: str | None, budget_governed: bool,
) -> tuple[float, float]:
    """Meter a run's real provider spend — ALWAYS, even when the run errored after billing
    tokens/web fees. The month-to-date `agent_usage` meter is written for every account
    (accounting + the flat cap); for a budget-governed subscriber the same real cost is ALSO
    debited from the per-period USD budget (E4), in the same transaction. When there is
    genuine output, append the assistant turn and (first turn) the title. The write is
    retried on transient SQLite lock contention so a known-nonzero charge is never silently
    dropped. Returns (run_cost, governing_remaining) — the budget remaining for a
    subscriber, else the flat-cap remaining."""
    in_tok = int(final.get("input_tokens") or 0)
    out_tok = int(final.get("output_tokens") or 0)
    extra = float(final.get("extra_cost_usd") or 0.0)
    c_read = int(final.get("cache_read_tokens") or 0)
    c_write = int(final.get("cache_write_tokens") or 0)
    last_exc: Exception | None = None
    for attempt in range(5):
        try:
            with connection(db_path) as conn:
                cost = usage.record(
                    conn, account_id, model, in_tok, out_tok, extra_cost_usd=extra,
                    cache_read_tokens=c_read, cache_write_tokens=c_write,
                )
                budget_left = (
                    entitlements.debit_budget(conn, account_id, cost) if budget_governed else None
                )
                if output is not None:
                    threads.add_message(
                        conn, account_id, thread_id, threads.ROLE_ASSISTANT, output,
                        model=model, cost_usd=cost,
                    )
                    if set_title is not None:
                        threads.set_title(conn, account_id, thread_id, set_title)
                remaining = (
                    max(0.0, budget_left) if budget_left is not None
                    else usage.remaining(conn, account_id, cap)
                )
                return cost, remaining
        except sqlite3.OperationalError as exc:  # "database is locked" → back off + retry
            last_exc = exc
            await asyncio.sleep(0.1 * (attempt + 1))
    logger.warning(
        "agent usage.record failed after retries for account %s (spend NOT metered): %s",
        account_id, last_exc,
    )
    return 0.0, cap
