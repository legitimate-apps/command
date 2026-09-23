"""The session cookie — built in exactly one place.

Login, invite redemption, and the sliding-session refresh all issue the same cookie. When
that lived in three places the attributes drifted, and a refresh whose `max-age` differed
from login's would quietly re-introduce the fixed-window logout it exists to prevent.
"""

from __future__ import annotations

from starlette.responses import Response

from ..config import Settings


def set_session_cookie(response: Response, settings: Settings, raw_token: str) -> None:
    response.set_cookie(
        settings.cookie_name,
        raw_token,
        max_age=settings.session_days * 86400,
        httponly=True,
        secure=settings.cookie_secure,
        samesite="lax",
        path="/",
    )


def session_cookie_header(settings: Settings, raw_token: str) -> str:
    """The `Set-Cookie` header value, for layers that only have raw ASGI messages."""
    carrier = Response()
    set_session_cookie(carrier, settings, raw_token)
    return carrier.headers["set-cookie"]
