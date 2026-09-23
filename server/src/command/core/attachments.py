"""Attachments: any-file uploads on notes and assignments (spec 2026-07-19-later-bucket).

Bytes live on disk under `<attachments_dir>/<account_id>/<stored_name>` (an opaque uuid —
never the user-supplied filename, so path traversal is structurally impossible); SQLite holds
only metadata. Every delete path must remove the FILE as well as the row: entity delete
(assignments only — notes are undeletable, Hard Rule 1), attachment delete, account delete.

No MCP surface in v1 (deliberate — see the spec): note attachments are part of the raw-input
record, and exposing them to the agent needs the permissions-table design pass first.
"""

from __future__ import annotations

import hashlib
import shutil
import sqlite3
import uuid
from pathlib import Path

from pydantic import BaseModel

from ..config import get_settings
from ..db import after_commit, now_iso
from ..errors import NotFound, ValidationError
from . import assignments as assignments_core
from . import notes as notes_core

VALID_ENTITY_KINDS = {"note", "assignment"}


class Attachment(BaseModel):
    id: int
    account_id: int
    entity_kind: str
    entity_id: int
    filename: str
    mime: str
    size_bytes: int
    sha256: str
    created_at: str


def _row(r: sqlite3.Row) -> Attachment:
    return Attachment(**{k: r[k] for k in r.keys() if k != "stored_name"})


def storage_root() -> Path:
    settings = get_settings()
    if settings.attachments_dir:
        return Path(settings.attachments_dir)
    return Path(settings.db_path).resolve().parent / "attachments"


def _account_dir(account_id: int) -> Path:
    return storage_root() / str(account_id)


def _validate_entity(
    conn: sqlite3.Connection, account_id: int, entity_kind: str, entity_id: int
) -> None:
    """Raise NotFound unless the target entity exists and belongs to the account."""
    if entity_kind not in VALID_ENTITY_KINDS:
        raise ValidationError(
            f"Unknown entity_kind: {entity_kind!r}.", hint="Use 'note' or 'assignment'."
        )
    if entity_kind == "note":
        notes_core.get(conn, account_id, entity_id)
    else:
        assignments_core.get(conn, account_id, entity_id)


def save(
    conn: sqlite3.Connection,
    account_id: int,
    entity_kind: str,
    entity_id: int,
    *,
    filename: str,
    mime: str,
    data: bytes,
) -> Attachment:
    settings = get_settings()
    _validate_entity(conn, account_id, entity_kind, entity_id)
    if not data:
        raise ValidationError("Attachment is empty.")
    if len(data) > settings.max_attachment_bytes:
        limit_mb = settings.max_attachment_bytes // (1024 * 1024)
        raise ValidationError(
            f"Attachment is too large ({len(data)} bytes).",
            hint=f"The limit is {limit_mb} MB per file.",
        )
    count = conn.execute(
        "SELECT COUNT(*) AS n FROM attachments"
        " WHERE account_id = ? AND entity_kind = ? AND entity_id = ?",
        (account_id, entity_kind, entity_id),
    ).fetchone()["n"]
    if count >= settings.max_attachments_per_entity:
        raise ValidationError(
            f"This {entity_kind} already has {count} attachments.",
            hint=f"The limit is {settings.max_attachments_per_entity} per {entity_kind}; delete one first.",
        )
    name = (filename or "").strip().replace("/", "_").replace("\\", "_") or "attachment"
    stored = uuid.uuid4().hex
    directory = _account_dir(account_id)
    directory.mkdir(parents=True, exist_ok=True)
    # Atomic-enough for one process (Hard Rule 3): write a temp name, rename into place, and
    # only then insert the row — a crash mid-write leaves an orphan temp file, never a row
    # pointing at truncated bytes.
    tmp = directory / f".{stored}.tmp"
    final = directory / stored
    tmp.write_bytes(data)
    tmp.rename(final)
    try:
        cur = conn.execute(
            "INSERT INTO attachments (account_id, entity_kind, entity_id, filename, mime,"
            " size_bytes, sha256, stored_name, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                account_id,
                entity_kind,
                entity_id,
                name,
                mime or "application/octet-stream",
                len(data),
                hashlib.sha256(data).hexdigest(),
                stored,
                now_iso(),
            ),
        )
    except Exception:
        final.unlink(missing_ok=True)
        raise
    new_id = cur.lastrowid
    if new_id is None:  # pragma: no cover - sqlite always sets this after a successful INSERT
        # Reachable only if the INSERT somehow didn't produce a rowid. Without this the None
        # would be passed to `get`, which would raise a misleading "No such attachment" —
        # after the bytes are already on disk, leaving an orphan file and no explanation.
        final.unlink(missing_ok=True)
        raise RuntimeError("Attachment row was not created.")
    return get(conn, account_id, new_id)


