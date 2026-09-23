"""Accounts, app sessions, and the memorable MCP access token.

Session auth in Python/SQLite: bcrypt password
hashes; app-session tokens stored ONLY as sha256 (the raw token lives on the
device); plus the regenerable memorable access token (`core.tokens`) that scopes
a Claude Code instance to one account over MCP.

Plain synchronous functions taking a connection — the REST layer calls them in a
worker thread, the MCP layer offloads them to one.
"""

from __future__ import annotations

import functools
import hashlib
import re
import secrets
import sqlite3
from collections.abc import Callable
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import bcrypt
from pydantic import BaseModel

from ..db import now_iso
from ..errors import AuthFailed, Conflict, InvalidTimezone, NotFound, ValidationError
from . import clock, tokens
from . import delegatees as delegatees_core
from . import settings as settings_core

MIN_USERNAME_LEN = 3
MAX_USERNAME_LEN = 64
MIN_PASSWORD_LEN = 8
MAX_PASSWORD_LEN = 128
BCRYPT_ROUNDS = 12
BCRYPT_MAX_BYTES = 72
_USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$")


class Account(BaseModel):
    id: int
    username: str
    display_name: str | None
    timezone: str | None
    created_at: str
    updated_at: str


def _row_to_account(row: sqlite3.Row) -> Account:
    return Account(
        id=row["id"],
        username=row["username"],
        display_name=row["display_name"],
        timezone=row["timezone"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


# ---------- credentials ----------


def normalize_username(username: str) -> str:
    return username.strip().lower()


def validate_credentials(username: str, password: str) -> None:
    u = normalize_username(username)
    if not (MIN_USERNAME_LEN <= len(u) <= MAX_USERNAME_LEN) or not _USERNAME_RE.match(u):
        raise ValidationError(
            "Username must be 3-64 chars: lowercase letters, digits, dot, dash, underscore.",
            hint="e.g. 'casey', 'team_lead', 'jordan.k'",
        )
    if not (MIN_PASSWORD_LEN <= len(password) <= MAX_PASSWORD_LEN):
        raise ValidationError(f"Password must be {MIN_PASSWORD_LEN}-{MAX_PASSWORD_LEN} characters.")
    validate_password_bytes(password)


def validate_password_bytes(password: str) -> None:
    """bcrypt only uses the first 72 BYTES, and bcrypt 5 raises ValueError past that — which
    reached the client as a 500 on register and account deletion. Characters are not bytes:
    128 characters can be 500+ bytes of UTF-8, so the character limit alone doesn't cover it."""
    if len(password.encode("utf-8")) > BCRYPT_MAX_BYTES:
        raise ValidationError(
            f"Password is too long: at most {BCRYPT_MAX_BYTES} bytes "
            "(fewer characters if it uses accents, emoji or non-Latin letters).",
        )


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt(rounds=BCRYPT_ROUNDS)).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    raw = password.encode("utf-8")
    if len(raw) > BCRYPT_MAX_BYTES:
        return False   # can never match a hash we issued, and bcrypt 5 would raise
    try:
        return bcrypt.checkpw(raw, hashed.encode("utf-8"))
    except ValueError:
        return False


@functools.cache
def _dummy_hash() -> str:
    """A real bcrypt hash at the production cost, computed once on first use (not at import,
    so startup stays cheap). Checked against when the username doesn't exist."""
    return hash_password(secrets.token_urlsafe(16))


def _hash_session_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


# ---------- accounts ----------


def register(
    conn: sqlite3.Connection,
    username: str,
    password: str,
    display_name: str | None = None,
    *,
    token_words: int = 4,
) -> Account:
    validate_credentials(username, password)
    u = normalize_username(username)
    if conn.execute("SELECT 1 FROM accounts WHERE username = ?", (u,)).fetchone():
        raise Conflict("That username is already taken.", hint="pick another username or log in instead")
    ts = now_iso()
    cur = conn.execute(
        "INSERT INTO accounts (username, display_name, password_hash, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (u, (display_name or None), hash_password(password), ts, ts),
    )
    account_id = int(cur.lastrowid or 0)
    settings_core.seed_defaults(conn, account_id)
    delegatees_core.ensure_self(conn, account_id)  # the "Me" actor for activity + self-scheduling
    ensure_access_token(conn, account_id, words=token_words)
    return get_account(conn, account_id)


def get_account(conn: sqlite3.Connection, account_id: int) -> Account:
    row = conn.execute("SELECT * FROM accounts WHERE id = ?", (account_id,)).fetchone()
    if row is None:
        raise NotFound(f"No account with id {account_id}.")
    return _row_to_account(row)


def get_account_by_username(conn: sqlite3.Connection, username: str) -> Account | None:
    row = conn.execute(
        "SELECT * FROM accounts WHERE username = ?", (normalize_username(username),)
    ).fetchone()
    return _row_to_account(row) if row else None


def get_timezone(conn: sqlite3.Connection, account_id: int) -> str:
    """The account's IANA zone, or ``"UTC"`` when unset/unknown.

    Exists because "which day is it for this user" now decides real behaviour — briefing
    windows, weekend detection in free-time search — and callers were each writing their own
    `SELECT timezone` and their own fallback. One of those, and one fallback.
    """
    row = conn.execute(
        "SELECT timezone FROM accounts WHERE id = ?", (account_id,)
    ).fetchone()
    value = row["timezone"] if row is not None else None
    return str(value) if value else "UTC"


def set_timezone(conn: sqlite3.Connection, account_id: int, timezone: str) -> Account:
    """Validate and persist an IANA timezone. Repeating the same value is an idempotent no-op."""
    try:
        ZoneInfo(timezone)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise InvalidTimezone(
            f"Unknown timezone: {timezone!r}.", hint="Use an IANA name, e.g. 'America/New_York'."
        ) from exc
    conn.execute(
        "UPDATE accounts SET timezone = ?, updated_at = ? WHERE id = ?",
        (timezone, now_iso(), account_id),
    )
    return get_account(conn, account_id)


def login(conn: sqlite3.Connection, username: str, password: str) -> Account:
    row = conn.execute(
        "SELECT * FROM accounts WHERE username = ?", (normalize_username(username),)
    ).fetchone()
    if row is None:
        # Spend the same bcrypt work as a real check. Returning straight away made an unknown
        # username answer in ~1 ms and a known one in ~250 ms — a free username oracle.
        verify_password(password, _dummy_hash())
        raise AuthFailed("Incorrect username or password.")
    if not verify_password(password, row["password_hash"]):
        raise AuthFailed("Incorrect username or password.")
    return _row_to_account(row)


# ---------- app sessions ----------


class SessionPolicy(BaseModel):
    """How long a session lives — a *sliding* idle window, not a fixed one.

    The original design stamped `expires_at` once at login and never moved it, so an
    account in daily use was signed out exactly `idle_days` after logging in, forever,
    on every device independently. That reads to a user as "it logs me out at random".

    Now `idle_days` is time-since-last-use: every request slides the expiry forward (and
    re-issues the cookie, or the client would still drop it at its own `max-age`).
    `absolute_days` is the backstop — the longest a single login may live no matter how
    actively it's used, so a leaked cookie is not immortal. 0 disables it.

    `renew_after_seconds` throttles the slide: renewing on literally every request would
    mean an extra write + `Set-Cookie` per call for no benefit. Renewing once a day keeps
    the window within a day of exact while costing ~1 write/day/device.
    """

    idle_days: int = 30
    absolute_days: int = 365
    renew_after_seconds: int = 86_400


DEFAULT_SESSION_POLICY = SessionPolicy()


def create_session(conn: sqlite3.Connection, account_id: int, *, days: int = 30) -> tuple[str, str]:
    """Return (raw_token, expires_at_iso). Only sha256(token) is stored."""
    purge_expired_sessions(conn)  # a login is the natural, always-committing GC point
    raw = secrets.token_urlsafe(32)
    ts = now_iso()
    expires_at = (clock.now() + timedelta(days=days)).isoformat()
    conn.execute(
        "INSERT INTO sessions (token_hash, account_id, created_at, expires_at, last_seen_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (_hash_session_token(raw), account_id, ts, expires_at, ts),
    )
    return raw, expires_at


def session_is_past_absolute_cap(created_at: str, policy: SessionPolicy) -> bool:
    """True when this login is older than the absolute cap (0 ⇒ no cap)."""
    if policy.absolute_days <= 0:
        return False
    return clock.now() >= datetime.fromisoformat(created_at) + timedelta(days=policy.absolute_days)


def touch_session(
    conn: sqlite3.Connection,
    token_hash: str,
    *,
    created_at: str,
    expires_at: str,
    policy: SessionPolicy,
) -> str | None:
    """Mark the session used, sliding its expiry when the throttle allows.

    Returns the new `expires_at` when it moved (the caller must re-issue the cookie so the
    client's copy slides too), else None. Never slides past the absolute cap, so the cap is
    a real ceiling rather than something the cookie can outrun.
    """
    now = clock.now()
    ts = now.isoformat()
    target = now + timedelta(days=policy.idle_days)
    if policy.absolute_days > 0:
        ceiling = datetime.fromisoformat(created_at) + timedelta(days=policy.absolute_days)
        target = min(target, ceiling)

    # `expires_at` is always (last renewal + idle_days), so it doubles as the renewal
    # clock: no extra column needed to know when we last slid this session.
    current = datetime.fromisoformat(expires_at)
    last_renewed = current - timedelta(days=policy.idle_days)
    due = now - last_renewed >= timedelta(seconds=policy.renew_after_seconds)
    if not due or target <= current:
        conn.execute("UPDATE sessions SET last_seen_at = ? WHERE token_hash = ?", (ts, token_hash))
        return None

    new_expires = target.isoformat()
    conn.execute(
        "UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE token_hash = ?",
        (ts, new_expires, token_hash),
    )
    return new_expires


def get_session_account(
    conn: sqlite3.Connection,
    token: str,
    *,
    policy: SessionPolicy = DEFAULT_SESSION_POLICY,
    on_renew: Callable[[str], None] | None = None,
) -> Account | None:
    """Resolve an operator session, sliding its expiry (see `SessionPolicy`).

    `on_renew` is called with the new `expires_at` when the expiry moved — the REST layer
    uses it to re-issue the session cookie.
    """
    if not token:
        return None
    th = _hash_session_token(token)
    row = conn.execute(
        "SELECT s.expires_at AS expires_at, s.created_at AS session_created_at, a.* FROM sessions s "
        "JOIN accounts a ON a.id = s.account_id WHERE s.token_hash = ? AND s.delegatee_id IS NULL",
        (th,),
    ).fetchone()
    if row is None:
        return None
    if datetime.fromisoformat(row["expires_at"]) <= clock.now() or session_is_past_absolute_cap(
        row["session_created_at"], policy
    ):
        # Best-effort cleanup: the REST layer rolls this back on its way to the 401, so the
        # rows actually go at the next login / server start (`purge_expired_sessions`).
        conn.execute("DELETE FROM sessions WHERE token_hash = ?", (th,))
        return None
    renewed = touch_session(
        conn,
        th,
        created_at=row["session_created_at"],
        expires_at=row["expires_at"],
        policy=policy,
    )
    if renewed is not None and on_renew is not None:
        on_renew(renewed)
    return _row_to_account(row)


def purge_expired_sessions(conn: sqlite3.Connection) -> int:
    """Delete sessions that are already past their expiry. Returns the row count.

    Expiry is enforced on read, so this is hygiene rather than security: without it the
    table only ever shrinks when an expired token happens to be presented again, which for
    a re-installed device is never.
    """
    cur = conn.execute("DELETE FROM sessions WHERE expires_at <= ?", (clock.now().isoformat(),))
    return cur.rowcount or 0


def destroy_session(conn: sqlite3.Connection, token: str) -> None:
    conn.execute("DELETE FROM sessions WHERE token_hash = ?", (_hash_session_token(token),))


# ---------- memorable MCP access token ----------


def any_account_exists(conn: sqlite3.Connection) -> bool:
    """Whether this instance has been claimed yet.

    Drives first-user-only signup: a Command server is one person's planner and is normally
    reachable from the internet (the phone has to get to it), so leaving registration open lets
    anyone who finds the URL spend the owner's model budget. `LIMIT 1` rather than a count —
    the question is existence.
    """
    return conn.execute("SELECT 1 FROM accounts LIMIT 1").fetchone() is not None


def _active_token_row(conn: sqlite3.Connection, account_id: int) -> sqlite3.Row | None:
    row: sqlite3.Row | None = conn.execute(
        "SELECT * FROM access_tokens WHERE account_id = ? AND label = 'default' AND revoked_at IS NULL "
        "ORDER BY id DESC LIMIT 1",
        (account_id,),
    ).fetchone()
    return row


def _new_unique_token(conn: sqlite3.Connection, words: int) -> str:
    # Collisions are astronomically unlikely (~55 bits) but loop to be certain.
    for _ in range(8):
        candidate = tokens.generate(words)
        if conn.execute("SELECT 1 FROM access_tokens WHERE token = ?", (candidate,)).fetchone() is None:
            return candidate
    raise RuntimeError("could not generate a unique access token")  # pragma: no cover


def ensure_access_token(
    conn: sqlite3.Connection, account_id: int, *, words: int = tokens.DEFAULT_WORDS
) -> str:
    row = _active_token_row(conn, account_id)
    if row is not None:
        return str(row["token"])
    token = _new_unique_token(conn, words)
    conn.execute(
        "INSERT INTO access_tokens (account_id, token, label, created_at) VALUES (?, ?, 'default', ?)",
        (account_id, token, now_iso()),
    )
    return token


def get_access_token(
    conn: sqlite3.Connection, account_id: int, *, words: int = tokens.DEFAULT_WORDS
) -> str:
    return ensure_access_token(conn, account_id, words=words)


def regenerate_access_token(
    conn: sqlite3.Connection, account_id: int, *, words: int = tokens.DEFAULT_WORDS
) -> str:
    conn.execute(
        "UPDATE access_tokens SET revoked_at = ? "
        "WHERE account_id = ? AND label = 'default' AND revoked_at IS NULL",
        (now_iso(), account_id),
    )
    token = _new_unique_token(conn, words)
    conn.execute(
        "INSERT INTO access_tokens (account_id, token, label, created_at) VALUES (?, ?, 'default', ?)",
        (account_id, token, now_iso()),
    )
    return token


#: Account-scoped tables whose FK to `accounts` was declared WITHOUT `ON DELETE CASCADE`.
#: `PRAGMA foreign_keys=ON` is set (db.py), so SQLite's default NO ACTION would make
#: `DELETE FROM accounts` fail with a constraint error the moment any of these has a row.
#: They must be cleared explicitly. Everything else cascades on its own.
#: If you add a table referencing accounts(id), give it ON DELETE CASCADE or add it here —
#: `test_delete_account_leaves_nothing_behind` sweeps every table and will fail otherwise.
_NON_CASCADING = ("credit_ledger", "task_items", "device_tokens", "sent_reminders")


def delete_account(conn: sqlite3.Connection, account_id: int, *, password: str) -> None:
    """Permanently delete an account and everything attached to it.

    Apple requires any app offering account creation to offer in-app deletion
    (App Review 5.1.1(v)), and our privacy policy promises it — so this is the real thing,
    not a soft flag: the rows go.

    Re-authentication is required. A stolen session should not be able to destroy someone's
    data, so the caller must supply the account's password even though it already holds a
    valid session.
    """
    row = conn.execute("SELECT * FROM accounts WHERE id = ?", (account_id,)).fetchone()
    if row is None:
        raise NotFound("No such account.")
    validate_password_bytes(password)   # a clear 422, not bcrypt's ValueError as a 500
    if not verify_password(password, row["password_hash"]):
        raise AuthFailed("Password is incorrect.")

    with conn:   # one transaction: either the account is fully gone or nothing changed
        for table in _NON_CASCADING:
            conn.execute(f"DELETE FROM {table} WHERE account_id = ?", (account_id,))
        conn.execute("DELETE FROM accounts WHERE id = ?", (account_id,))
    # Attachment rows cascaded with the account; the BYTES live on disk. Clean the directory
    # after the transaction committed — a rolled-back delete must not have destroyed files.
    from . import attachments as attachments_core

    attachments_core.delete_for_account(account_id)


def account_for_access_token(conn: sqlite3.Connection, token: str) -> Account | None:
    """Resolve a bearer access token to its account (active tokens only)."""
    if not token or not tokens.is_well_formed(token):
        return None
    row = conn.execute(
        "SELECT a.* FROM access_tokens t JOIN accounts a ON a.id = t.account_id "
        "WHERE t.token = ? AND t.revoked_at IS NULL",
        (token,),
    ).fetchone()
    if row is None:
        return None
    conn.execute("UPDATE access_tokens SET last_used_at = ? WHERE token = ?", (now_iso(), token))
    return _row_to_account(row)
