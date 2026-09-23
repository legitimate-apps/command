"""Connected peer agents (A2A) — per-account registry + exchange audit log.

A peer is another app's agent, added by URL: we fetch its Agent Card
(SSRF-guarded), derive a slug from the card name, and store the card, its
JSON-RPC endpoint, and an optional bearer token (AES-GCM encrypted at rest;
key derived from ``COMMAND_PEER_TOKEN_KEY``). Tokens are write-only through
the public models — only :func:`get_token` (the outbound call path) can
recover one.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Any, Protocol
from urllib.parse import urlsplit, urlunsplit

from pydantic import BaseModel

from ...config import get_settings
from ...db import now_iso
from ...errors import NotFound, ValidationError
from .. import sealed
from .._unset import UNSET, Unset
from ..delegatees import slugify
from .safefetch import safe_https_json

WELL_KNOWN_PATH = "/.well-known/agent-card.json"
CARD_MAX_BYTES = 64 * 1024
CARD_TIMEOUT = 10.0


class CardFetcher(Protocol):
    def __call__(
        self,
        url: str,
        *,
        max_bytes: int,
        timeout: float,
        _allow_http_hosts: frozenset[str],
    ) -> dict[str, Any]: ...


class Peer(BaseModel):
    id: int
    account_id: int
    name: str
    card_url: str
    url: str
    card: dict[str, Any]
    card_fetched_at: str
    has_token: bool
    enabled: bool
    created_at: str
    updated_at: str


def _row(r: sqlite3.Row) -> Peer:
    return Peer(
        id=r["id"],
        account_id=r["account_id"],
        name=r["name"],
        card_url=r["card_url"],
        url=r["url"],
        card=json.loads(r["card_json"]),
        card_fetched_at=r["card_fetched_at"],
        has_token=r["token_ciphertext"] is not None,
        enabled=bool(r["enabled"]),
        created_at=r["created_at"],
        updated_at=r["updated_at"],
    )


_TOKEN_PURPOSE = b"peer-token"


def _allow_http_hosts() -> frozenset[str]:
    """Dev/e2e-only escape hatch (COMMAND_PEER_ALLOW_HTTP_HOSTS); empty in prod."""
    raw = get_settings().peer_allow_http_hosts
    return frozenset(h.strip() for h in raw.split(",") if h.strip())


def _encrypt_token(token: str) -> str:
    return sealed.seal(token, purpose=_TOKEN_PURPOSE)


def _decrypt_token(ciphertext: str) -> str:
    return sealed.unseal(ciphertext, purpose=_TOKEN_PURPOSE)


def _card_fetch_url(user_url: str) -> str:
    """A bare base URL gets the well-known card path appended; full paths pass through."""
    parts = urlsplit(user_url.strip())
    if parts.path in ("", "/") and not parts.query:
        return urlunsplit((parts.scheme, parts.netloc, WELL_KNOWN_PATH, "", ""))
    return user_url.strip()


def _endpoint_from_card(card: dict[str, Any]) -> str:
    interfaces = card.get("supportedInterfaces")
    if isinstance(interfaces, list):
        for interface in interfaces:
            url: object = interface.get("url") if isinstance(interface, dict) else None
            if (
                isinstance(interface, dict)
                and interface.get("protocolBinding") == "JSONRPC"
                and isinstance(url, str)
            ):
                return url
    raise ValidationError(
        "That agent's card has no JSON-RPC interface — Command can only talk to "
        "A2A v1.0 agents with a JSONRPC binding."
    )


def _validate_card(card: dict[str, Any]) -> None:
    if not isinstance(card.get("name"), str) or not card["name"].strip():
        raise ValidationError("That agent's card has no name — is the URL an A2A agent card?")


def _unique_name(conn: sqlite3.Connection, account_id: int, base: str) -> str:
    name, n = base, 2
    while conn.execute(
        "SELECT 1 FROM peers WHERE account_id = ? AND name = ?", (account_id, name)
    ).fetchone():
        name, n = f"{base}-{n}", n + 1
    return name


def add_peer(
    conn: sqlite3.Connection,
    account_id: int,
    card_url: str,
    *,
    token: str | None,
    _fetch: CardFetcher | None = None,
) -> Peer:
    fetch = _fetch or safe_https_json
    fetch_url = _card_fetch_url(card_url)
    card = fetch(
        fetch_url,
        max_bytes=CARD_MAX_BYTES,
        timeout=CARD_TIMEOUT,
        _allow_http_hosts=_allow_http_hosts(),
    )
    _validate_card(card)
    endpoint = _endpoint_from_card(card)
    name = _unique_name(conn, account_id, slugify(card["name"]))
    ts = now_iso()
    conn.execute(
        "INSERT INTO peers (account_id, name, card_url, url, card_json, card_fetched_at,"
        " token_ciphertext, enabled, created_at, updated_at)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)",
        (
            account_id,
            name,
            fetch_url,
            endpoint,
            json.dumps(card),
            ts,
            _encrypt_token(token) if token else None,
            ts,
            ts,
        ),
    )
    conn.commit()
    return get_peer(conn, account_id, name)


def list_peers(conn: sqlite3.Connection, account_id: int) -> list[Peer]:
    rows = conn.execute(
        "SELECT * FROM peers WHERE account_id = ? ORDER BY name", (account_id,)
    ).fetchall()
    return [_row(r) for r in rows]


def _peer_row(conn: sqlite3.Connection, account_id: int, name: str) -> sqlite3.Row:
    row: sqlite3.Row | None = conn.execute(
        "SELECT * FROM peers WHERE account_id = ? AND name = ?", (account_id, name)
    ).fetchone()
    if row is None:
        raise NotFound(f"No connected agent named '{name}'.")
    return row


def get_peer(conn: sqlite3.Connection, account_id: int, name: str) -> Peer:
    return _row(_peer_row(conn, account_id, name))


def get_token(conn: sqlite3.Connection, account_id: int, name: str) -> str | None:
    """Decrypt and return the peer's bearer token — outbound call path only."""
    ciphertext: str | None = _peer_row(conn, account_id, name)["token_ciphertext"]
    return _decrypt_token(ciphertext) if ciphertext else None