def get(conn: sqlite3.Connection, account_id: int, attachment_id: int) -> Attachment:
    row = conn.execute(
        "SELECT * FROM attachments WHERE id = ? AND account_id = ?",
        (attachment_id, account_id),
    ).fetchone()
    if row is None:
        raise NotFound("No such attachment.")
    return _row(row)


def file_path(conn: sqlite3.Connection, account_id: int, attachment_id: int) -> Path:
    """The on-disk path for a download. Raises NotFound if the row or the file is gone."""
    row = conn.execute(
        "SELECT stored_name FROM attachments WHERE id = ? AND account_id = ?",
        (attachment_id, account_id),
    ).fetchone()
    if row is None:
        raise NotFound("No such attachment.")
    # `sqlite3.Row.__getitem__` is typed `Any`; str() keeps the joined result a real `Path`
    # instead of silently making this function's return type Any for every caller.
    path = _account_dir(account_id) / str(row["stored_name"])
    if not path.is_file():
        raise NotFound("Attachment file is missing on the server.")
    return path


def list_for(
    conn: sqlite3.Connection, account_id: int, entity_kind: str, entity_id: int
) -> list[Attachment]:
    _validate_entity(conn, account_id, entity_kind, entity_id)
    rows = conn.execute(
        "SELECT * FROM attachments WHERE account_id = ? AND entity_kind = ? AND entity_id = ?"
        " ORDER BY created_at, id",
        (account_id, entity_kind, entity_id),
    ).fetchall()
    return [_row(r) for r in rows]


def delete(conn: sqlite3.Connection, account_id: int, attachment_id: int) -> Attachment:
    row = conn.execute(
        "SELECT * FROM attachments WHERE id = ? AND account_id = ?",
        (attachment_id, account_id),
    ).fetchone()
    if row is None:
        raise NotFound("No such attachment.")
    conn.execute("DELETE FROM attachments WHERE id = ?", (attachment_id,))
    # The bytes go only once the row's deletion is durable — see db.after_commit.
    path = _account_dir(account_id) / row["stored_name"]
    after_commit(conn, lambda: path.unlink(missing_ok=True))
    return _row(row)


def delete_for_entity(
    conn: sqlite3.Connection, account_id: int, entity_kind: str, entity_id: int
) -> None:
    """Remove every attachment (rows + files) on one entity. Called from assignments.delete."""
    rows = conn.execute(
        "SELECT stored_name FROM attachments"
        " WHERE account_id = ? AND entity_kind = ? AND entity_id = ?",
        (account_id, entity_kind, entity_id),
    ).fetchall()
    conn.execute(
        "DELETE FROM attachments WHERE account_id = ? AND entity_kind = ? AND entity_id = ?",
        (account_id, entity_kind, entity_id),
    )
    paths = [_account_dir(account_id) / r["stored_name"] for r in rows]

    def unlink_all() -> None:
        for p in paths:
            p.unlink(missing_ok=True)

    # After commit: an entity delete that rolls back must still have its files.
    after_commit(conn, unlink_all)


def delete_for_account(account_id: int) -> None:
    """Remove the account's whole attachment directory. The rows go via the accounts-table
    cascade inside delete_account's transaction; this cleans the disk after commit."""
    shutil.rmtree(_account_dir(account_id), ignore_errors=True)
