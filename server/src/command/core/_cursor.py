"""Opaque keyset-pagination cursors.

The MCP spec requires cursors be treated as opaque by clients (no parsing, no
fabrication). We encode a tiny JSON blob (the last-seen row id) as urlsafe
base64. Decoding a malformed cursor raises `ValidationError` (a 422), never a
bare exception that would 500 — a client can send any string as `cursor`.
"""

from __future__ import annotations

import base64
import binascii
import json
from typing import Any

from ..errors import ValidationError

_BAD = "omit `cursor` to start from the first page."


def encode(data: dict[str, Any]) -> str:
    raw = json.dumps(data, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def decode(cursor: str, *, require: tuple[str, ...] = ()) -> dict[str, Any]:
    """Decode an opaque cursor to its dict payload. Raises `ValidationError` on any
    malformed input — bad base64/JSON, a non-object payload, or a missing required
    key — so a hand-crafted or truncated cursor becomes a 422, not a 500."""
    pad = "=" * (-len(cursor) % 4)
    try:
        raw = base64.urlsafe_b64decode(cursor + pad)
        data: Any = json.loads(raw)
    except (binascii.Error, ValueError) as exc:
        raise ValidationError("Invalid pagination cursor.", hint=_BAD) from exc
    if not isinstance(data, dict) or any(k not in data for k in require):
        raise ValidationError("Invalid pagination cursor.", hint=_BAD)
    return data


def decode_id(cursor: str) -> int:
    """Decode a cursor whose payload is a single integer row id, fully validated."""
    data = decode(cursor, require=("id",))
    try:
        return int(data["id"])
    except (TypeError, ValueError) as exc:
        raise ValidationError("Invalid pagination cursor.", hint=_BAD) from exc
