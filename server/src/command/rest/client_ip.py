"""The client's address, for per-IP rate limits — honoring X-Forwarded-For only as far as the
operator says proxies are in front (COMMAND_TRUSTED_PROXY_HOPS).

Each proxy APPENDS the address it received the request from, so with N trusted proxies the
client is the N-th entry from the right; everything further left was supplied by the client and
proves nothing. With 0 hops (the default) the header is ignored entirely and the connection's
peer address is used — any client can send the header, so trusting it by default would let
every request pick its own rate-limit bucket.

(Uvicorn itself rewrites the peer from X-Forwarded-For only when the peer is loopback — a
tunnel on the same host — so the 0-hop answer is still the real client in that setup.)
"""

from __future__ import annotations

from starlette.requests import Request


def client_ip(request: Request, trusted_hops: int) -> str:
    peer = request.client.host if request.client else "unknown"
    if trusted_hops <= 0:
        return peer
    entries = [
        part.strip()
        for header in request.headers.getlist("x-forwarded-for")
        for part in header.split(",")
        if part.strip()
    ]
    if not entries:
        return peer
    if len(entries) >= trusted_hops:
        return entries[-trusted_hops]
    # Fewer entries than proxies: the request entered past the outer ones, and the leftmost
    # entry is what the first proxy it did pass saw — the real connecting address.
    return entries[0]
