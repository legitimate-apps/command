"""FastAPI dependencies: per-request DB connection + current-account resolution."""

from __future__ import annotations

import sqlite3
from collections.abc import Callable, Iterator
from typing import Annotated

from fastapi import Depends, Request

from ..config import Settings, get_settings
from ..core import accounts as accounts_core
from ..core import delegatee_access
from ..core.accounts import Account
from ..core.delegatees import Delegatee
from ..db import connect
from ..errors import AuthFailed, NotFound


def get_db(settings: Annotated[Settings, Depends(get_settings)]) -> Iterator[sqlite3.Connection]:
    """Open a connection for the request; commit on success, roll back on error."""
    conn = connect(settings.db_path)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def session_token_from_request(request: Request, settings: Settings) -> str | None:
    """Pull the app-session token from the Authorization bearer header or the cookie."""
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip() or None
    return request.cookies.get(settings.cookie_name)


def session_policy(settings: Settings) -> accounts_core.SessionPolicy:
    return accounts_core.SessionPolicy(
        idle_days=settings.session_days,
        absolute_days=settings.session_absolute_days,
        renew_after_seconds=settings.session_renew_after_seconds,
    )


SESSION_REFRESH_KEY = "command_session_refresh"


def cookie_refresher(request: Request, settings: Settings, token: str) -> Callable[[str], None]:
    """Build the `on_renew` callback that re-issues the session cookie.

    Handed through the ASGI scope rather than an injected `Response` because endpoints
    that return a Response object themselves (attachment `FileResponse`, the agent's
    `StreamingResponse`) never merge a dependency's response headers — those requests
    would silently keep the old cookie and expire on the client while the server thinks
    the session is fresh.

    Only cookie-borne sessions get a refreshed cookie: a bearer-token client (tests, the
    MCP-adjacent tooling) manages its own token and should not start collecting cookies.
    """
    from_cookie = request.cookies.get(settings.cookie_name) == token

    def _on_renew(_expires_at: str) -> None:
        if from_cookie:
            request.scope.setdefault("state", {})[SESSION_REFRESH_KEY] = token

    return _on_renew


def get_current_account(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
    conn: Annotated[sqlite3.Connection, Depends(get_db)],
) -> Account:
    token = session_token_from_request(request, settings)
    if token:
        account = accounts_core.get_session_account(
            conn,
            token,
            policy=session_policy(settings),
            on_renew=cookie_refresher(request, settings, token),
        )
        if account is not None:
            return account
        if delegatee_access.delegatee_for_session(conn, token) is not None:
            raise NotFound("Not found.")
    raise AuthFailed("Not authenticated.", hint="log in via POST /api/auth/login")


CurrentAccount = Annotated[Account, Depends(get_current_account)]


def get_current_delegatee(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
    conn: Annotated[sqlite3.Connection, Depends(get_db)],
) -> tuple[Account, Delegatee]:
    token = session_token_from_request(request, settings)
    scoped = delegatee_access.delegatee_for_session(
        conn,
        token or "",
        policy=session_policy(settings),
        on_renew=cookie_refresher(request, settings, token or ""),
    )
    if scoped is not None:
        return scoped
    raise AuthFailed("Not authenticated.", hint="redeem an invite via POST /api/auth/invite")


CurrentDelegatee = Annotated[tuple[Account, Delegatee], Depends(get_current_delegatee)]
Db = Annotated[sqlite3.Connection, Depends(get_db)]
Config = Annotated[Settings, Depends(get_settings)]