def update_peer(
    conn: sqlite3.Connection,
    account_id: int,
    name: str,
    *,
    token: str | Unset | None = UNSET,
    enabled: bool | Unset = UNSET,
) -> Peer:
    _peer_row(conn, account_id, name)  # NotFound check
    sets: list[str] = []
    params: list[str | int | None] = []
    if token is not UNSET:
        sets.append("token_ciphertext = ?")
        params.append(_encrypt_token(token) if token else None)
    if enabled is not UNSET:
        sets.append("enabled = ?")
        params.append(1 if enabled else 0)
    if sets:
        sets.append("updated_at = ?")
        params.append(now_iso())
        conn.execute(
            f"UPDATE peers SET {', '.join(sets)} WHERE account_id = ? AND name = ?",
            (*params, account_id, name),
        )
        conn.commit()
    return get_peer(conn, account_id, name)


def delete_peer(conn: sqlite3.Connection, account_id: int, name: str) -> None:
    _peer_row(conn, account_id, name)
    conn.execute("DELETE FROM peers WHERE account_id = ? AND name = ?", (account_id, name))
    conn.commit()


def refresh_card(
    conn: sqlite3.Connection, account_id: int, name: str, *, _fetch: CardFetcher | None = None
) -> Peer:
    fetch = _fetch or safe_https_json
    row = _peer_row(conn, account_id, name)
    card = fetch(
        row["card_url"],
        max_bytes=CARD_MAX_BYTES,
        timeout=CARD_TIMEOUT,
        _allow_http_hosts=_allow_http_hosts(),
    )
    _validate_card(card)
    endpoint = _endpoint_from_card(card)
    conn.execute(
        "UPDATE peers SET card_json = ?, url = ?, card_fetched_at = ?, updated_at = ?"
        " WHERE account_id = ? AND name = ?",
        (json.dumps(card), endpoint, now_iso(), now_iso(), account_id, name),
    )
    conn.commit()
    return get_peer(conn, account_id, name)


def log_exchange(
    conn: sqlite3.Connection,
    account_id: int,
    *,
    peer_id: int | None,
    direction: str,
    context_id: str | None,
    request_text: str,
    response_text: str | None,
    status: str,
) -> int:
    cur = conn.execute(
        "INSERT INTO peer_exchanges (account_id, peer_id, direction, context_id,"
        " request_text, response_text, status, created_at)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (account_id, peer_id, direction, context_id, request_text, response_text, status, now_iso()),
    )
    conn.commit()
    return int(cur.lastrowid or 0)
