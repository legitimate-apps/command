"""Resolve the authenticated account inside an MCP tool call."""

from __future__ import annotations

from mcp.server.auth.middleware.auth_context import get_access_token

from ..errors import AuthFailed


def current_account_id() -> int:
    """The account id for the current MCP request, from the auth context.

    Raises AuthFailed if there is no authenticated token — which should never
    happen for a request that reached a tool (the transport enforces auth), but
    we fail closed rather than guess.
    """
    token = get_access_token()
    if token is None:
        raise AuthFailed("No authenticated account on this MCP request.")
    try:
        return int(token.client_id)
    except (TypeError, ValueError) as exc:  # pragma: no cover - malformed context
        raise AuthFailed("Malformed MCP auth context.") from exc
