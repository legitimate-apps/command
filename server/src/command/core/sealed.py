"""Secrets sealed at rest with the instance key (AES-256-GCM).

Stored third-party credentials — a connected peer's bearer token, the owner's model key — are
never kept in plaintext in SQLite. They are sealed with a key derived from the instance secret
`peer_token_key` (env, or generated once beside the database by config._fill_instance_secrets),
which lives OUTSIDE the database: a copy of the .db file alone, or a backup archive, does not
reveal them.

`purpose` is bound in as associated data, so a value sealed for one use cannot be replayed as
another (a peer token pasted into the model-key row fails to open). Wire format:
base64(nonce[12] || ciphertext || tag[16]).
"""

from __future__ import annotations

import base64
import hashlib
import os

from ..config import _DEV_PEER_TOKEN_KEY, get_settings


def _key() -> bytes:
    s = get_settings()
    key = s.peer_token_key
    if s.is_prod and (not key or key == _DEV_PEER_TOKEN_KEY):
        # Fail closed: compose passes ${COMMAND_PEER_TOKEN_KEY:-}, so a missing
        # .env value arrives as "" — never silently encrypt with a weak key in prod.
        raise RuntimeError("COMMAND_PEER_TOKEN_KEY must be set to a real secret in prod")
    return hashlib.sha256((key or _DEV_PEER_TOKEN_KEY).encode("utf-8")).digest()


def seal(value: str, *, purpose: bytes) -> str:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # lazy: keep idle RSS lean

    nonce = os.urandom(12)
    sealed = AESGCM(_key()).encrypt(nonce, value.encode("utf-8"), purpose)
    return base64.b64encode(nonce + sealed).decode("ascii")


def unseal(ciphertext: str, *, purpose: bytes) -> str:
    """Raises `cryptography.exceptions.InvalidTag` if the value was sealed under another key
    or purpose (e.g. the instance secret was rotated)."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # lazy: keep idle RSS lean

    raw = base64.b64decode(ciphertext)
    return AESGCM(_key()).decrypt(raw[:12], raw[12:], purpose).decode("utf-8")
