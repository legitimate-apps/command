"""Pay-per-token credit ledger.

An append-only ledger; the balance is `SUM(delta)`. Grants (consumable IAP purchases) are
positive, usage debits are negative. Every mutation can carry a `ref` (store transaction /
webhook event id) which is unique, so a redelivered grant is a no-op — critical for webhooks,
which retry. Following the codebase convention, these functions do not commit; the request-scoped
`connection()` context manager commits on exit.
"""

from __future__ import annotations

import sqlite3

from pydantic import BaseModel

from . import clock


class CreditTransaction(BaseModel):
    id: int
    delta: int
    reason: str
    ref: str | None
    created_at: str


def balance(conn: sqlite3.Connection, account_id: int) -> int:
    row = conn.execute(
        "SELECT COALESCE(SUM(delta), 0) AS bal FROM credit_ledger WHERE account_id = ?",
        (account_id,),
    ).fetchone()
    return int(row["bal"])


def _append(conn: sqlite3.Connection, account_id: int, delta: int,
            reason: str, ref: str | None) -> bool:
    """Append a ledger row. Idempotent on a non-null `ref` (a duplicate is ignored). Returns
    whether a new row was written."""
    try:
        conn.execute(
            "INSERT INTO credit_ledger (account_id, delta, reason, ref, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (account_id, delta, reason, ref, clock.now().isoformat()),
        )
        return True
    except sqlite3.IntegrityError:
        # ONLY a duplicate `ref` means "already applied". This table raises `IntegrityError`
        # three other ways — the `account_id` foreign key (`PRAGMA foreign_keys=ON`), and the
        # NOT NULL on `delta`/`reason` — and treating those as a redelivery reports a customer's
        # purchase as already-applied while nothing is written. Measured before this guard:
        # `grant(conn, <nonexistent account>, 500, ref="txn")` returned `False` and the money
        # vanished with no error anywhere.
        #
        # The unique index is on `ref` alone (`WHERE ref IS NOT NULL`), so the check is not
        # scoped by account: a ref colliding across accounts is still a genuine duplicate.
        already_applied = ref is not None and conn.execute(
            "SELECT 1 FROM credit_ledger WHERE ref = ?", (ref,)
        ).fetchone() is not None
        if already_applied:
            return False
        raise


def grant(conn: sqlite3.Connection, account_id: int, amount: int, *,
          reason: str = "purchase", ref: str | None = None) -> bool:
    if amount <= 0:
        raise ValueError("grant amount must be positive")
    return _append(conn, account_id, amount, reason, ref)


def debit(conn: sqlite3.Connection, account_id: int, amount: int, *,
          reason: str = "usage", ref: str | None = None) -> bool:
    if amount <= 0:
        raise ValueError("debit amount must be positive")
    return _append(conn, account_id, -amount, reason, ref)


def transactions(conn: sqlite3.Connection, account_id: int, *, limit: int = 50) -> list[CreditTransaction]:
    rows = conn.execute(
        "SELECT id, delta, reason, ref, created_at FROM credit_ledger "
        "WHERE account_id = ? ORDER BY id DESC LIMIT ?",
        (account_id, max(1, min(limit, 500))),
    ).fetchall()
    return [
        CreditTransaction(id=r["id"], delta=r["delta"], reason=r["reason"],
                          ref=r["ref"], created_at=r["created_at"])
        for r in rows
    ]
