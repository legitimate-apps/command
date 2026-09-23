"""What this server is, and the owner's model key (docs/specs/2026-09-23-command-cloud.md).

`GET /api/server/info` is public: the app reads it before anyone has signed in, to label the
server, decide whether to offer "Create account", and whether to ask for an AI key. It reveals
nothing an account owns.

`PUT`/`DELETE /api/server/ai-key` let the owner of a self-hosted server supply the assistant's
model key from the app instead of editing env and restarting.
"""

from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel, Field

from ..core import instance
from ..core.ai import key as ai_key
from ..errors import ManagedByEnv, NotOwner
from .deps import Config, CurrentAccount, Db

router = APIRouter(prefix="/api/server", tags=["server"])


class AiKeyIn(BaseModel):
    api_key: str = Field(max_length=ai_key.MAX_KEY_LENGTH + 64)


@router.get("/info", response_model=instance.ServerInfo)
def server_info(conn: Db, settings: Config) -> instance.ServerInfo:
    return instance.info(conn, settings)


def _require_settable_by_owner(conn: Db, settings: Config, account_id: int) -> None:
    if settings.is_cloud:
        raise ManagedByEnv(
            "This server's AI key is managed by its operator.",
            hint="Nothing to set here — the assistant on this server uses the operator's key.",
        )
    if ai_key.managed_by_env():
        raise ManagedByEnv(
            "This server's AI key is set in its configuration (COMMAND_AI_API_KEY).",
            hint="Change or remove COMMAND_AI_API_KEY where the server is deployed, then restart it.",
        )
    if not instance.is_owner(conn, account_id):
        raise NotOwner(
            "Only this server's owner can change its AI key.",
            hint="The owner is the first account created on this server.",
        )


@router.put("/ai-key", response_model=instance.ServerInfo)
def set_ai_key(
    body: AiKeyIn, account: CurrentAccount, conn: Db, settings: Config
) -> instance.ServerInfo:
    """Validate the key against the provider, then store it sealed. Takes effect at once."""
    _require_settable_by_owner(conn, settings, account.id)
    key = ai_key.normalize(body.api_key)
    conn.commit()  # no write transaction (the session slide) held across the provider call
    ai_key.validate(key)
    ai_key.store(conn, key)
    conn.commit()  # publish the key to the running process before reporting it configured
    return instance.info(conn, settings)


@router.delete("/ai-key", response_model=instance.ServerInfo)
def clear_ai_key(account: CurrentAccount, conn: Db, settings: Config) -> instance.ServerInfo:
    """Forget the owner-set key (idempotent). The assistant stops until a key is set again."""
    _require_settable_by_owner(conn, settings, account.id)
    ai_key.clear(conn)
    conn.commit()
    return instance.info(conn, settings)
