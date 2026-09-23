"""Notes REST endpoints. No delete route exists, by design (Hard Rule 1)."""

from __future__ import annotations

from fastapi import APIRouter, BackgroundTasks, Query
from pydantic import BaseModel

from ..core import ai, entitlements, notes
from .common import Page
from .deps import CurrentAccount, Db

router = APIRouter(prefix="/api/notes", tags=["notes"])


def _may_auto_title(conn: Db, account_id: int) -> bool:
    """AI titles send the note body to a third-party model, so they need the same
    recorded AI-disclosure consent the assistant does. Without it the note simply
    keeps its first-line fallback title — the feature switches on the moment the
    user consents, and no note content leaves the server before then."""
    return ai.enabled() and entitlements.has_consent(conn, account_id)


class NoteCreate(BaseModel):
    body: str
    source: str = "typed"
    engine: str | None = None
    locale: str | None = None
    title: str | None = None
    hidden: bool = False


class NoteUpdate(BaseModel):
    title: str | None = None
    body: str | None = None


@router.get("", response_model=Page[notes.Note])
def search_notes(
    account: CurrentAccount,
    conn: Db,
    query: str | None = Query(None),
    unprocessed: bool | None = Query(None),
    source: str | None = Query(None),
    include_archived: bool = Query(False),
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = Query(None),
) -> Page[notes.Note]:
    items, nxt = notes.search(
        conn,
        account.id,
        query=query,
        unprocessed=unprocessed,
        source=source,
        include_archived=include_archived,
        include_hidden=True,  # the app shows hidden notes (veiled); only the agent excludes them
        limit=limit,
        cursor=cursor,
    )
    return Page(items=items, next_cursor=nxt)


@router.post("", response_model=notes.Note, status_code=201)
def create_note(
    body: NoteCreate, account: CurrentAccount, conn: Db, background_tasks: BackgroundTasks
) -> notes.Note:
    note = notes.create(
        conn,
        account.id,
        body.body,
        source=body.source,
        engine=body.engine,
        locale=body.locale,
        title=body.title,
        hidden=body.hidden,
    )
    # Every fresh note without a user-set title gets a terse AI title in the
    # background, so the list reads as titles rather than raw first lines.
    if notes.wants_auto_title(note) and not note.title and _may_auto_title(conn, account.id):
        # Commit now so the note is visible to the background task's own DB
        # connection (it runs after the response, on a separate connection).
        conn.commit()
        background_tasks.add_task(ai.generate_and_save_title, note.id, account.id)
        note = note.model_copy(update={"title_status": "generating"})
    return note


@router.get("/{note_id}", response_model=notes.Note)
def get_note(note_id: int, account: CurrentAccount, conn: Db) -> notes.Note:
    return notes.get(conn, account.id, note_id)


@router.patch("/{note_id}", response_model=notes.Note)
def update_note(note_id: int, payload: NoteUpdate, account: CurrentAccount, conn: Db) -> notes.Note:
    note = notes.get(conn, account.id, note_id)
    if payload.body is not None:
        note = notes.update_body(conn, account.id, note_id, payload.body)
    if payload.title is not None:
        # an explicit title from the app is the user's — never auto-overwritten
        note = notes.set_title(conn, account.id, note_id, payload.title, status="user")
    return note


@router.post("/{note_id}/archive", response_model=notes.Note)
def archive_note(note_id: int, account: CurrentAccount, conn: Db, archived: bool = Query(True)) -> notes.Note:
    return notes.set_archived(conn, account.id, note_id, archived)


@router.post("/{note_id}/hidden", response_model=notes.Note)
def set_note_hidden(
    note_id: int, account: CurrentAccount, conn: Db, hidden: bool = Query(True)
) -> notes.Note:
    """Toggle the invisible-ink veil on a note (reversible; never deletes)."""
    return notes.set_hidden(conn, account.id, note_id, hidden)


@router.post("/{note_id}/processed", response_model=notes.Note)
def set_processed_note(
    note_id: int, account: CurrentAccount, conn: Db, processed: bool = Query(True)
) -> notes.Note:
    return notes.set_processed(conn, account.id, note_id, processed)


@router.post("/{note_id}/close", response_model=notes.Note)
def close_note(
    note_id: int, account: CurrentAccount, conn: Db, background_tasks: BackgroundTasks
) -> notes.Note:
    """The user closed the note. Snapshot a backup (only if it changed) and, unless
    the title is user-set, kick off a terse AI title in the background. Returns the
    note immediately with `title_status='generating'` so the app can show progress."""
    revision = notes.snapshot(conn, account.id, note_id)
    note = notes.get(conn, account.id, note_id)
    should_title = notes.wants_auto_title(note) and (revision is not None or not note.title)
    if should_title and _may_auto_title(conn, account.id):
        background_tasks.add_task(ai.generate_and_save_title, note_id, account.id)
        note = note.model_copy(update={"title_status": "generating"})
    return note


@router.get("/{note_id}/revisions", response_model=list[notes.Revision])
def list_note_revisions(note_id: int, account: CurrentAccount, conn: Db) -> list[notes.Revision]:
    return notes.list_revisions(conn, account.id, note_id)


@router.post("/{note_id}/revisions/{revision_id}/restore", response_model=notes.Note)
def restore_note_revision(
    note_id: int, revision_id: int, account: CurrentAccount, conn: Db
) -> notes.Note:
    return notes.restore_revision(conn, account.id, note_id, revision_id)
