"""Attachments: upload/list/download/delete, caps, ownership, delegatee scoping, cleanup."""

from __future__ import annotations

import hashlib
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import attachments as ATT
from command.core import notes as N
from command.errors import NotFound, ValidationError


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


@pytest.fixture(autouse=True)
def _isolated_storage(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Point storage at tmp for the CORE tests (the `conn` fixture doesn't touch settings,
    and storage_root() derives from db_path — without this, core saves would write into the
    repo's ./data). The `client` fixture re-sets COMMAND_DB_PATH after this runs, so REST
    tests keep their own isolated path."""
    from command.config import get_settings

    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "core.db"))
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


# ---------- core ----------

def test_save_list_download_delete_roundtrip(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    note = N.create(conn, aid, body="attach here")
    data = b"PDF-ish bytes \x00\x01"
    att = ATT.save(conn, aid, "note", note.id, filename="doc.pdf", mime="application/pdf", data=data)
    assert att.size_bytes == len(data)
    assert att.sha256 == hashlib.sha256(data).hexdigest()

    listed = ATT.list_for(conn, aid, "note", note.id)
    assert [a.id for a in listed] == [att.id]

    path = ATT.file_path(conn, aid, att.id)
    assert path.read_bytes() == data
    # opaque stored name — never the user-supplied filename
    assert path.name != "doc.pdf"

    ATT.delete(conn, aid, att.id)
    assert ATT.list_for(conn, aid, "note", note.id) == []
    conn.commit()   # bytes are removed once the row's deletion is durable
    assert not path.exists()


def test_ownership_and_entity_validation(conn: sqlite3.Connection) -> None:
    owner = _acct(conn, "owner")
    other = _acct(conn, "other")
    note = N.create(conn, owner, body="mine")
    with pytest.raises(NotFound):
        ATT.save(conn, other, "note", note.id, filename="x", mime="text/plain", data=b"x")
    with pytest.raises(ValidationError):
        ATT.save(conn, owner, "goal", note.id, filename="x", mime="text/plain", data=b"x")
    att = ATT.save(conn, owner, "note", note.id, filename="x", mime="text/plain", data=b"x")
    with pytest.raises(NotFound):
        ATT.get(conn, other, att.id)
    with pytest.raises(NotFound):
        ATT.delete(conn, other, att.id)


def test_size_and_count_caps(conn: sqlite3.Connection, monkeypatch: pytest.MonkeyPatch) -> None:
    from command.config import get_settings

    monkeypatch.setenv("COMMAND_MAX_ATTACHMENT_BYTES", "10")
    monkeypatch.setenv("COMMAND_MAX_ATTACHMENTS_PER_ENTITY", "2")
    get_settings.cache_clear()
    try:
        aid = _acct(conn)
        note = N.create(conn, aid, body="capped")
        with pytest.raises(ValidationError, match="too large"):
            ATT.save(conn, aid, "note", note.id, filename="big", mime="x", data=b"0123456789A")
        with pytest.raises(ValidationError, match="empty"):
            ATT.save(conn, aid, "note", note.id, filename="none", mime="x", data=b"")
        ATT.save(conn, aid, "note", note.id, filename="1", mime="x", data=b"a")
        ATT.save(conn, aid, "note", note.id, filename="2", mime="x", data=b"b")
        with pytest.raises(ValidationError, match="already has 2"):
            ATT.save(conn, aid, "note", note.id, filename="3", mime="x", data=b"c")
    finally:
        get_settings.cache_clear()


def test_assignment_delete_removes_files(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = A.create(conn, aid, title="with file", scheduled_start="2026-08-01T09:00:00+00:00")
    att = ATT.save(conn, aid, "assignment", a.id, filename="f", mime="x", data=b"bytes")
    path = ATT.file_path(conn, aid, att.id)
    A.delete(conn, aid, a.id)
    assert path.exists(), "bytes removed before the delete committed"
    conn.commit()
    assert not path.exists()
    assert conn.execute("SELECT COUNT(*) AS n FROM attachments").fetchone()["n"] == 0


def test_a_rolled_back_delete_keeps_the_file(conn: sqlite3.Connection) -> None:
    """The row and the bytes live in two stores; a delete that rolls back must restore BOTH.
    Unlinking inline left a row that listed fine and 404'd on download."""
    aid = _acct(conn)
    a = A.create(conn, aid, title="with file", scheduled_start="2026-08-01T09:00:00+00:00")
    att = ATT.save(conn, aid, "assignment", a.id, filename="f", mime="x", data=b"bytes")
    conn.commit()
    path = ATT.file_path(conn, aid, att.id)
    A.delete(conn, aid, a.id)
    conn.rollback()
    assert path.exists()
    assert ATT.file_path(conn, aid, att.id) == path   # row back, file still downloadable
    ATT.delete(conn, aid, att.id)
    conn.rollback()
    assert path.exists()


def test_account_delete_removes_directory(conn: sqlite3.Connection) -> None:
    aid = _acct(conn, "doomed")
    note = N.create(conn, aid, body="going away")
    att = ATT.save(conn, aid, "note", note.id, filename="f", mime="x", data=b"bye")
    directory = ATT.file_path(conn, aid, att.id).parent
    accounts_core.delete_account(conn, aid, password="password1")
    assert not directory.exists()
    assert conn.execute("SELECT COUNT(*) AS n FROM attachments").fetchone()["n"] == 0


# ---------- REST ----------

def _register(client: TestClient, username: str = "owner") -> str:
    response = client.post(
        "/api/auth/register", json={"username": username, "password": "password1"}
    )
    assert response.status_code == 200, response.text
    return client.cookies.get("command_session") or ""


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_rest_upload_download_delete(client: TestClient) -> None:
    token = _register(client)
    note = client.post("/api/notes", json={"body": "rest note"}, headers=_auth(token)).json()
    data = b"hello attachment"
    up = client.post(
        "/api/attachments",
        data={"entity_kind": "note", "entity_id": str(note["id"])},
        files={"file": ("hello.txt", data, "text/plain")},
        headers=_auth(token),
    )
    assert up.status_code == 200, up.text
    meta = up.json()
    assert meta["filename"] == "hello.txt"
    assert meta["sha256"] == hashlib.sha256(data).hexdigest()

    listed = client.get(
        "/api/attachments",
        params={"entity_kind": "note", "entity_id": note["id"]},
        headers=_auth(token),
    ).json()
    assert [a["id"] for a in listed] == [meta["id"]]

    down = client.get(f"/api/attachments/{meta['id']}/download", headers=_auth(token))
    assert down.status_code == 200
    assert down.content == data
    assert down.headers["content-type"].startswith("text/plain")

    gone = client.delete(f"/api/attachments/{meta['id']}", headers=_auth(token))
    assert gone.status_code == 200
    assert client.get(
        f"/api/attachments/{meta['id']}/download", headers=_auth(token)
    ).status_code == 404


def test_rest_upload_rejects_oversize(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    # The route reads at most cap+1 bytes; core rejects with the actionable error.
    from command.config import get_settings

    token = _register(client)
    note = client.post("/api/notes", json={"body": "cap"}, headers=_auth(token)).json()
    settings = get_settings()
    monkeypatch.setattr(settings, "max_attachment_bytes", 8)
    up = client.post(
        "/api/attachments",
        data={"entity_kind": "note", "entity_id": str(note["id"])},
        files={"file": ("big.bin", b"0123456789", "application/octet-stream")},
        headers=_auth(token),
    )
    assert up.status_code == 422   # domain ValidationError maps to 422
    assert "too large" in up.text


def test_delegatee_reads_only_their_assignment_attachments(client: TestClient) -> None:
    token = _register(client)
    person = client.post(
        "/api/delegatees", json={"name": "Helper", "kind": "human"}, headers=_auth(token)
    ).json()["delegatee"]
    mine = client.post(
        "/api/assignments",
        json={"title": "Theirs", "scheduled_start": "2026-08-01T09:00:00+00:00",
              "assignee_id": person["id"]},
        headers=_auth(token),
    ).json()
    other = client.post(
        "/api/assignments",
        json={"title": "Not theirs", "scheduled_start": "2026-08-01T10:00:00+00:00"},
        headers=_auth(token),
    ).json()
    note = client.post("/api/notes", json={"body": "private"}, headers=_auth(token)).json()

    def upload(kind: str, eid: int, name: str) -> dict:
        r = client.post(
            "/api/attachments",
            data={"entity_kind": kind, "entity_id": str(eid)},
            files={"file": (name, b"data-" + name.encode(), "text/plain")},
            headers=_auth(token),
        )
        assert r.status_code == 200, r.text
        return r.json()

    on_mine = upload("assignment", mine["id"], "mine.txt")
    on_other = upload("assignment", other["id"], "other.txt")
    on_note = upload("note", note["id"], "note.txt")

    invite = client.post(
        f"/api/delegatees/{person['id']}/invite", headers=_auth(token)
    ).json()["invite_token"]
    redeemed = client.post("/api/auth/invite", json={"token": invite})
    assert redeemed.status_code == 200
    dtoken = client.cookies.get("command_session") or ""

    ok = client.get(
        f"/api/my/assignments/{mine['id']}/attachments", headers=_auth(dtoken)
    )
    assert ok.status_code == 200
    assert [a["id"] for a in ok.json()] == [on_mine["id"]]

    assert client.get(
        f"/api/my/assignments/{other['id']}/attachments", headers=_auth(dtoken)
    ).status_code == 404

    down = client.get(f"/api/my/attachments/{on_mine['id']}/download", headers=_auth(dtoken))
    assert down.status_code == 200
    assert down.content == b"data-mine.txt"
    # not their assignment / a note attachment → invisible
    assert client.get(
        f"/api/my/attachments/{on_other['id']}/download", headers=_auth(dtoken)
    ).status_code == 404
    assert client.get(
        f"/api/my/attachments/{on_note['id']}/download", headers=_auth(dtoken)
    ).status_code == 404
    # delegatee sessions can't touch the operator attachment surface at all
    assert client.get(
        "/api/attachments",
        params={"entity_kind": "assignment", "entity_id": mine["id"]},
        headers=_auth(dtoken),
    ).status_code == 404
    # and can't write: no upload/delete surface exists under /api/my
    assert client.post(
        "/api/attachments",
        data={"entity_kind": "assignment", "entity_id": str(mine["id"])},
        files={"file": ("nope.txt", b"nope", "text/plain")},
        headers=_auth(dtoken),
    ).status_code == 404
    assert client.delete(
        f"/api/attachments/{on_mine['id']}", headers=_auth(dtoken)
    ).status_code == 404


def test_storage_root_follows_db_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from command.config import get_settings

    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "x.db"))
    get_settings.cache_clear()
    try:
        assert ATT.storage_root() == (tmp_path / "attachments")
        monkeypatch.setenv("COMMAND_ATTACHMENTS_DIR", str(tmp_path / "elsewhere"))
        get_settings.cache_clear()
        assert ATT.storage_root() == (tmp_path / "elsewhere")
    finally:
        get_settings.cache_clear()
