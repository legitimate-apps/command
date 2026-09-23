"""Operator endpoints. Today: the backup download.

`GET /api/admin/backup` with `Authorization: Bearer <COMMAND_BACKUP_TOKEN>` streams a tar.gz of
a consistent database snapshot plus the attachments directory (core/backup.py). The route does
not exist — 404 — unless a token is configured, so a server that never opted in exposes
nothing. This is the only cross-account surface on the server, and it reads no account's data
through the API: it hands the operator the whole store, which they already hold on disk.
"""

from __future__ import annotations

import hmac
import threading
import weakref
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool, run_in_threadpool

from ..config import get_settings
from ..core import attachments as attachments_core
from ..core import backup as backup_core
from ..core.ratelimit import SlidingWindowLimiter
from ..errors import AuthFailed, NotFound, RateLimited
from .client_ip import client_ip

router = APIRouter(prefix="/api/admin", tags=["admin"])

# Wrong tokens per client address. The token is a long random secret, so this is about
# keeping a scanner from hammering the route, not about the search space.
_backup_failures = SlidingWindowLimiter(max_attempts=10, window_seconds=900.0)
# One backup at a time: each holds a snapshot on the data volume while it streams.
_backup_running = threading.Lock()


def _presented_token(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    return auth[7:].strip() if auth.lower().startswith("bearer ") else ""


@router.get("/backup")
async def backup(request: Request) -> StreamingResponse:
    settings = get_settings()
    expected = settings.backup_token
    if not expected:
        raise NotFound("Not found.")
    ip = client_ip(request, settings.trusted_proxy_hops)
    if not _backup_failures.allowed(ip):
        raise RateLimited("Too many failed backup attempts. Try again later.")
    if not hmac.compare_digest(_presented_token(request).encode(), expected.encode()):
        _backup_failures.record_failure(ip)
        raise AuthFailed(
            "Bad backup token.", hint="Send Authorization: Bearer <COMMAND_BACKUP_TOKEN>."
        )
    if not _backup_running.acquire(blocking=False):
        raise RateLimited("A backup is already in progress. Try again when it finishes.")

    try:
        snapshot = await run_in_threadpool(backup_core.snapshot_database, settings.db_path)
    except BaseException:
        _backup_running.release()
        raise
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    prefix = f"command-backup-{stamp}"
    root = Path(attachments_core.storage_root())

    finish = _Finish(snapshot)
    chunks = backup_core.archive_chunks(snapshot, root, prefix)

    async def body() -> AsyncIterator[bytes]:
        try:
            # Compression and file reads happen on a worker thread, chunk by chunk.
            async for chunk in iterate_in_threadpool(chunks):
                yield chunk
        finally:
            chunks.close()
            finish()

    stream = body()
    # A client that disconnects before the first chunk leaves the generator un-started, and
    # an un-started generator never runs its `finally`. The finalizer (and the background
    # task, which Starlette runs after most disconnects) make sure the snapshot is removed
    # and the lock released anyway; `_Finish` runs once however many of them fire.
    weakref.finalize(stream, finish)
    return StreamingResponse(
        stream,
        media_type="application/gzip",
        headers={
            "Content-Disposition": f'attachment; filename="{prefix}.tar.gz"',
            "Cache-Control": "no-store",
        },
        background=BackgroundTask(finish),
    )


class _Finish:
    """Remove the snapshot and release the one-backup lock — exactly once."""

    def __init__(self, snapshot: Path) -> None:
        self._snapshot = snapshot
        self._done = False
        self._lock = threading.Lock()

    def __call__(self) -> None:
        with self._lock:
            if self._done:
                return
            self._done = True
        backup_core.cleanup(self._snapshot)
        _backup_running.release()
