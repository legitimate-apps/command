"""The model API key every AI call uses — from env, or set by the owner from the app.

Two sources, one accessor. `COMMAND_AI_API_KEY` (env) always wins: an operator who configured
the key in deployment keeps control of it, and the app cannot replace it (`managed_by_env`).
Without one, the owner of a self-hosted server may paste a key in the app; it is validated
against the provider, sealed with the instance key (core/sealed.py) into `instance_meta`, and
takes effect immediately — no restart, because every caller reads it through `api_key()`.

The stored key is never returned by any endpoint; only whether one is configured is.
"""

from __future__ import annotations

import logging
import sqlite3
import threading
from pathlib import Path

import httpx

from ...config import get_settings
from ...db import after_commit, connection
from ...errors import InvalidApiKey, ProviderUnavailable, ValidationError
from .. import sealed

logger = logging.getLogger(__name__)

META_KEY = "ai_api_key_sealed"
_PURPOSE = b"ai-api-key"
MAX_KEY_LENGTH = 512

# db_path -> decrypted stored key (None = none stored). Filled on first read, replaced on every
# set/clear, so the hot path (every note title, every agent turn) never touches SQLite or AES.
_cache: dict[str, str | None] = {}
_cache_lock = threading.Lock()


def env_key() -> str | None:
    return get_settings().ai_api_key or None


class _Unavailable(Exception):
    """The database isn't there (yet) — answer "no key" without caching the answer."""


def _load_stored(db_path: str) -> str | None:
    if not Path(db_path).exists():
        raise _Unavailable  # never create a database file just to look for a key
    try:
        with connection(db_path) as conn:
            row = conn.execute(
                "SELECT value FROM instance_meta WHERE key = ?", (META_KEY,)
            ).fetchone()
    except sqlite3.OperationalError as exc:  # not migrated yet
        raise _Unavailable from exc
    if row is None:
        return None
    try:
        return sealed.unseal(str(row["value"]), purpose=_PURPOSE)
    except Exception:
        # The instance secret changed (a restore onto a fresh volume, a rotated
        # COMMAND_PEER_TOKEN_KEY). The key is unrecoverable; report "not configured" so the
        # owner is asked for it again instead of every AI call failing mysteriously.
        logger.warning("stored AI key could not be decrypted (instance secret changed?); ignoring it")
        return None


def stored_key() -> str | None:
    db_path = get_settings().db_path
    with _cache_lock:
        if db_path in _cache:
            return _cache[db_path]
    try:
        value = _load_stored(db_path)
    except _Unavailable:
        return None
    with _cache_lock:
        _cache[db_path] = value
    return value


def api_key() -> str | None:
    """The effective key: env first, else the owner-set one. None ⇒ AI is unavailable."""
    return env_key() or stored_key()


def configured() -> bool:
    return api_key() is not None


def managed_by_env() -> bool:
    return env_key() is not None


# --- Validation ---------------------------------------------------------------------


def _status(url: str, key: str) -> int:
    """GET `url` with the key as a bearer; the HTTP status. Seam for tests."""
    resp = httpx.get(
        url,
        headers={"Authorization": f"Bearer {key}", "X-Title": "Command"},
        timeout=get_settings().ai_request_timeout,
    )
    return resp.status_code


def validate(key: str) -> None:
    """Prove the provider accepts `key`, or raise.

    OpenRouter's `GET /models` is public — it answers 200 to any key, including none — so it
    cannot tell a good key from a bad one. `GET /key` (the key's own metadata) is authenticated:
    verified 2026-09-23, a made-up key gets 401 and a real one 200. Other OpenAI-compatible
    providers have no `/key` (404) but do authenticate `/models`, so that is the fallback.
    """
    base = get_settings().ai_base_url.rstrip("/")
    try:
        status = _status(f"{base}/key", key)
        if status == 404:
            status = _status(f"{base}/models", key)
    except httpx.HTTPError as exc:
        raise ProviderUnavailable(
            "Couldn't reach the model provider to check this key.",
            hint="Check the server's internet connection and try again.",
        ) from exc
    if status in (401, 403):
        raise InvalidApiKey(
            "The model provider rejected this key.",
            hint="Copy the whole key again from openrouter.ai/keys (it starts with sk-or-).",
        )
    if not 200 <= status < 300:
        raise ProviderUnavailable(
            f"The model provider answered {status} while checking this key.",
            hint="Try again in a minute.",
        )


def normalize(raw: str) -> str:
    key = (raw or "").strip()
    if not key:
        raise ValidationError("api_key is empty.", hint="Paste the key from openrouter.ai/keys.")
    if len(key) > MAX_KEY_LENGTH or any(ch.isspace() for ch in key):
        raise InvalidApiKey(
            "That doesn't look like an API key.",
            hint="Paste only the key itself, e.g. sk-or-v1-….",
        )
    return key


# --- Storage (caller has already authorized the owner) -------------------------------


def store(conn: sqlite3.Connection, key: str) -> None:
    conn.execute(
        "INSERT INTO instance_meta (key, value) VALUES (?, ?)"
        " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (META_KEY, sealed.seal(key, purpose=_PURPOSE)),
    )
    _set_cache_after_commit(conn, key)


def clear(conn: sqlite3.Connection) -> None:
    conn.execute("DELETE FROM instance_meta WHERE key = ?", (META_KEY,))
    _set_cache_after_commit(conn, None)


def _set_cache_after_commit(conn: sqlite3.Connection, value: str | None) -> None:
    db_path = get_settings().db_path

    def apply() -> None:
        with _cache_lock:
            _cache[db_path] = value

    # A rolled-back write must not leave the process using a key the database doesn't hold.
    after_commit(conn, apply)


def reset_cache() -> None:
    """Forget cached keys (tests; a restored database)."""
    with _cache_lock:
        _cache.clear()
