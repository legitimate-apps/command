"""Persistent create keys; transaction ownership stays with REST/MCP callers."""
from __future__ import annotations

import sqlite3
from typing import Literal

from ..errors import ValidationError

CreateTable = Literal["notes", "activities", "assignments"]
MAX_KEY_LENGTH = 255


def existing_id(
    conn: sqlite3.Connection, table: CreateTable, account_id: int, key: str | None
) -> int | None:
    """Validate and look up a key before body validation, quotas or side effects.

    A keyed create takes the SQLite writer lock before its lookup. This also makes
    simultaneous retries with different/invalid bodies or a now-full quota replay
    the winner instead of failing validation. No-key calls retain their old path.
    The caller commits or rolls back; never commit unrelated work here.
    """
    if key is None:
        return None
    if not 1 <= len(key) <= MAX_KEY_LENGTH:
        raise ValidationError(
            f"Idempotency key must contain 1-{MAX_KEY_LENGTH} characters.",
            hint="Use a fresh UUID for each intended create and reuse it for every retry.",
        )
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    row = conn.execute(
        f"SELECT id FROM {table} WHERE account_id = ? AND idempotency_key = ?", (account_id, key)
    ).fetchone()
    return int(row[0]) if row is not None else None
