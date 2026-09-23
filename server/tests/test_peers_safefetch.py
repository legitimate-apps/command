"""SSRF-guard tests for core.peers.safefetch.

No test touches the real network: DNS cases monkeypatch socket.getaddrinfo,
and live-request cases use a loopback http.server enabled via the
``_allow_http_hosts`` test hook (which also skips the private-IP rejection
for that host, since the whole point of the hook is loopback testing).
"""

import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import ClassVar

import pytest

from command.core.peers.safefetch import PeerFetchError, safe_https_json

ALLOW_LOCAL = frozenset({"127.0.0.1", "localhost"})


def _addrinfo(ip):
    family = socket.AF_INET6 if ":" in ip else socket.AF_INET
    return [(family, socket.SOCK_STREAM, 6, "", (ip, 443))]


class _Handler(BaseHTTPRequestHandler):
    routes: ClassVar[dict] = {}

    def _serve(self):
        entry = self.routes.get(self.path)
        if entry is None:
            self.send_response(404)
            self.end_headers()
            return
        status, headers, body = entry
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # BaseHTTPRequestHandler dispatches on these exact mixedCase names.
    do_GET = _serve  # noqa: N815
    do_POST = _serve  # noqa: N815

    def log_message(self, *args):
        pass


@pytest.fixture
def local_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    _Handler.routes = {}
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server
    server.shutdown()
    _Handler.routes = {}


def _url(server, path):
    return f"http://127.0.0.1:{server.server_address[1]}{path}"


def test_http_scheme_blocked_without_hook():
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json("http://example.com/card.json", max_bytes=1024, timeout=2)
    assert exc.value.kind == "blocked_url"


@pytest.mark.parametrize(
    "ip",
    ["10.0.0.5", "127.0.0.1", "169.254.1.1", "192.168.1.1", "::1", "fd00::1", "0.0.0.0"],
)
def test_literal_private_ips_blocked(ip):
    host = f"[{ip}]" if ":" in ip else ip
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json(f"https://{host}/card.json", max_bytes=1024, timeout=2)
    assert exc.value.kind == "blocked_url"


def test_hostname_resolving_to_private_ip_blocked(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: _addrinfo("10.0.0.5"))
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json("https://evil.example.com/card.json", max_bytes=1024, timeout=2)
    assert exc.value.kind == "blocked_url"


def test_hostname_with_any_private_answer_blocked(monkeypatch):
    """DNS answers mixing one public and one private IP must be rejected."""
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda *a, **k: _addrinfo("93.184.216.34") + _addrinfo("10.0.0.5"),
    )
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json("https://mixed.example.com/card.json", max_bytes=1024, timeout=2)
    assert exc.value.kind == "blocked_url"


def test_happy_path_get_json(local_server):
    body = json.dumps({"name": "Pantry"}).encode()
    _Handler.routes["/card.json"] = (200, {"Content-Type": "application/json"}, body)
    result = safe_https_json(
        _url(local_server, "/card.json"),
        max_bytes=65536,
        timeout=2,
        _allow_http_hosts=ALLOW_LOCAL,
    )
    assert result == {"name": "Pantry"}


def test_post_sends_body_and_bearer(local_server):
    captured = {}

    class Capture(_Handler):
        pass

    def _serve(handler):
        length = int(handler.headers.get("Content-Length", 0))
        captured["body"] = handler.rfile.read(length)
        captured["auth"] = handler.headers.get("Authorization")
        payload = json.dumps({"ok": True}).encode()
        handler.send_response(200)
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        handler.wfile.write(payload)

    _Handler.do_POST = _serve
    try:
        result = safe_https_json(
            _url(local_server, "/a2a"),
            method="POST",
            body={"jsonrpc": "2.0"},
            bearer="tok-123",
            max_bytes=65536,
            timeout=2,
            _allow_http_hosts=ALLOW_LOCAL,
        )
    finally:
        _Handler.do_POST = _Handler._serve
    assert result == {"ok": True}
    assert json.loads(captured["body"]) == {"jsonrpc": "2.0"}
    assert captured["auth"] == "Bearer tok-123"


def test_redirect_to_private_host_blocked(local_server):
    _Handler.routes["/hop"] = (302, {"Location": "https://10.0.0.5/steal"}, b"")
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json(
            _url(local_server, "/hop"),
            max_bytes=1024,
            timeout=2,
            _allow_http_hosts=ALLOW_LOCAL,
        )
    assert exc.value.kind == "blocked_url"


