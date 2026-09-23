from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import credits


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_balance_starts_zero(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    assert credits.balance(conn, aid) == 0


def test_grant_and_debit(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    assert credits.grant(conn, aid, 1000, reason="purchase", ref="txn-1") is True
    assert credits.balance(conn, aid) == 1000
    assert credits.debit(conn, aid, 250, reason="usage") is True
    assert credits.balance(conn, aid) == 750


def test_grant_is_idempotent_on_ref(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    assert credits.grant(conn, aid, 500, ref="evt-abc") is True
    # A redelivered webhook with the same event id must not double-grant.
    assert credits.grant(conn, aid, 500, ref="evt-abc") is False
    assert credits.balance(conn, aid) == 500


def test_null_ref_grants_are_independent(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    assert credits.grant(conn, aid, 100, ref=None) is True
    assert credits.grant(conn, aid, 100, ref=None) is True  # no ref → not deduped
    assert credits.balance(conn, aid) == 200


def test_positive_amount_required(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValueError, match="positive"):
        credits.grant(conn, aid, 0)
    with pytest.raises(ValueError, match="positive"):
        credits.debit(conn, aid, -5)


def test_transactions_newest_first(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    credits.grant(conn, aid, 100, ref="a")
    credits.debit(conn, aid, 30, ref="b")
    txns = credits.transactions(conn, aid)
    assert [t.ref for t in txns] == ["b", "a"]
    assert txns[0].delta == -30
    assert txns[1].delta == 100


def test_balance_scoped_per_account(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "owner_a")
    b = _acct(conn, "owner_b")
    credits.grant(conn, a, 100, ref="a1")
    assert credits.balance(conn, a) == 100
    assert credits.balance(conn, b) == 0


def test_a_failed_grant_raises_instead_of_looking_like_a_redelivery(conn: sqlite3.Connection) -> None:
    """`_append` used to swallow every IntegrityError as "already applied".

    The table raises IntegrityError three other ways — the account_id foreign key, and NOT NULL
    on delta/reason. Reporting those as a redelivery means a customer's purchase returns the
    "already applied, nothing to do" answer while no money is ever credited, and nothing
    anywhere logs an error. Measured before the fix: grant() to a nonexistent account returned
    False and the balance stayed 0.
    """
    with pytest.raises(sqlite3.IntegrityError):
        credits.grant(conn, 999_999, 500, ref="txn-missing-account")


def test_a_genuine_redelivery_is_still_a_silent_no_op(conn: sqlite3.Connection) -> None:
    """The idempotency this guard protects must survive it — webhooks retry."""
    aid = accounts_core.register(conn, "credits-redeliver", "password1").id
    assert credits.grant(conn, aid, 500, ref="txn-dup") is True
    assert credits.grant(conn, aid, 500, ref="txn-dup") is False, "second delivery is a no-op"
    assert credits.balance(conn, aid) == 500, "a retried webhook must never double-grant"


def test_the_ref_collision_check_is_not_scoped_by_account(conn: sqlite3.Connection) -> None:
    """The unique index is on `ref` alone, so a cross-account collision is a real duplicate and
    must be reported as one rather than raising."""
    a = accounts_core.register(conn, "credits-acct-a", "password1").id
    b = accounts_core.register(conn, "credits-acct-b", "password1").id
    assert credits.grant(conn, a, 100, ref="shared-ref") is True
    assert credits.grant(conn, b, 100, ref="shared-ref") is False
    assert credits.balance(conn, b) == 0
