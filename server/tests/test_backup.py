"""GET /api/admin/backup — the operator's consistent tar.gz snapshot."""

from __future__ import annotations

import io
import sqlite3
import tarfile
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from command.config import get_settings
from command.core import backup as backup_core
from command.rest import admin

TOKEN = "backup-token-for-tests-0123456789"
PASSWORD = "correct-horse-battery"


def _server(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, **env: str) -> TestClient:
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "data" / "command.db"))
    monkeypatch.setenv("COMMAND_COOKIE_SECURE", "false")
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.delenv("COMMAND_BACKUP_TOKEN", raising=False)
    for k, v in env.items():
        monkeypatch.setenv(f"COMMAND_{k.upper()}", v)
    get_settings.cache_clear()
    admin._backup_failures.clear()
    from command.app import create_app

    return TestClient(create_app())


@pytest.fixture
def server(tmp_path, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    with _server(tmp_path, monkeypatch, backup_token=TOKEN) as c:
        yield c
    get_settings.cache_clear()


def _auth(token: str = TOKEN) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_absent_without_a_configured_token(tmp_path, monkeypatch) -> None:
    with _server(tmp_path, monkeypatch) as c:
        assert c.get("/api/admin/backup", headers=_auth()).status_code == 404
        assert c.get("/api/admin/backup").status_code == 404
    get_settings.cache_clear()


def test_wrong_or_missing_token_is_refused(server: TestClient) -> None:
    assert server.get("/api/admin/backup").status_code == 401
    assert server.get("/api/admin/backup", headers=_auth("nope")).status_code == 401
    # A session cookie / account bearer is not the backup token.
    r = server.post("/api/auth/register", json={"username": "owner", "password": PASSWORD})
    session = r.cookies.get("command_session")
    server.cookies.clear()
    assert server.get("/api/admin/backup", headers=_auth(session)).status_code == 401


def test_repeated_bad_tokens_are_rate_limited(server: TestClient) -> None:
    for _ in range(10):
        assert server.get("/api/admin/backup", headers=_auth("guess")).status_code == 401
    # Now locked out — even the right token waits for the window to pass.
    assert server.get("/api/admin/backup", headers=_auth()).status_code == 429


def test_backup_is_a_consistent_tarball_of_database_and_attachments(server: TestClient) -> None:
    r = server.post("/api/auth/register", json={"username": "owner", "password": PASSWORD})
    auth = {"Authorization": f"Bearer {r.cookies.get('command_session')}"}
    server.cookies.clear()
    note = server.post("/api/notes", json={"body": "back me up"}, headers=auth).json()
    payload = b"attachment bytes " * 10_000  # spans several chunks
    att = server.post(
        "/api/attachments",
        data={"entity_kind": "note", "entity_id": str(note["id"])},
        files={"file": ("a.bin", payload, "application/octet-stream")},
        headers=auth,
    ).json()

    r = server.get("/api/admin/backup", headers=_auth())
    assert r.status_code == 200
    assert r.headers["content-type"] == "application/gzip"
    assert r.headers["cache-control"] == "no-store"
    assert ".tar.gz" in r.headers["content-disposition"]

    with tarfile.open(fileobj=io.BytesIO(r.content), mode="r:gz") as tar:
        names = tar.getnames()
        prefix = names[0].split("/")[0]
        assert prefix.startswith("command-backup-")
        db_member = tar.extractfile(f"{prefix}/command.db")
        assert db_member is not None
        db_bytes = db_member.read()
        attachment_members = [n for n in names if "/attachments/" in n]
        assert len(attachment_members) == 1
        stored = tar.extractfile(attachment_members[0])
        assert stored is not None and stored.read() == payload

    # The snapshot is a real, self-contained database with the live data in it.
    snap = Path(get_settings().db_path).parent / "restored.db"
    snap.write_bytes(db_bytes)
    conn = sqlite3.connect(snap)
    try:
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
        assert conn.execute("SELECT body FROM notes").fetchone()[0] == "back me up"
        assert conn.execute("SELECT id FROM attachments").fetchone()[0] == att["id"]
    finally:
        conn.close()

    # Nothing left behind, and the one-at-a-time lock is free again.
    data_dir = Path(get_settings().db_path).parent
    assert not [p for p in data_dir.iterdir() if p.name.startswith(".backup-")]
    assert server.get("/api/admin/backup", headers=_auth()).status_code == 200


def test_concurrent_backup_is_refused(server: TestClient) -> None:
    assert admin._backup_running.acquire(blocking=False)
    try:
        r = server.get("/api/admin/backup", headers=_auth())
        assert r.status_code == 429
    finally:
        admin._backup_running.release()


def test_archive_stream_handles_missing_attachments_dir_and_skips_temp_files(tmp_path) -> None:
    db = tmp_path / "x.db"
    sqlite3.connect(db).close()
    snapshot = backup_core.snapshot_database(str(db))
    try:
        # No attachments directory at all.
        blob = b"".join(backup_core.archive_chunks(snapshot, tmp_path / "missing", "p"))
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            assert tar.getnames() == ["p/command.db"]
        # An in-progress upload (`.<uuid>.tmp`) is not part of the store.
        acct = tmp_path / "att" / "1"
        acct.mkdir(parents=True)
        (acct / ".abc.tmp").write_bytes(b"partial")
        (acct / "abc").write_bytes(b"whole")
        blob = b"".join(backup_core.archive_chunks(snapshot, tmp_path / "att", "p"))
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            assert tar.getnames() == ["p/command.db", "p/attachments/1/abc"]
            member = tar.extractfile("p/attachments/1/abc")
            assert member is not None and member.read() == b"whole"
    finally:
        backup_core.cleanup(snapshot)
    assert not snapshot.parent.exists()


@pytest.mark.anyio
async def test_a_response_dropped_before_streaming_still_cleans_up(server: TestClient) -> None:
    """A client that disconnects before the first chunk leaves the body generator un-started,
    so its `finally` never runs; the finalizer must still free the lock and the snapshot."""
    import gc

    from starlette.requests import Request

    scope = {
        "type": "http", "method": "GET", "path": "/api/admin/backup", "query_string": b"",
        "headers": [(b"authorization", f"Bearer {TOKEN}".encode())], "client": ("10.0.0.5", 1),
    }
    response = await admin.backup(Request(scope))
    data_dir = Path(get_settings().db_path).parent
    assert [p for p in data_dir.iterdir() if p.name.startswith(".backup-")]
    assert admin._backup_running.locked()
    del response
    gc.collect()
    assert not admin._backup_running.locked()
    assert not [p for p in data_dir.iterdir() if p.name.startswith(".backup-")]
