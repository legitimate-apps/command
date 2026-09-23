"""Per-account bearer auth for the MCP transport.

A `TokenVerifier` that resolves the presented memorable access token to its
account and stuffs the account id into `AccessToken.client_id`. The SDK's
auth middleware then makes that available inside every tool via
`get_access_token()` (see `context.py`), so each MCP session is scoped to
exactly one account.
"""

from __future__ import annotations

import anyio
from mcp.server.auth.provider import AccessToken, TokenVerifier

from ..core import accounts as accounts_core
from ..core import tokens
from ..core.accounts import Account
from ..db import connection


class AccountTokenVerifier(TokenVerifier):
    def __init__(self, db_path: str) -> None:
        self.db_path = db_path

    async def verify_token(self, token: str) -> AccessToken | None:
        if not token or not tokens.is_well_formed(token):
            return None
        account = await anyio.to_thread.run_sync(self._lookup, token)
        if account is None:
            return None
        # client_id carries the account id; scopes unused (single-tenant-per-token).
        return AccessToken(token=token, client_id=str(account.id), scopes=[], subject=account.username)

    def _lookup(self, token: str) -> Account | None:
        with connection(self.db_path) as conn:
            return accounts_core.account_for_access_token(conn, token)
