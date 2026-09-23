"""Shared plumbing for MCP tool modules."""

from __future__ import annotations

import sqlite3
from collections.abc import Callable

import anyio
from mcp.server.fastmcp.exceptions import ToolError

from ...db import connection
from ...errors import CommandError
from ..context import current_account_id


async def run_for_account[T](db_path: str, fn: Callable[[sqlite3.Connection, int], T]) -> T:
    """Resolve the account (in the auth context), then run `fn(conn, account_id)` in a worker
    thread under a fresh connection. Domain errors become MCP tool errors (isError results)."""
    account_id = current_account_id()

    def work() -> T:
        try:
            with connection(db_path) as conn:
                return fn(conn, account_id)
        except CommandError as exc:
            message = exc.message + (f" (hint: {exc.hint})" if exc.hint else "")
            raise ToolError(message) from exc

    return await anyio.to_thread.run_sync(work)
