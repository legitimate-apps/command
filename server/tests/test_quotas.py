"""Per-account ceilings: hit in core/, so every surface gets the same actionable error."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from command.config import get_settings
from command.core import accounts, activities, assignments, attachments, notes
from command.errors import QuotaExceeded


@pytest.fixture
def account_id(conn: sqlite3.Connection, tmp_path, monkeypatch: pytest.MonkeyPatch) -> Iterator[int]:
    monkeypatch.setenv("COMMAND_ATTACHMENTS_DIR", str(tmp_path / "att"))
    get_settings.cache_clear()
    yield accounts.register(conn, "quota", "pw12345678").id
    get_settings.cache_clear()


def _limit(monkeypatch: pytest.MonkeyPatch, **values: int) -> None:
    for name, value in values.items():
        monkeypatch.setattr(get_settings(), name, value)


def test_note_ceiling(conn, account_id, monkeypatch) -> None:
    _limit(monkeypatch, max_notes_per_account=2)
    notes.create(conn, account_id, "one")
    notes.create(conn, account_id, "two")
    with pytest.raises(QuotaExceeded) as exc:
        notes.create(conn, account_id, "three")
    assert exc.value.code == "quota_exceeded"
    assert "2 notes" in exc.value.message and exc.value.hint
    assert exc.value.details == {"kind": "note", "limit": 2}


def test_ceilings_are_per_account(conn, account_id, monkeypatch) -> None:
    _limit(monkeypatch, max_notes_per_account=1)
    other = accounts.register(conn, "other", "pw12345678").id
    notes.create(conn, account_id, "mine")
    notes.create(conn, other, "theirs")  # the other account's allowance is untouched


def test_zero_means_unlimited(conn, account_id, monkeypatch) -> None:
    _limit(monkeypatch, max_notes_per_account=0)
    for i in range(5):
        notes.create(conn, account_id, f"n{i}")


def test_assignment_and_activity_ceilings(conn, account_id, monkeypatch) -> None:
    _limit(monkeypatch, max_assignments_per_account=1, max_activities_per_account=1)
    assignments.create(conn, account_id, title="a")
    with pytest.raises(QuotaExceeded):
        assignments.create(conn, account_id, title="b")
    activities.create(conn, account_id, title="x")
    with pytest.raises(QuotaExceeded):
        activities.create(conn, account_id, title="y")


def test_attachment_count_and_byte_ceilings(conn, account_id, monkeypatch) -> None:
    note = notes.create(conn, account_id, "carrier")
    _limit(monkeypatch, max_attachments_per_account=2, max_attachment_bytes_per_account=100)
    attachments.save(conn, account_id, "note", note.id, filename="a", mime="text/plain", data=b"x" * 60)
    with pytest.raises(QuotaExceeded) as exc:
        attachments.save(conn, account_id, "note", note.id, filename="b", mime="text/plain", data=b"x" * 41)
    assert exc.value.details is not None and exc.value.details["kind"] == "attachment_bytes"
    attachments.save(conn, account_id, "note", note.id, filename="c", mime="text/plain", data=b"x" * 40)
    with pytest.raises(QuotaExceeded) as exc:
        attachments.save(conn, account_id, "note", note.id, filename="d", mime="text/plain", data=b"x")
    assert exc.value.details is not None and exc.value.details["kind"] == "attachment_count"
    # A refused upload leaves no bytes behind.
    assert len(list((attachments.storage_root() / str(account_id)).iterdir())) == 2


def test_rest_surfaces_the_quota_as_an_actionable_403(client: TestClient, monkeypatch) -> None:
    client.post("/api/auth/register", json={"username": "owner", "password": "correct-horse-battery"})
    monkeypatch.setattr(get_settings(), "max_notes_per_account", 1)
    assert client.post("/api/notes", json={"body": "first"}).status_code == 201
    r = client.post("/api/notes", json={"body": "second"})
    assert r.status_code == 403
    err = r.json()["error"]
    assert err["code"] == "quota_exceeded"
    assert "COMMAND_MAX_NOTES_PER_ACCOUNT" in err["hint"]
