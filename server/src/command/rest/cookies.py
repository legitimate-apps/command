"""The session cookie — built in exactly one place.

Login, invite redemption, and the sliding-session refresh all issue the same cookie. When
that lived in three places the attributes drifted, and a refresh whose `max-age` differed
from login's would quietly re-introduce the fixed-window logout it exists to prevent.
"""

from __future__ import annotations

from collections.abc import MutableMapping
from typing import Any

from starlette.datastructures import Headers
from starlette.responses import Response

from ..config import Settings


def scope_is_https(scope: MutableMapping[str, Any]) -> bool:
    """Whether the client reached us over HTTPS, directly or through a TLS-terminating proxy.

    X-Forwarded-Proto is trusted from anyone: all it can do is make the caller's own cookie
    Secure, which only ever withholds that cookie from plain http.
    """
    if scope.get("scheme") == "https":
        return True
    proto = Headers(scope=scope).get("x-forwarded-proto", "")
    return proto.split(",")[0].strip().lower() == "https"


def cookie_is_secure(settings: Settings, scope: MutableMapping[str, Any]) -> bool:
    if settings.cookie_secure is not None:
        return settings.cookie_secure
    return scope_is_https(scope)


def set_session_cookie(
    response: Response, settings: Settings, raw_token: str, *, secure: bool
) -> None:
    response.set_cookie(
        settings.cookie_name,
        raw_token,
        max_age=settings.session_days * 86400,
        httponly=True,
        secure=secure,
        samesite="lax",
        path="/",
    )


def session_cookie_header(settings: Settings, raw_token: str, scope: MutableMapping[str, Any]) -> str:
    """The `Set-Cookie` header value, for layers that only have raw ASGI messages."""
    carrier = Response()
    set_session_cookie(carrier, settings, raw_token, secure=cookie_is_secure(settings, scope))
    return carrier.headers["set-cookie"]
