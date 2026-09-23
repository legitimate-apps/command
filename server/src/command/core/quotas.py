"""Per-account ceilings, checked where rows and files are created.

On a shared server (Command Cloud) one account must not be able to fill the disk or bloat the
database for everyone. The ceilings sit far above anything a real planner reaches — they stop
runaway scripts and abuse, not use. Each is a setting; 0 turns it off.

Checked in `core/` at creation, so REST, MCP, the in-app assistant and A2A peers all hit the
same wall with the same actionable error.
"""

from __future__ import annotations

import sqlite3

from ..config import get_settings
from ..errors import QuotaExceeded

# kind -> (table, settings attribute, human noun, what to do)
_ROW_LIMITS: dict[str, tuple[str, str, str, str]] = {
    "note": ("notes", "max_notes_per_account", "notes",
             "Notes are permanent, so ask the server's operator to raise "
             "COMMAND_MAX_NOTES_PER_ACCOUNT."),
    "assignment": ("assignments", "max_assignments_per_account", "assignments",
                   "Delete finished or obsolete assignments, then try again."),
    "activity": ("activities", "max_activities_per_account", "activities",
                 "Delete old activity entries, then try again."),
}


def check_rows(conn: sqlite3.Connection, account_id: int, kind: str) -> None:
    """Raise QuotaExceeded if the account already holds its ceiling of `kind` rows."""
    table, attr, noun, fix = _ROW_LIMITS[kind]
    limit = int(getattr(get_settings(), attr))
    if limit <= 0:
        return
    # Each table is indexed on account_id, so this is an index range count.
    n = conn.execute(f"SELECT COUNT(*) FROM {table} WHERE account_id = ?", (account_id,)).fetchone()[0]
    if n >= limit:
        raise QuotaExceeded(
            f"This account has reached its limit of {limit:,} {noun}.",
            hint=fix,
            details={"kind": kind, "limit": limit},
        )


def check_attachment(conn: sqlite3.Connection, account_id: int, new_bytes: int) -> None:
    """Raise QuotaExceeded if storing `new_bytes` more would pass the account's attachment
    count or total-size ceiling."""
    s = get_settings()
    row = conn.execute(
        "SELECT COUNT(*) AS n, COALESCE(SUM(size_bytes), 0) AS total FROM attachments"
        " WHERE account_id = ?",
        (account_id,),
    ).fetchone()
    count, total = int(row["n"]), int(row["total"])
    if s.max_attachments_per_account > 0 and count >= s.max_attachments_per_account:
        raise QuotaExceeded(
            f"This account has reached its limit of {s.max_attachments_per_account:,} attachments.",
            hint="Delete attachments you no longer need, then try again.",
            details={"kind": "attachment_count", "limit": s.max_attachments_per_account},
        )
    cap = s.max_attachment_bytes_per_account
    if cap > 0 and total + new_bytes > cap:
        raise QuotaExceeded(
            f"This file would take the account past its {_human(cap)} attachment storage "
            f"({_human(total)} used).",
            hint="Delete large attachments you no longer need, then try again.",
            details={"kind": "attachment_bytes", "limit": cap, "used": total},
        )


def _human(n: int) -> str:
    gib = 1024 ** 3
    if n >= gib:
        return f"{n / gib:.1f} GB"
    return f"{n / (1024 * 1024):.0f} MB"
