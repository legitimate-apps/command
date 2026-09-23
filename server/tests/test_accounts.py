from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as A
from command.core import settings as S
from command.errors import AuthFailed, Conflict, NotesImmutable, PermissionDenied, ValidationError
from command.mcp import permissions as P


def test_register_creates_account_token_and_settings(conn: sqlite3.Connection) -> None:
    acct = A.register(conn, "Jordan", "supersecret", "Jordan K")
    assert acct.username == "jordan"  # normalized
    assert acct.display_name == "Jordan K"
    token = A.get_access_token(conn, acct.id)
    assert token.startswith("cmd_")
    perms = S.mcp_permissions(conn, acct.id)
    assert perms["notes"]["delete"] is False
    assert perms["notes"]["update"] is False
    assert perms["notes"]["process"] is True  # the one allowed notes mutation, default on
    assert perms["delegatees"]["delete"] is True
    assert perms["activities"]["create"] is True and perms["activities"]["delete"] is True


def test_notes_permission_cannot_be_enabled(conn: sqlite3.Connection) -> None:
    acct = A.register(conn, "ada", "password1")
    # Even if a settings row tries to enable notes delete, the backstop forces it off.
    S.set_value(conn, acct.id, S.MCP_PERMISSIONS_KEY, {"notes": {"delete": True, "update": True}})
    perms = S.mcp_permissions(conn, acct.id)
    assert perms["notes"]["delete"] is False
    assert perms["notes"]["update"] is False


def test_notes_process_is_settings_controllable(conn: sqlite3.Connection) -> None:
    acct = A.register(conn, "rae", "password1")
    # Unlike update/delete, `process` is a real settings toggle (not force-disabled).
    S.set_value(conn, acct.id, S.MCP_PERMISSIONS_KEY, {"notes": {"process": False}})
    perms = S.mcp_permissions(conn, acct.id)
    assert perms["notes"]["process"] is False


def test_notes_process_gate(conn: sqlite3.Connection) -> None:
    acct = A.register(conn, "kit", "password1")
    P.require(conn, acct.id, "notes", "process")  # default on — no raise
    # Body-edit / delete stay hard-blocked by the immutability backstop.
    with pytest.raises(NotesImmutable):
        P.require(conn, acct.id, "notes", "update")
    # Disabling process in settings makes the gate deny it.
    S.set_value(conn, acct.id, S.MCP_PERMISSIONS_KEY, {"notes": {"process": False}})
    with pytest.raises(PermissionDenied):
        P.require(conn, acct.id, "notes", "process")


def test_read_permission_is_enforced(conn: sqlite3.Connection) -> None:
    """The matrix's per-entity `read` bool is real, not decorative (D1): the MCP read
    tools call permissions.require(..., 'read'), so disabling it denies reads."""
    acct = A.register(conn, "reader", "password1")
    P.require(conn, acct.id, "activities", "read")  # default on — no raise
    S.set_value(conn, acct.id, S.MCP_PERMISSIONS_KEY, {"activities": {"read": False}})
    with pytest.raises(PermissionDenied):
        P.require(conn, acct.id, "activities", "read")


def test_duplicate_username(conn: sqlite3.Connection) -> None:
    A.register(conn, "sam", "password1")
    with pytest.raises(Conflict):
        A.register(conn, "Sam", "password2")  # case-insensitive collision


def test_validation(conn: sqlite3.Connection) -> None:
    with pytest.raises(ValidationError):
        A.register(conn, "ab", "password1")  # username too short
    with pytest.raises(ValidationError):
        A.register(conn, "validname", "short")  # password too short


def test_login(conn: sqlite3.Connection) -> None:
    A.register(conn, "kelly", "password1")
    assert A.login(conn, "Kelly", "password1").username == "kelly"
    with pytest.raises(AuthFailed):
        A.login(conn, "kelly", "wrongpass")
    with pytest.raises(AuthFailed):
        A.login(conn, "ghost", "password1")


def test_sessions_roundtrip(conn: sqlite3.Connection) -> None:
    acct = A.register(conn, "robin", "password1")
    raw, _ = A.create_session(conn, acct.id, days=30)
    got = A.get_session_account(conn, raw)
    assert got is not None and got.id == acct.id
    A.destroy_session(conn, raw)
    assert A.get_session_account(conn, raw) is None


def test_expired_session(conn: sqlite3.Connection) -> None:
    acct = A.register(conn, "pat", "password1")
    raw, _ = A.create_session(conn, acct.id, days=-1)  # already expired
    assert A.get_session_account(conn, raw) is None


def test_access_token_regenerate_and_lookup(conn: sqlite3.Connection) -> None:
    acct = A.register(conn, "lee", "password1")
    t1 = A.get_access_token(conn, acct.id)
    found = A.account_for_access_token(conn, t1)
    assert found is not None and found.id == acct.id
    t2 = A.regenerate_access_token(conn, acct.id)
    assert t2 != t1
    assert A.account_for_access_token(conn, t1) is None  # old token revoked
    again = A.account_for_access_token(conn, t2)
    assert again is not None and again.id == acct.id


def test_token_is_per_account(conn: sqlite3.Connection) -> None:
    a = A.register(conn, "accta", "password1")
    b = A.register(conn, "acctb", "password1")
    ta = A.get_access_token(conn, a.id)
    tb = A.get_access_token(conn, b.id)
    assert ta != tb
    assert A.account_for_access_token(conn, ta).id == a.id  # type: ignore[union-attr]
    assert A.account_for_access_token(conn, tb).id == b.id  # type: ignore[union-attr]
