"""Outbound A2A calls — Command's agent asking a connected peer agent.

One synchronous JSON-RPC ``SendMessage`` per ask; the peer's direct-Message
reply text and contextId come back, and every exchange (success or failure)
lands in ``peer_exchanges``.
"""

from __future__ import annotations

import sqlite3
import uuid
from typing import Any, Protocol

from ...errors import CommandError, NotFound, ValidationError
from . import registry
from .safefetch import PeerFetchError, safe_https_json

A2A_TIMEOUT = 30.0
REPLY_MAX_BYTES = 256 * 1024

_FETCH_ERROR_MESSAGES = {
    "unreachable": "Connected agent '{name}' is unreachable — ask the user to check its URL.",
    "blocked_url": "Connected agent '{name}' has a non-public URL — it must be public HTTPS.",
    "auth": "Connected agent '{name}' rejected the stored token — ask the user to update it.",
    "timeout": "Connected agent '{name}' timed out — try again later.",
    "too_large": "Connected agent '{name}' sent an oversized reply — try a narrower question.",
    "protocol": "Connected agent '{name}' sent an invalid response — its A2A endpoint may be broken.",
}


class ReplyFetcher(Protocol):
    def __call__(
        self,
        url: str,
        *,
        method: str,
        body: dict[str, Any],
        bearer: str | None,
        max_bytes: int,
        timeout: float,
        _allow_http_hosts: frozenset[str],
    ) -> dict[str, Any]: ...


def ask_peer(
    conn: sqlite3.Connection,
    account_id: int,
    peer_name: str,
    message: str,
    *,
    context_id: str | None,
    _fetch: ReplyFetcher | None = None,
) -> dict[str, Any]:
    fetch = _fetch or safe_https_json
    try:
        peer = registry.get_peer(conn, account_id, peer_name)
    except NotFound:
        names = ", ".join(p.name for p in registry.list_peers(conn, account_id)) or "none"
        raise NotFound(
            f"No connected agent named '{peer_name}'. Connected agents: {names}."
        ) from None
    if not peer.enabled:
        raise ValidationError(
            f"Connected agent '{peer.name}' is disabled — the user can re-enable it in settings."
        )

    token = registry.get_token(conn, account_id, peer.name)
    a2a_message: dict[str, Any] = {
        "messageId": str(uuid.uuid4()),
        "role": "ROLE_USER",
        "parts": [{"text": message}],
    }
    if context_id:
        a2a_message["contextId"] = context_id
    request = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "SendMessage",
        "params": {"message": a2a_message},
    }

    def _log(status: str, response_text: str | None = None, ctx: str | None = None) -> None:
        registry.log_exchange(
            conn,
            account_id,
            peer_id=peer.id,
            direction="out",
            context_id=ctx or context_id,
            request_text=message,
            response_text=response_text,
            status=status,
        )

    try:
        response = fetch(
            peer.url,
            method="POST",
            body=request,
            bearer=token,
            max_bytes=REPLY_MAX_BYTES,
            timeout=A2A_TIMEOUT,
            _allow_http_hosts=registry._allow_http_hosts(),
        )
    except PeerFetchError as exc:
        _log(f"error:{exc.kind}")
        template = _FETCH_ERROR_MESSAGES.get(exc.kind, "Connected agent '{name}' failed: ")
        raise CommandError(template.format(name=peer.name)) from exc

    if "error" in response:
        # JSON-RPC says `error` is an object with a `message`, but this is another app's
        # output: a bare string (or anything else) used to raise AttributeError, which is not a
        # CommandError, so it escaped the tool guard and killed the whole agent run.
        err = response["error"]
        raw = err.get("message") if isinstance(err, dict) else err
        detail = str(raw)[:300] if raw not in (None, "") else "unknown error"
        _log("error:peer")
        raise CommandError(f"Connected agent '{peer.name}' returned an error: {detail}")

    result = response.get("result")
    reply = result.get("message") if isinstance(result, dict) else None
    if not isinstance(reply, dict):
        _log("error:protocol")
        raise CommandError(
            f"Connected agent '{peer.name}' answered with an async task — not supported yet."
        )

    parts = reply.get("parts")
    text = "\n".join(
        p["text"]
        for p in (parts if isinstance(parts, list) else [])
        if isinstance(p, dict) and isinstance(p.get("text"), str)
    )
    reply_context = reply.get("contextId") if isinstance(reply.get("contextId"), str) else None
    _log("ok", response_text=text, ctx=reply_context)
    return {"peer": peer.name, "reply": text, "context_id": reply_context}
