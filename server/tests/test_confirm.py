from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import confirm
from command.errors import ConfirmRequired


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_issue_then_consume_ok(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    payload = {"slug": "x"}
    token, ttl = confirm.issue(conn, aid, "delegatees_remove", payload)
    assert ttl > 0
    confirm.consume(conn, aid, "delegatees_remove", token, payload)  # no raise


def test_missing_token_raises(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ConfirmRequired):
        confirm.consume(conn, aid, "t", None, {})


def test_single_use(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    payload = {"a": 1}
    token, _ = confirm.issue(conn, aid, "t", payload)
    confirm.consume(conn, aid, "t", token, payload)
    with pytest.raises(ConfirmRequired):
        confirm.consume(conn, aid, "t", token, payload)  # reuse rejected


def test_payload_binding(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    token, _ = confirm.issue(conn, aid, "t", {"slug": "a"})
    with pytest.raises(ConfirmRequired):
        confirm.consume(conn, aid, "t", token, {"slug": "b"})  # target changed


def test_tool_binding(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    token, _ = confirm.issue(conn, aid, "toolA", {"x": 1})
    with pytest.raises(ConfirmRequired):
        confirm.consume(conn, aid, "toolB", token, {"x": 1})


def test_account_binding(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "aaa")
    b = _acct(conn, "bbb")
    token, _ = confirm.issue(conn, a, "t", {"x": 1})
    with pytest.raises(ConfirmRequired):
        confirm.consume(conn, b, "t", token, {"x": 1})  # different account


def test_expired(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    token, _ = confirm.issue(conn, aid, "t", {"x": 1}, ttl_seconds=-1)  # already past
    with pytest.raises(ConfirmRequired):
        confirm.consume(conn, aid, "t", token, {"x": 1})
