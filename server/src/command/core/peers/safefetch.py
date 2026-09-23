"""SSRF-guarded outbound JSON fetcher for peer (A2A) traffic.

Every request: HTTPS only, every DNS answer must be a public IP, the TCP
connection is pinned to a validated IP (DNS-rebinding proof), redirects are
followed manually (max 3) with full re-validation per hop, and responses are
size-capped. ``_allow_http_hosts`` exists solely so tests can hit a loopback
``http.server``; production callers never pass it.
"""

from __future__ import annotations

import http.client
import ipaddress
import json
import socket
import ssl
import urllib.parse
from typing import Any

_MAX_REDIRECTS = 3
_REDIRECT_STATUSES = {301, 302, 303, 307, 308}


class PeerFetchError(Exception):
    """A peer fetch failed; ``kind`` is machine-readable, message actionable."""

    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind


def is_public_ip(value: str) -> bool:
    """True only for a globally routable unicast address.

    An allow-list (`is_global`), not a deny-list of private/loopback/...: the deny-list missed
    ranges that are neither "private" nor global — notably 100.64.0.0/10 (carrier-grade NAT,
    which is where Tailscale and many ISP-internal services live) — and every future special
    range would have been missed the same way. Multicast is excluded explicitly because some
    multicast blocks count as global. IPv4-mapped IPv6 is unwrapped first so
    `::ffff:127.0.0.1` is judged as the loopback it is.
    """
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip.is_global and not ip.is_multicast


_is_public_ip = is_public_ip   # historical private name, kept for existing callers


def _resolve_public_ip(host: str, port: int) -> str:
    """Resolve ``host`` and return one validated IP; reject any private answer."""

    bare = host.strip("[]")
    try:
        ipaddress.ip_address(bare)
    except ValueError:
        pass
    else:
        if not _is_public_ip(bare):
            raise PeerFetchError(
                "blocked_url",
                "That address isn't reachable from Command — public HTTPS URLs only",
            )
        return bare

    try:
        infos = socket.getaddrinfo(bare, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise PeerFetchError("unreachable", f"Could not resolve {host}") from exc
    # `sockaddr[0]` is the address for both AF_INET and AF_INET6, but the union of the two
    # sockaddr tuple shapes types it as `str | int`. Narrow explicitly and FAIL CLOSED on
    # anything that isn't a string, rather than str()-ing it into `_is_public_ip`, where an
    # unparseable value would be rejected for the right reason by accident.
    ips = [addr for info in infos if isinstance(addr := info[4][0], str)]
    if len(ips) != len(infos) or not ips or not all(_is_public_ip(ip) for ip in ips):
        raise PeerFetchError(
            "blocked_url",
            "That address isn't reachable from Command — public HTTPS URLs only",
        )
    return ips[0]


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS connection that dials a pre-validated IP while keeping SNI/Host."""

    def __init__(self, host: str, port: int, pinned_ip: str, timeout: float) -> None:
        # Keep our own reference to the TLS context. The base class stores it as the private
        # `_context`, which is not in typeshed and is not API we should be reaching into —
        # and reading it back is the one thing that MUST NOT silently degrade here, because
        # a context that isn't the verifying one turns the pinned dial into an unverified one.
        context = ssl.create_default_context()
        super().__init__(host, port, timeout=timeout, context=context)
        self._pinned_ip = pinned_ip
        self._verified_context = context

    def connect(self) -> None:  # pragma: no cover - exercised only against real TLS
        raw = socket.create_connection((self._pinned_ip, self.port), self.timeout)
        # server_hostname stays the ORIGINAL host so SNI and certificate validation are done
        # against the name, while the TCP connection went to the IP we already validated.
        self.sock = self._verified_context.wrap_socket(raw, server_hostname=self.host)


def safe_https_json(
    url: str,
    *,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    bearer: str | None = None,
    max_bytes: int,
    timeout: float,
    _allow_http_hosts: frozenset[str] = frozenset(),
) -> dict[str, Any]:
    """Fetch ``url`` and return its parsed JSON object, SSRF-guarded throughout."""

    return _fetch(url, method, body, bearer, max_bytes, timeout, _allow_http_hosts, hops=0)


def _fetch(
    url: str,
    method: str,
    body: dict[str, Any] | None,
    bearer: str | None,
    max_bytes: int,
    timeout: float,
    allow_http_hosts: frozenset[str],
    hops: int,
) -> dict[str, Any]:
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    test_host = host in allow_http_hosts

    if parsed.scheme != "https" and not (parsed.scheme == "http" and test_host):
        raise PeerFetchError(
            "blocked_url",
            "That address isn't reachable from Command — public HTTPS URLs only",
        )
    if not host:
        raise PeerFetchError("blocked_url", "That URL has no host — check the address")

    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"

    if test_host:
        conn: http.client.HTTPConnection = http.client.HTTPConnection(host, port, timeout=timeout)
    else:
        pinned_ip = _resolve_public_ip(host, port)
        conn = _PinnedHTTPSConnection(host, port, pinned_ip, timeout)

    headers = {"Accept": "application/json", "User-Agent": "command-peer/1"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    try:
        conn.request(method, path, body=payload, headers=headers)
        response = conn.getresponse()
        status = response.status

        if status in _REDIRECT_STATUSES:
            location = response.getheader("Location")
            if not location:
                raise PeerFetchError("protocol", "Peer sent a redirect with no destination")
            if hops + 1 > _MAX_REDIRECTS:
                raise PeerFetchError("protocol", "Peer redirected too many times")
            next_url = urllib.parse.urljoin(url, location)
            # Strip credentials on cross-origin redirects so a malicious peer
            # can't bounce the request elsewhere and capture the bearer token.
            next_parsed = urllib.parse.urlsplit(next_url)
            same_origin = (
                next_parsed.scheme == parsed.scheme
                and next_parsed.hostname == parsed.hostname
                and next_parsed.port == parsed.port
            )
            return _fetch(
                next_url,
                method,
                body,
                bearer if same_origin else None,
                max_bytes,
                timeout,
                allow_http_hosts,
                hops + 1,
            )

        if status in (401, 403):
            raise PeerFetchError("auth", "Peer rejected the token — check it and try again")
        if status >= 400:
            raise PeerFetchError("protocol", f"Peer returned HTTP {status}")

        data = response.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise PeerFetchError("too_large", "Peer response too large — refusing to read it")
    except PeerFetchError:
        raise
    except TimeoutError as exc:
        raise PeerFetchError("timeout", "Peer timed out — try again later") from exc
    except (OSError, http.client.HTTPException) as exc:
        raise PeerFetchError("unreachable", "Peer unreachable — check the URL") from exc
    finally:
        conn.close()

    try:
        parsed_json = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise PeerFetchError("protocol", "Peer did not return JSON") from exc
    if not isinstance(parsed_json, dict):
        raise PeerFetchError("protocol", "Peer returned JSON that isn't an object")
    return parsed_json
