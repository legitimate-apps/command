"""What this server is, as the app needs to know before anyone signs in.

`GET /api/server/info` reports it (docs/specs/2026-09-23-command-cloud.md): the kind of server
(Command Cloud or someone's own), whether it takes new accounts, and whether the assistant has
a model key — and if not, whether the owner may supply one from the app.

The **owner** of a self-hosted server is its first account (the lowest id): the one that
claimed the instance through first-user-only registration.
"""

from __future__ import annotations

import sqlite3

from pydantic import BaseModel

from .. import __version__
from ..config import Settings
from .ai import key as ai_key


class AiInfo(BaseModel):
    configured: bool             # a model key is available to the assistant
    requires_subscription: bool  # Command Pro gates the assistant here
    key_settable: bool           # the owner may set a key from the app


class ServerInfo(BaseModel):
    service: str = "command"
    version: str = __version__
    kind: str                    # "cloud" | "self"
    registration_open: bool
    ai: AiInfo


def owner_account_id(conn: sqlite3.Connection) -> int | None:
    row = conn.execute("SELECT MIN(id) AS id FROM accounts").fetchone()
    return None if row is None or row["id"] is None else int(row["id"])


def is_owner(conn: sqlite3.Connection, account_id: int) -> bool:
    return owner_account_id(conn) == account_id


def registration_open(conn: sqlite3.Connection, settings: Settings) -> bool:
    """Whether POST /api/auth/register will accept a new account.

    Cloud follows COMMAND_ALLOW_REGISTRATION alone — its operator opens or closes signup. A
    self-hosted server is open until its owner exists (first-user-only), unless the owner
    deliberately reopened it with COMMAND_ALLOW_REGISTRATION=true."""
    if settings.allow_registration:
        return True
    if settings.is_cloud:
        return False
    return conn.execute("SELECT 1 FROM accounts LIMIT 1").fetchone() is None


def key_settable(settings: Settings) -> bool:
    """A self-hosted server with no key in env: its owner may set one from the app. Cloud keys
    are the operator's, supplied by env, never by an account."""
    return not settings.is_cloud and not ai_key.managed_by_env()


def info(conn: sqlite3.Connection, settings: Settings) -> ServerInfo:
    return ServerInfo(
        kind=settings.server_kind,
        registration_open=registration_open(conn, settings),
        ai=AiInfo(
            configured=ai_key.configured(),
            requires_subscription=settings.agent_require_subscription,
            key_settable=key_settable(settings),
        ),
    )
