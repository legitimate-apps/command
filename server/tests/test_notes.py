from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import notes
from command.errors import NotFound, ValidationError


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_create_and_get(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    n = notes.create(conn, aid, "  buy milk  ", source="typed")
    assert n.body == "buy milk"  # trimmed
    assert n.source == "typed"
    assert notes.get(conn, aid, n.id).id == n.id


def test_empty_body_and_bad_source(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    with pytest.raises(ValidationError):
        notes.create(conn, aid, "   ")
    with pytest.raises(ValidationError):
        notes.create(conn, aid, "x", source="bogus")


def test_search_pagination(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    for i in range(5):
        notes.create(conn, aid, f"note {i}")
    page1, cur = notes.search(conn, aid, limit=2)
    assert len(page1) == 2 and cur is not None
    page2, _ = notes.search(conn, aid, limit=2, cursor=cur)
    assert len(page2) == 2
    assert page1[-1].id > page2[0].id  # strictly older across pages


def test_search_query_and_unprocessed(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    a = notes.create(conn, aid, "apple pie")
    notes.create(conn, aid, "banana split")
    hits, _ = notes.search(conn, aid, query="banana")
    assert len(hits) == 1 and "banana" in hits[0].body
    notes.set_processed(conn, aid, a.id, True)
    unp, _ = notes.search(conn, aid, unprocessed=True)
    assert all(n.processed_at is None for n in unp)
    assert a.id not in {n.id for n in unp}


def test_fts_search_or_terms_and_recent_fallback(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    meal = notes.create(conn, aid, "Cook paprika rice tonight")
    grocery = notes.create(conn, aid, "Buy spinach tomorrow")
    notes.create(conn, aid, "Unrelated journal entry")

    hits, _ = notes.search(conn, aid, query="paprika spinach")
    assert {note.id for note in hits} == {meal.id, grocery.id}

    # A lexical miss is an honest empty result — not unrelated recent notes posing as matches.
    miss, _ = notes.search(conn, aid, query="meals", limit=2)
    assert miss == []
    # Agent surfaces get the recent notes on a miss, explicitly labelled as such.
    found = notes.search_with_fallback(conn, aid, query="meals", limit=2)
    recent, _ = notes.search(conn, aid, limit=2)
    assert found.matched is False and found.items == []
    assert [note.id for note in found.recent] == [note.id for note in recent]
    hit = notes.search_with_fallback(conn, aid, query="paprika")
    assert hit.matched is True and [n.id for n in hit.items] == [meal.id] and hit.recent == []


def test_fts_index_tracks_body_updates(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    note = notes.create(conn, aid, "original wording")
    assert notes.search(conn, aid, query="original")[0][0].id == note.id
    notes.update_body(conn, aid, note.id, "replacement wording")
    replacement, _ = notes.search(conn, aid, query="replacement")
    assert [item.id for item in replacement] == [note.id]


def test_archive_hides_from_default_search(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    n = notes.create(conn, aid, "x")
    notes.set_archived(conn, aid, n.id, True)
    assert notes.search(conn, aid)[0] == []
    assert len(notes.search(conn, aid, include_archived=True)[0]) == 1


def test_account_isolation(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "aaa")
    b = _acct(conn, "bbb")
    n = notes.create(conn, a, "secret")
    with pytest.raises(NotFound):
        notes.get(conn, b, n.id)
    assert notes.search(conn, b)[0] == []


def test_notes_have_no_delete_function() -> None:
    # Hard Rule 1: there is no destructive note operation in the module surface.
    assert not hasattr(notes, "delete")
    assert not hasattr(notes, "remove")


def test_title_provenance(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    n = notes.create(conn, aid, "body", title="  My Title  ")
    assert n.title == "My Title" and n.title_status == "user"
    assert notes.wants_auto_title(n) is False  # user titles are never overwritten

    n2 = notes.create(conn, aid, "body2")
    assert n2.title is None and n2.title_status is None
    assert notes.wants_auto_title(n2) is True
    t = notes.set_title(conn, aid, n2.id, "Auto Name", status="ai")
    assert t.title == "Auto Name" and t.title_status == "ai"
    assert notes.wants_auto_title(t) is True  # ai titles stay refreshable
    assert notes.mark_title_error(conn, aid, n2.id).title_status == "error"


def test_snapshot_dedup_and_prune(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    n = notes.create(conn, aid, "v1")
    r1 = notes.snapshot(conn, aid, n.id)
    assert r1 is not None and r1.body == "v1"
    assert notes.snapshot(conn, aid, n.id) is None  # unchanged -> no duplicate
    for i in range(7):
        notes.update_body(conn, aid, n.id, f"body {i}")
        notes.snapshot(conn, aid, n.id)
    revs = notes.list_revisions(conn, aid, n.id)
    assert len(revs) == notes.MAX_REVISIONS  # only newest 5 survive
    assert revs[0].body == "body 6"  # newest first


def test_restore_revision_roundtrip(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    n = notes.create(conn, aid, "original")
    notes.snapshot(conn, aid, n.id)  # back up "original"
    notes.update_body(conn, aid, n.id, "edited")
    target = next(r for r in notes.list_revisions(conn, aid, n.id) if r.body == "original")
    restored = notes.restore_revision(conn, aid, n.id, target.id)
    assert restored.body == "original"
    # restoring snapshots the "edited" state first, so nothing is lost
    assert "edited" in {r.body for r in notes.list_revisions(conn, aid, n.id)}


def test_revisions_account_isolation(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "owner-a")
    b = _acct(conn, "owner-b")
    n = notes.create(conn, a, "x")
    notes.snapshot(conn, a, n.id)
    with pytest.raises(NotFound):
        notes.list_revisions(conn, b, n.id)
    with pytest.raises(NotFound):
        notes.restore_revision(conn, b, n.id, 1)


def test_malformed_cursor_raises_validation_error(conn: sqlite3.Connection) -> None:
    """A client can send any string as `cursor`; a bad one must be a 422, not a 500 (C3)."""
    aid = _acct(conn)
    for bad in ["!!!not-base64!!!", "e30", "YWJj"]:  # garbage, {} (no id), "abc" (not json)
        with pytest.raises(ValidationError):
            notes.search(conn, aid, cursor=bad)
