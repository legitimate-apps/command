"""Spend guard for proactive (unasked-for) LLM work.

The problem it solves is churn, not abuse: someone installs the app, stops opening it, and
a daily briefing keeps calling a model on their behalf forever. Nobody reads it and it bills
every day. So proactive work is capped at N model-spending sends since the user last opened
the app, and opening it resets the count — engagement buys the budget back.

Deliberately narrow: this counts **LLM-spending** sends only. A plain reminder push renders
a template and never touches a model, so it is neither counted nor capped; doing otherwise
would silence real reminders while saving nothing. `llm_sends_since_open` is named to say so.

The cap lives in config (`COMMAND_MAX_LLM_SENDS_BEFORE_OPEN`), never here, so it is tunable
without a code change. `cap < 0` means unlimited — an explicit escape hatch for a self-hosted
instance that does not want the guard at all.
"""

from __future__ import annotations

import sqlite3

from pydantic import BaseModel

from ..db import now_iso


class BudgetState(BaseModel):
    account_id: int
    llm_sends_since_open: int
    last_send_at: str | None = None
    last_open_at: str | None = None


def get_state(conn: sqlite3.Connection, account_id: int) -> BudgetState:
    row = conn.execute(
        "SELECT * FROM llm_budget WHERE account_id = ?", (account_id,)
    ).fetchone()
    if row is None:
        return BudgetState(account_id=account_id, llm_sends_since_open=0)
    return BudgetState(
        account_id=row["account_id"],
        llm_sends_since_open=row["llm_sends_since_open"],
        last_send_at=row["last_send_at"],
        last_open_at=row["last_open_at"],
    )


def sends_since_open(conn: sqlite3.Connection, account_id: int) -> int:
    return get_state(conn, account_id).llm_sends_since_open


def may_spend(conn: sqlite3.Connection, account_id: int, *, cap: int) -> bool:
    """Whether proactive LLM work is still allowed for this account.

    Checked BEFORE generating, never merely before sending — the model call is the cost, so
    an exhausted account must never reach the model in the first place.
    """
    if cap < 0:
        return True   # explicit "no guard" for self-hosted instances
    if cap == 0:
        return False  # proactive spend switched off entirely
    return sends_since_open(conn, account_id) < cap


def record_send(conn: sqlite3.Connection, account_id: int) -> int:
    """Count one LLM-spending proactive send. Returns the new count."""
    ts = now_iso()
    conn.execute(
        "INSERT INTO llm_budget (account_id, llm_sends_since_open, last_send_at) "
        "VALUES (?, 1, ?) "
        "ON CONFLICT(account_id) DO UPDATE SET "
        "llm_sends_since_open = llm_sends_since_open + 1, last_send_at = excluded.last_send_at",
        (account_id, ts),
    )
    return sends_since_open(conn, account_id)


def record_open(conn: sqlite3.Connection, account_id: int) -> None:
    """The user opened the app (or the web surface) — give the budget back.

    Called from the app-open ping and from the session bootstrap, so any real engagement
    resets it; a background push registration must NOT call this, or the guard never trips.
    """
    ts = now_iso()
    conn.execute(
        "INSERT INTO llm_budget (account_id, llm_sends_since_open, last_open_at) "
        "VALUES (?, 0, ?) "
        "ON CONFLICT(account_id) DO UPDATE SET "
        "llm_sends_since_open = 0, last_open_at = excluded.last_open_at",
        (account_id, ts),
    )
