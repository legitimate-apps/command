"""APNs token-based sender (B4).

Signs an ES256 JWT with the team's `.p8` auth key and pushes an alert to a device over HTTP/2
(APNs is HTTP/2 only). Disabled (no-op) unless the key path/id/team are configured, so a dev server
without the key behaves exactly as before. The JWT is cached and refreshed well inside APNs' 60-min
validity window; one key/topic serves the whole app. The device's stored environment
(sandbox = dev/TestFlight, production = App Store) selects the APNs host.
"""

from __future__ import annotations

import contextlib
import time
from dataclasses import dataclass
from functools import lru_cache
from typing import Any

import httpx
import jwt

from ..config import get_settings

PROD_HOST = "https://api.push.apple.com"
SANDBOX_HOST = "https://api.sandbox.push.apple.com"
_JWT_TTL_SECONDS = 50 * 60          # refresh before APNs' 60-min limit
_UNREGISTERED_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"}


@dataclass
class PushResult:
    ok: bool
    status: int
    reason: str | None = None
    unregistered: bool = False       # 410 / bad-token → the caller should delete the device token


def configured() -> bool:
    s = get_settings()
    return bool((s.apns_key or s.apns_key_path) and s.apns_key_id and s.apns_team_id)


def _signing_key() -> str:
    """The .p8 PEM: COMMAND_APNS_KEY's contents, else the file at COMMAND_APNS_KEY_PATH.

    Env UIs often flatten newlines, so a literal `\\n` in the value is read as a line break.
    """
    s = get_settings()
    if s.apns_key:
        return s.apns_key.replace("\\n", "\n")
    with open(s.apns_key_path) as f:  # type: ignore[arg-type]
        return f.read()


_jwt_cache: tuple[str, float] | None = None


def _bearer() -> str:
    """A cached ES256 provider JWT (iss=team, kid=key id). Refreshed every ~50 min."""
    global _jwt_cache
    now = time.time()
    if _jwt_cache is not None and now - _jwt_cache[1] < _JWT_TTL_SECONDS:
        return _jwt_cache[0]
    s = get_settings()
    token = jwt.encode(
        {"iss": s.apns_team_id, "iat": int(now)},
        _signing_key(),
        algorithm="ES256",
        headers={"kid": s.apns_key_id},
    )
    _jwt_cache = (token, now)
    return token


def reset_jwt_cache() -> None:
    """Drop the cached JWT (tests / key rotation)."""
    global _jwt_cache
    _jwt_cache = None


@lru_cache(maxsize=2)
def _client(sandbox: bool) -> httpx.Client:
    # One reusable HTTP/2 client per host (connection pooling to APNs).
    return httpx.Client(http2=True, timeout=10.0, base_url=SANDBOX_HOST if sandbox else PROD_HOST)


def send(
    device_token: str,
    *,
    title: str,
    body: str,
    environment: str = "production",
    collapse_id: str | None = None,
    extra: dict[str, Any] | None = None,
) -> PushResult:
    """Push an alert to one device token. Returns a PushResult; `unregistered=True` means the token
    is dead and should be removed. Never raises — transport errors come back as ok=False."""
    if not configured():
        return PushResult(ok=False, status=0, reason="apns_not_configured")
    s = get_settings()
    payload: dict[str, Any] = {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}}
    if extra:
        payload.update(extra)
    headers = {
        "authorization": f"bearer {_bearer()}",
        "apns-topic": s.apns_topic or "",
        "apns-push-type": "alert",
    }
    if collapse_id:
        headers["apns-collapse-id"] = collapse_id[:64]
    try:
        r = _client(environment == "sandbox").post(
            f"/3/device/{device_token}", headers=headers, json=payload
        )
    except Exception as e:  # transport failures are reported, not raised
        return PushResult(ok=False, status=0, reason=str(e)[:120])
    if r.status_code == 200:
        return PushResult(ok=True, status=200)
    reason: str | None = None
    with contextlib.suppress(Exception):
        reason = r.json().get("reason")
    unregistered = r.status_code == 410 or reason in _UNREGISTERED_REASONS
    return PushResult(ok=False, status=r.status_code, reason=reason, unregistered=unregistered)
