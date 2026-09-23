"""Connected peer agents (A2A) REST endpoints.

Add-by-URL: POST performs the SSRF-guarded card fetch and returns the stored
peer (card included so the client can show a confirm/preview). Tokens are
write-only — accepted on create/update, never present in any response.
"""

from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel

from ..core._unset import UNSET
from ..core.peers import registry
from ..core.peers.safefetch import PeerFetchError
from ..errors import ValidationError
from .deps import Config, CurrentAccount, Db

router = APIRouter(prefix="/api/peers", tags=["peers"])


class PeerCreate(BaseModel):
    card_url: str
    token: str | None = None


class PeerUpdate(BaseModel):
    token: str | None = None
    enabled: bool | None = None


class InboundInfo(BaseModel):
    card_url: str
    a2a_url: str


def _friendly(exc: PeerFetchError) -> ValidationError:
    if exc.kind == "blocked_url":
        return ValidationError(
            "That URL isn't reachable from Command — public HTTPS URLs only."
        )
    return ValidationError(str(exc))


@router.get("", response_model=list[registry.Peer])
def list_peers(account: CurrentAccount, conn: Db) -> list[registry.Peer]:
    return registry.list_peers(conn, account.id)


@router.post("", response_model=registry.Peer, status_code=201)
def add_peer(body: PeerCreate, account: CurrentAccount, conn: Db) -> registry.Peer:
    try:
        return registry.add_peer(conn, account.id, body.card_url, token=body.token)
    except PeerFetchError as exc:
        raise _friendly(exc) from exc


@router.get("/inbound-info", response_model=InboundInfo)
def inbound_info(account: CurrentAccount, settings: Config) -> InboundInfo:
    """Where to point another app at THIS account's agent. Authenticate the peer
    with your access token (GET /api/access-token) — not echoed here."""
    base = (settings.public_base_url or "http://localhost:8000").rstrip("/")
    return InboundInfo(card_url=f"{base}/.well-known/agent-card.json", a2a_url=f"{base}/a2a")


@router.get("/{name}", response_model=registry.Peer)
def get_peer(name: str, account: CurrentAccount, conn: Db) -> registry.Peer:
    return registry.get_peer(conn, account.id, name)


@router.patch("/{name}", response_model=registry.Peer)
def update_peer(name: str, body: PeerUpdate, account: CurrentAccount, conn: Db) -> registry.Peer:
    fields = body.model_dump(exclude_unset=True)
    return registry.update_peer(
        conn,
        account.id,
        name,
        token=fields.get("token", UNSET),
        enabled=fields.get("enabled", UNSET),
    )


@router.delete("/{name}", status_code=204)
def delete_peer(name: str, account: CurrentAccount, conn: Db) -> None:
    registry.delete_peer(conn, account.id, name)


@router.post("/{name}/refresh", response_model=registry.Peer)
def refresh_peer(name: str, account: CurrentAccount, conn: Db) -> registry.Peer:
    try:
        return registry.refresh_card(conn, account.id, name)
    except PeerFetchError as exc:
        raise _friendly(exc) from exc
