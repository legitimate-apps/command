"""Per-account agent usage meter + monthly cap.

Lightweight (no pydantic-ai import) so REST/MCP can read budget cheaply. One row
per account per period (YYYY-MM for now; later the subscription renewal window).
"""

from __future__ import annotations

import sqlite3

from pydantic import BaseModel

from ...db import now_iso
from . import pricing


class AgentUsage(BaseModel):
    account_id: int
    period: str
    cost_usd: float
    input_tokens: int
    output_tokens: int
    runs: int


def current_period() -> str:
    return now_iso()[:7]  # YYYY-MM


def get_usage(conn: sqlite3.Connection, account_id: int, period: str | None = None) -> AgentUsage:
    period = period or current_period()
    r = conn.execute(
        "SELECT * FROM agent_usage WHERE account_id = ? AND period = ?", (account_id, period)
    ).fetchone()
    if r is None:
        return AgentUsage(
            account_id=account_id, period=period, cost_usd=0.0,
            input_tokens=0, output_tokens=0, runs=0,
        )
    return AgentUsage(
        account_id=r["account_id"], period=r["period"], cost_usd=r["cost_usd"],
        input_tokens=r["input_tokens"], output_tokens=r["output_tokens"], runs=r["runs"],
    )


def remaining(conn: sqlite3.Connection, account_id: int, cap_usd: float) -> float:
    return max(0.0, cap_usd - get_usage(conn, account_id).cost_usd)


def over_cap(conn: sqlite3.Connection, account_id: int, cap_usd: float) -> bool:
    return get_usage(conn, account_id).cost_usd >= cap_usd


def record(
    conn: sqlite3.Connection, account_id: int, model: str, input_tokens: int, output_tokens: int,
    *, extra_cost_usd: float = 0.0, cache_read_tokens: int = 0, cache_write_tokens: int = 0,
) -> float:
    """Add a run's cost to the account's month-to-date total. Returns the run cost.

    `extra_cost_usd` covers non-token charges incurred during the run (e.g. the flat
    per-search web fee) so the meter reflects the true provider spend."""
    cost = pricing.cost_usd(
        model, input_tokens, output_tokens,
        cache_read_tokens=cache_read_tokens, cache_write_tokens=cache_write_tokens,
    ) + max(0.0, extra_cost_usd)
    conn.execute(
        "INSERT INTO agent_usage "
        "(account_id, period, cost_usd, input_tokens, output_tokens, runs, updated_at) "
        "VALUES (?, ?, ?, ?, ?, 1, ?) "
        "ON CONFLICT(account_id, period) DO UPDATE SET "
        "cost_usd = cost_usd + excluded.cost_usd, "
        "input_tokens = input_tokens + excluded.input_tokens, "
        "output_tokens = output_tokens + excluded.output_tokens, "
        "runs = runs + 1, updated_at = excluded.updated_at",
        (account_id, current_period(), cost, input_tokens, output_tokens, now_iso()),
    )
    return cost
