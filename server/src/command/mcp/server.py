"""Build the FastMCP server: per-account bearer auth + all tool modules.

Streamable HTTP, mounted into the FastAPI app by `command.app`. DNS-rebinding
protection is disabled because the mandatory per-account bearer (not the Host
header) is the security boundary, and the public Host behind the Cloudflare
Tunnel is not localhost.
"""

from __future__ import annotations

from typing import Any

from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from ..config import Settings
from .auth import AccountTokenVerifier
from .instructions import INSTRUCTIONS
from .tools import activities, assignments, delegatees, detail, goals, meta, notes, schedule
from .tools import settings as settings_tools


def build_mcp(settings: Settings) -> FastMCP[Any]:
    base_url = settings.public_base_url or f"http://{settings.http_host}:{settings.http_port}"
    auth = AuthSettings(issuer_url=base_url, resource_server_url=base_url)  # type: ignore[arg-type]
    mcp: FastMCP[Any] = FastMCP(
        name="command",
        instructions=INSTRUCTIONS,
        host=settings.http_host,
        port=settings.http_port,
        streamable_http_path="/mcp",
        stateless_http=True,
        token_verifier=AccountTokenVerifier(settings.db_path),
        auth=auth,
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
    for module in (
        meta, notes, delegatees, goals, assignments, activities, schedule, detail,
        settings_tools
    ):
        module.register(mcp, settings)
    return mcp
