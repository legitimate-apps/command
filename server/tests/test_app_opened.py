"""Open detection — the signal that refunds the proactive-LLM budget.

The guard is only fair if engagement actually resets it. "Opened the app or the site" has
to be observable server-side, so two things count: the explicit foreground ping, and the
session bootstrap (`/api/auth/me`), which is the first call every launch makes.

Deliberately NOT an open: push registration, or any background/system call. If those reset
the counter, a dormant device refreshes its own budget forever and the guard never trips —
which is the exact failure the guard exists to prevent.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from command.core import llm_budget


def _spend(client: TestClient, db_path: str, n: int) -> None:
    from command.db import connect

    conn = connect(db_path)
    try:
        account_id = conn.execute("SELECT id FROM accounts LIMIT 1").fetchone()[0]
        for _ in range(n):
            llm_budget.record_send(conn, account_id)
        conn.commit()
    finally:
        conn.close()


def _count(db_path: str) -> int:
    from command.db import connect

    conn = connect(db_path)
    try:
        account_id = conn.execute("SELECT id FROM accounts LIMIT 1").fetchone()[0]
        return llm_budget.sends_since_open(conn, account_id)
    finally:
        conn.close()


def _register(client: TestClient) -> None:
    r = client.post("/api/auth/register", json={"username": "sam", "password": "supersecret"})
    assert r.status_code == 200, r.text


def test_explicit_open_ping_resets_the_budget(client: TestClient, tmp_path) -> None:
    db_path = str(tmp_path / "app.db")
    _register(client)
    _spend(client, db_path, 30)
    assert _count(db_path) == 30

    r = client.post("/api/app/opened")
    assert r.status_code == 200, r.text
    assert r.json()["ok"] is True
    assert _count(db_path) == 0


def test_session_bootstrap_counts_as_an_open(client: TestClient, tmp_path) -> None:
    """`/api/auth/me` is the first call of every launch — that IS the app opening."""
    db_path = str(tmp_path / "app.db")
    _register(client)
    _spend(client, db_path, 12)

    assert client.get("/api/auth/me").status_code == 200
    assert _count(db_path) == 0


def test_open_ping_requires_authentication(client: TestClient) -> None:
    assert client.post("/api/app/opened").status_code == 401


def test_push_registration_is_not_an_open(client: TestClient, tmp_path) -> None:
    """A background device-token refresh must not refund the budget, or a dormant device
    keeps its own briefings alive forever."""
    db_path = str(tmp_path / "app.db")
    _register(client)
    _spend(client, db_path, 30)

    r = client.post(
        "/api/push/register",
        json={"token": "a" * 64, "environment": "sandbox"},
    )
    assert r.status_code == 200, r.text
    assert _count(db_path) == 30, "push registration must not count as engagement"