def test_redirect_followed_and_capped(local_server):
    port = local_server.server_address[1]
    body = json.dumps({"here": True}).encode()
    _Handler.routes["/a"] = (302, {"Location": f"http://127.0.0.1:{port}/b"}, b"")
    _Handler.routes["/b"] = (302, {"Location": f"http://127.0.0.1:{port}/c"}, b"")
    _Handler.routes["/c"] = (200, {}, body)
    result = safe_https_json(
        _url(local_server, "/a"), max_bytes=1024, timeout=2, _allow_http_hosts=ALLOW_LOCAL
    )
    assert result == {"here": True}

    # Four hops exceeds the 3-redirect cap.
    _Handler.routes["/r1"] = (302, {"Location": f"http://127.0.0.1:{port}/r2"}, b"")
    _Handler.routes["/r2"] = (302, {"Location": f"http://127.0.0.1:{port}/r3"}, b"")
    _Handler.routes["/r3"] = (302, {"Location": f"http://127.0.0.1:{port}/r4"}, b"")
    _Handler.routes["/r4"] = (302, {"Location": f"http://127.0.0.1:{port}/c"}, b"")
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json(
            _url(local_server, "/r1"), max_bytes=1024, timeout=2, _allow_http_hosts=ALLOW_LOCAL
        )
    assert exc.value.kind == "protocol"


def test_cross_origin_redirect_strips_bearer(local_server):
    """A redirect to a different origin must not carry the Authorization header."""
    port = local_server.server_address[1]
    seen = {}

    def _serve(handler):
        seen[handler.path] = handler.headers.get("Authorization")
        if handler.path == "/start":
            handler.send_response(302)
            # localhost vs 127.0.0.1 = different origin, same physical server.
            handler.send_header("Location", f"http://localhost:{port}/elsewhere")
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            return
        payload = json.dumps({"ok": True}).encode()
        handler.send_response(200)
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        handler.wfile.write(payload)

    _Handler.do_GET = _serve
    try:
        result = safe_https_json(
            _url(local_server, "/start"),
            bearer="tok-secret",
            max_bytes=1024,
            timeout=2,
            _allow_http_hosts=ALLOW_LOCAL,
        )
    finally:
        _Handler.do_GET = _Handler._serve
    assert result == {"ok": True}
    assert seen["/start"] == "Bearer tok-secret"
    assert seen["/elsewhere"] is None


def test_same_origin_redirect_keeps_bearer(local_server):
    port = local_server.server_address[1]
    seen = {}

    def _serve(handler):
        seen[handler.path] = handler.headers.get("Authorization")
        if handler.path == "/start":
            handler.send_response(302)
            handler.send_header("Location", f"http://127.0.0.1:{port}/next")
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            return
        payload = json.dumps({"ok": True}).encode()
        handler.send_response(200)
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        handler.wfile.write(payload)

    _Handler.do_GET = _serve
    try:
        safe_https_json(
            _url(local_server, "/start"),
            bearer="tok-secret",
            max_bytes=1024,
            timeout=2,
            _allow_http_hosts=ALLOW_LOCAL,
        )
    finally:
        _Handler.do_GET = _Handler._serve
    assert seen["/next"] == "Bearer tok-secret"


def test_oversize_response_rejected(local_server):
    _Handler.routes["/big"] = (200, {}, b"x" * 2048)
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json(
            _url(local_server, "/big"), max_bytes=1024, timeout=2, _allow_http_hosts=ALLOW_LOCAL
        )
    assert exc.value.kind == "too_large"


def test_auth_status_maps_to_auth_kind(local_server):
    _Handler.routes["/secret"] = (401, {}, b"")
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json(
            _url(local_server, "/secret"), max_bytes=1024, timeout=2, _allow_http_hosts=ALLOW_LOCAL
        )
    assert exc.value.kind == "auth"


def test_non_json_body_is_protocol_error(local_server):
    _Handler.routes["/html"] = (200, {}, b"<html>hello</html>")
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json(
            _url(local_server, "/html"), max_bytes=1024, timeout=2, _allow_http_hosts=ALLOW_LOCAL
        )
    assert exc.value.kind == "protocol"


def test_unreachable_host_maps_to_unreachable(monkeypatch):
    def _fail(*a, **k):
        raise socket.gaierror("nope")

    monkeypatch.setattr(socket, "getaddrinfo", _fail)
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json("https://gone.example.com/card.json", max_bytes=1024, timeout=2)
    assert exc.value.kind == "unreachable"


def test_error_messages_are_actionable():
    with pytest.raises(PeerFetchError) as exc:
        safe_https_json("https://127.0.0.1/card.json", max_bytes=1024, timeout=2)
    assert "public HTTPS" in str(exc.value)
