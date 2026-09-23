"""ASGI application factory: the FastAPI REST API plus the mounted MCP server.

One process, two surfaces. The MCP Streamable-HTTP app is mounted at the root so
its `/mcp` route is served alongside the `/api/*` routes (which are registered
first and therefore matched first). The MCP session manager's lifespan does not
propagate through a mount, so we run it explicitly in the FastAPI lifespan.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from . import __version__
from .config import get_settings
from .core import accounts as accounts_core
from .core import apns, reminder_job
from .core import delegatees as delegatees_core
from .core.peers import inbound as peers_inbound
from .db import connection, init_db
from .errors import CommandError
from .mcp.server import build_mcp
from .rest.activities import router as activities_router
from .rest.agent import router as agent_router
from .rest.assignments import router as assignments_router
from .rest.attachments import router as attachments_router
from .rest.auth import router as auth_router
from .rest.calendar_ics import router as calendar_router
from .rest.delegatees import router as delegatees_router
from .rest.goals import router as goals_router
from .rest.items import router as items_router
from .rest.legal import router as legal_router
from .rest.my import router as my_router
from .rest.notes import router as notes_router
from .rest.peers import router as peers_router
from .rest.push import router as push_router
from .rest.session_refresh import SessionRefreshMiddleware
from .rest.settings import router as settings_router
from .rest.webhooks import router as webhooks_router

# A2A messages carry at most 32 KB of text (a2a_adapter.MAX_TEXT_BYTES); JSON escaping can
# inflate that several-fold (a \uXXXX escape is 6 bytes per character), so allow headroom.
A2A_MAX_BODY_BYTES = 256 * 1024


class HealthCheckAccessFilter(logging.Filter):
    """Drop successful `/api/health` access lines from uvicorn's access log.

    The container health-check polls that endpoint every few seconds, and it was **94% of
    everything the server logged** (measured on the live container: 181 of 193 lines). A log
    that is nine-tenths one repeated line is useless for the thing a log exists for — reading
    back what actually happened — and it is pure cost in whatever retains it.

    Only *successful* probes are dropped, so a health-check that starts failing still appears.
    Uvicorn logs access records as `'%s - "%s %s HTTP/%s" %d'` with args
    `(client_addr, method, full_path, http_version, status_code)`; anything not matching that
    shape is passed through untouched rather than guessed at.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if not isinstance(args, tuple) or len(args) < 5:
            return True
        path, status = args[2], args[4]
        if not isinstance(path, str) or not isinstance(status, int):
            return True
        return not (path.split("?", 1)[0] == "/api/health" and 200 <= status < 300)


def create_app() -> FastAPI:
    settings = get_settings()
    logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO))
    logging.getLogger("uvicorn.access").addFilter(HealthCheckAccessFilter())

    mcp = build_mcp(settings)
    mcp_app = mcp.streamable_http_app()  # also lazily creates the session manager

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        init_db(settings.db_path)
        with connection(settings.db_path) as conn:
            delegatees_core.backfill_self(conn)  # ensure every existing account has a "Me" actor
            # Expiry is enforced on read; this only keeps the table from accumulating rows
            # for devices that were wiped or reinstalled and will never present again.
            reaped = accounts_core.purge_expired_sessions(conn)
            if reaped:
                logging.getLogger("command").info("purged %d expired session(s)", reaped)

        # Push reminder delivery (B4): a background loop that pushes due reminders. Only starts when
        # APNs is configured, so a dev/prod server without the key is completely unaffected.
        reminder_stop = asyncio.Event()
        reminder_task: asyncio.Task[None] | None = None
        if apns.configured():
            reminder_task = asyncio.create_task(
                reminder_job.run_loop(
                    settings.db_path, poll_seconds=settings.reminder_poll_seconds, stop=reminder_stop
                )
            )
            logging.getLogger("command").info("APNs reminder loop started")

        try:
            async with mcp.session_manager.run():  # mounted sub-app lifespans don't run; do it here
                yield
        finally:
            reminder_stop.set()
            if reminder_task is not None:
                await reminder_task

    app = FastAPI(title="Command", version=__version__, lifespan=lifespan)

    # Sliding sessions: the auth dependency slides the expiry, this re-issues the cookie so
    # the client's copy slides with it (see rest/session_refresh.py).
    app.add_middleware(SessionRefreshMiddleware, settings=settings)

    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    @app.exception_handler(CommandError)
    async def _command_error_handler(request: Request, exc: CommandError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status,
            content={"error": exc.to_envelope().model_dump(exclude_none=True)},
        )

    for r in (
        auth_router,
        my_router,
        notes_router,
        delegatees_router,
        goals_router,
        assignments_router,
        attachments_router,
        activities_router,
        calendar_router,
        items_router,
        settings_router,
        agent_router,
        peers_router,
        webhooks_router,
        legal_router,
        push_router,
    ):
        app.include_router(r)

    @app.get("/api/health", tags=["meta"])
    def health() -> dict[str, str]:
        return {"status": "ok", "service": "command", "version": __version__}

    # Inbound A2A surface: agent card + JSON-RPC endpoint (bearer = the same
    # per-account access token the MCP surface uses).
    a2a_adapter = peers_inbound.build_adapter(settings.db_path, settings)

    @app.get("/.well-known/agent-card.json", tags=["a2a"])
    def agent_card() -> dict[str, Any]:
        return a2a_adapter.card()

    @app.post("/a2a", tags=["a2a"])
    async def a2a_rpc(request: Request) -> JSONResponse:
        auth = request.headers.get("authorization") or ""
        token = auth[7:].strip() if auth.lower().startswith("bearer ") else None
        # Authenticate FIRST, then read a capped body. This used to buffer the whole request
        # body — any size, from anyone — before looking at the token.
        principal = await run_in_threadpool(a2a_adapter.authenticate, token)
        if principal is None:
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        declared = request.headers.get("content-length")
        if declared is not None and declared.isdigit() and int(declared) > A2A_MAX_BODY_BYTES:
            return JSONResponse({"error": "request body too large"}, status_code=413)
        chunks: list[bytes] = []
        size = 0
        async for chunk in request.stream():
            size += len(chunk)
            if size > A2A_MAX_BODY_BYTES:
                return JSONResponse({"error": "request body too large"}, status_code=413)
            chunks.append(chunk)
        # The turn blocks (it runs a full agent turn) — keep the loop free.
        payload = await run_in_threadpool(
            a2a_adapter.handle_authenticated, b"".join(chunks), principal
        )
        return JSONResponse(payload, status_code=200)

    # MCP last: it serves /mcp; the /api routes above are matched first.
    app.mount("/", mcp_app)

    return app


app = create_app()
