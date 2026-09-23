"""Settings-driven read/write/delete gating for MCP tools + a small audit helper.

Annotations on tools are untrusted hints; this is the real enforcement, run
server-side at the top of every mutating tool. Notes update/delete are refused
unconditionally (Hard Rule 1) regardless of the settings matrix.
"""

from __future__ import annotations

import sqlite3

from ..core import settings as settings_core
from ..db import now_iso


def require(conn: sqlite3.Connection, account_id: int, entity: str, action: str) -> None:
    """Raise if the account's settings (or Hard Rule 1) forbid `action` on `entity`. The rule
    lives in core (`settings.require_agent_permission`) because A2A peer runs enforce it too."""
    settings_core.require_agent_permission(conn, account_id, entity, action, surface="MCP")


def audit(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    tool: str,
    action: str,
    entity: str,
    entity_id: int | None,
    summary: str,
) -> None:
    conn.execute(
        "INSERT INTO audit_log (account_id, actor, tool, action, entity, entity_id, summary, created_at) "
        "VALUES (?, 'mcp', ?, ?, ?, ?, ?, ?)",
        (account_id, tool, action, entity, entity_id, summary, now_iso()),
    )
