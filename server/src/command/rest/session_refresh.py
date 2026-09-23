"""Middleware that emits the refreshed session cookie for a slid session.

Pure ASGI on purpose. A `BaseHTTPMiddleware` runs the downstream app in its own task,
which historically interferes with streaming responses — and this app streams the agent's
replies over SSE. Wrapping `send` instead touches one header on `http.response.start` and
leaves the body untouched, so a stream stays a stream.

The auth dependency decides *whether* to refresh (it is the layer holding the DB and the
policy) and leaves the token in the ASGI scope; this layer only writes the header.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any

from starlette.datastructures import MutableHeaders

from ..config import Settings
from .cookies import session_cookie_header
from .deps import SESSION_REFRESH_KEY

Scope = dict[str, Any]
Message = dict[str, Any]
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]


class SessionRefreshMiddleware:
    def __init__(self, app: Callable[..., Awaitable[None]], settings: Settings) -> None:
        self.app = app
        self.settings = settings

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        state = scope.setdefault("state", {})

        async def send_wrapper(message: Message) -> None:
            if message["type"] == "http.response.start":
                token = state.pop(SESSION_REFRESH_KEY, None)
                if token:
                    MutableHeaders(scope=message).append(
                        "set-cookie", session_cookie_header(self.settings, token, scope)
                    )
            await send(message)

        await self.app(scope, receive, send_wrapper)
