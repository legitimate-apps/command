"""Per-account settings, including the MCP permission matrix.

"All that should be controlled in server settings" (operator). The matrix says
which entities the MCP surface may read / create / update / delete. Defaults are
least-privilege-leaning; the operator widens them in the app.

Hard Rule 1 is enforced HERE as a backstop: `mcp_permissions()` always forces
notes.update and notes.delete to False, no matter what a stored row says — a
settings bug must never make notes destructible via MCP.
"""

from __future__ import annotations

import copy
import json
import sqlite3
from typing import Any

from ..db import now_iso
from ..errors import NotesImmutable, PermissionDenied

MCP_PERMISSIONS_KEY = "mcp_permissions"

DEFAULT_MCP_PERMISSIONS: dict[str, dict[str, bool]] = {
    # Notes are body-immutable + non-deletable via MCP (update/delete force-denied
    # below and in permissions.require). `process` is the ONE allowed notes mutation
    # — a reversible "turned this into goals" workflow flag — kept settings-controllable
    # (default on) so every MCP write is governed by settings, per the operator contract.
    "notes": {"read": True, "create": True, "update": False, "delete": False, "process": True},
    "delegatees": {"read": True, "create": True, "update": True, "delete": True},
    "goals": {"read": True, "create": True, "update": True, "delete": True},
    "assignments": {"read": True, "create": True, "update": True, "delete": True},
    # Activities are the fact log — editable + deletable (a log, not raw capture),
    # all default-on; delete still needs a confirm-token. Auto-logged completions
    # are a core domain rule and bypass this matrix (they ride the already-permitted
    # assignment status change).
    "activities": {"read": True, "create": True, "update": True, "delete": True},
    # Attachments are READ-ONLY over MCP by default: an agent reading a document the operator
    # attached is the useful case; uploading or deleting their files from a remote agent is
    # not, and deletion also removes bytes from disk. Least privilege (Hard Rule 2).
    "attachments": {"read": True, "create": False, "update": False, "delete": False},
    # Checklists are lightweight working state on a note/assignment — ticking items off is the
    # point, so create/update are on. Delete stays off by default; cancelling an item by
    # marking it done loses nothing, whereas deleting it loses the record that it existed.
    "task_items": {"read": True, "create": True, "update": True, "delete": False},
    "settings": {"read": True, "create": False, "update": False, "delete": False},
}


def get_value(conn: sqlite3.Connection, account_id: int, key: str) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT value FROM settings WHERE account_id = ? AND key = ?",
        (account_id, key),
    ).fetchone()
    if row is None:
        return None
    parsed: dict[str, Any] = json.loads(row["value"])
    return parsed


def set_value(conn: sqlite3.Connection, account_id: int, key: str, value: dict[str, Any]) -> None:
    conn.execute(
        "INSERT INTO settings (account_id, key, value, updated_at) VALUES (?, ?, ?, ?) "
        "ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
        (account_id, key, json.dumps(value), now_iso()),
    )


def seed_defaults(conn: sqlite3.Connection, account_id: int) -> None:
    """Seed an account's default settings on registration (no-op if already present)."""
    if get_value(conn, account_id, MCP_PERMISSIONS_KEY) is None:
        set_value(conn, account_id, MCP_PERMISSIONS_KEY, copy.deepcopy(DEFAULT_MCP_PERMISSIONS))


def mcp_permissions(conn: sqlite3.Connection, account_id: int) -> dict[str, dict[str, bool]]:
    """Effective MCP permission matrix for an account (stored, merged over defaults).

    Notes update/delete are force-disabled here regardless of stored values.
    """
    merged = copy.deepcopy(DEFAULT_MCP_PERMISSIONS)
    stored = get_value(conn, account_id, MCP_PERMISSIONS_KEY) or {}
    for entity, perms in stored.items():
        if entity in merged and isinstance(perms, dict):
            for action, allowed in perms.items():
                if action in merged[entity]:
                    merged[entity][action] = bool(allowed)
    # Hard Rule 1 backstop — notes are never destructible via MCP.
    merged["notes"]["update"] = False
    merged["notes"]["delete"] = False
    return merged


_NOTES_FORBIDDEN = {"update", "delete"}


def require_agent_permission(
    conn: sqlite3.Connection, account_id: int, entity: str, action: str, *, surface: str = "MCP"
) -> None:
    """Raise unless the account's permission matrix allows `action` on `entity` for an external
    agent. One enforcement point for every surface driven by someone other than the operator in
    their own app: the MCP tools AND runs a connected peer agent starts over A2A (`surface`
    names which, so the refusal reads right). Notes update/delete are refused unconditionally
    (Hard Rule 1), whatever the matrix says."""
    if entity == "notes" and action in _NOTES_FORBIDDEN:
        raise NotesImmutable(
            f"Notes cannot be {action}d via {surface} — they are read/create only.",
            hint="notes are the raw capture and are never destructible through the agent",
        )
    perms = mcp_permissions(conn, account_id)
    if not perms.get(entity, {}).get(action, False):
        raise PermissionDenied(
            f"{surface} '{action}' on '{entity}' is disabled in this account's settings.",
            hint=f"the operator can enable {entity}.{action} in the app's settings",
        )
