"""Push device-token registry + send-once ledger (B4)."""

from __future__ import annotations

import sqlite3

import pytest
from fastapi.testclient import TestClient

from command.core import accounts, push
from command.errors import ValidationError


def test_register_is_upsert_and_moves_token_between_accounts(conn: sqlite3.Connection) -> None:
    a = accounts.register(conn, "owner-a", "password1").id
    b = accounts.register(conn, "owner-b", "password1").id

    t = push.register(conn, a, "ABC123", environment="sandbox")
    assert t.account_id == a and t.environment == "sandbox"
    assert [x.token for x in push.list_tokens(conn, a)] == ["ABC123"]

    # Same device re-registers under account b (e.g. a re-login) → it moves, never duplicated.
    t2 = push.register(conn, b, "ABC123", environment="production")
    assert t2.account_id == b and t2.environment == "production"
    assert push.list_tokens(conn, a) == []
    assert len(push.list_tokens(conn, b)) == 1

    assert push.remove(conn, b, "ABC123") is True
    assert push.list_tokens(conn, b) == []


def test_register_validates(conn: sqlite3.Connection) -> None:
    a = accounts.register(conn, "owner-v", "password1").id
    with pytest.raises(ValidationError):
        push.register(conn, a, "   ")
    with pytest.raises(ValidationError):
        push.register(conn, a, "TOKEN", environment="staging")


def test_send_once_ledger(conn: sqlite3.Connection) -> None:
    a = accounts.register(conn, "owner-s", "password1").id
    assert push.already_sent(conn, a, 5, "2026-07-10") is False
    assert push.mark_sent(conn, a, 5, "2026-07-10", "2026-07-09T09:00:00+00:00") is True
    assert push.already_sent(conn, a, 5, "2026-07-10") is True
    # A second mark for the same occurrence is refused (no double push).
    assert push.mark_sent(conn, a, 5, "2026-07-10", "2026-07-09T09:00:00+00:00") is False
    # A different day for the same assignment is independent.
    assert push.mark_sent(conn, a, 5, "2026-07-11", "2026-07-10T09:00:00+00:00") is True


def test_push_rest_roundtrip(client: TestClient) -> None:
    reg = client.post("/api/auth/register", json={"username": "owner", "password": "password1"})
    assert reg.status_code == 200
    r = client.post("/api/push/register", json={"token": "DEADBEEF", "environment": "sandbox"})
    assert r.status_code == 200 and r.json()["token"] == "DEADBEEF"
    assert [t["token"] for t in client.get("/api/push/tokens").json()] == ["DEADBEEF"]
    assert client.post("/api/push/unregister", json={"token": "DEADBEEF"}).json() == {"removed": True}
    assert client.get("/api/push/tokens").json() == []


def test_push_requires_auth(client: TestClient) -> None:
    assert client.get("/api/push/tokens").status_code == 401


def test_a_delegatee_can_only_unregister_its_own_devices(conn: sqlite3.Connection) -> None:
    """Registration stamps `delegatee_id`; unregistration has to check it.

    Without the filter the delegatee push surface deletes by (account, token) alone, so any
    delegatee holding another device's token could unregister the OPERATOR's phone and
    silently end their reminders and briefings. The token is not a secret — it is handed to
    the server by every device that registers, and shared-device or re-login flows move it
    between roles.
    """
    from command.core import delegatees as delegatees_core

    aid = accounts.register(conn, "owner-scope", "password1").id
    dee, _ = delegatees_core.upsert(conn, aid, name="Contractor")
    other, _ = delegatees_core.upsert(conn, aid, name="Someone Else")

    push.register(conn, aid, "OPERATOR-TOKEN", environment="sandbox")
    push.register(conn, aid, "DELEGATEE-TOKEN", environment="sandbox", delegatee_id=dee.id)

    # The delegatee surface cannot touch the operator's device...
    assert push.remove(conn, aid, "OPERATOR-TOKEN", only_delegatee_id=dee.id) is False
    # ...nor a different delegatee's.
    assert push.remove(conn, aid, "DELEGATEE-TOKEN", only_delegatee_id=other.id) is False
    assert {t.token for t in push.list_tokens(conn, aid)} == {"OPERATOR-TOKEN", "DELEGATEE-TOKEN"}

    # It can remove its own, and the operator (unscoped) can remove anything in the account.
    assert push.remove(conn, aid, "DELEGATEE-TOKEN", only_delegatee_id=dee.id) is True
    assert push.remove(conn, aid, "OPERATOR-TOKEN") is True
    assert push.list_tokens(conn, aid) == []
