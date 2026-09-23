"""Attachment endpoints: multipart upload, list, download, delete (operator sessions).

The delegatee read-only twin (list + download for their own assignments) lives in `my.py`.
"""

from __future__ import annotations

from fastapi import APIRouter, File, Form, Query, UploadFile
from fastapi.responses import FileResponse

from ..core import attachments as attachments_core
from .deps import Config, CurrentAccount, Db

router = APIRouter(prefix="/api/attachments", tags=["attachments"])


@router.post("", response_model=attachments_core.Attachment)
async def upload(
    account: CurrentAccount,
    conn: Db,
    settings: Config,
    entity_kind: str = Form(...),
    entity_id: int = Form(...),
    file: UploadFile = File(...),
) -> attachments_core.Attachment:
    # Read at most one byte past the cap so an oversized body can't balloon memory; core
    # then rejects with the actionable size error.
    data = await file.read(settings.max_attachment_bytes + 1)
    return attachments_core.save(
        conn,
        account.id,
        entity_kind,
        entity_id,
        filename=file.filename or "attachment",
        mime=file.content_type or "application/octet-stream",
        data=data,
    )


@router.get("", response_model=list[attachments_core.Attachment])
def list_attachments(
    account: CurrentAccount,
    conn: Db,
    entity_kind: str = Query(..., description="'note' or 'assignment'"),
    entity_id: int = Query(...),
) -> list[attachments_core.Attachment]:
    return attachments_core.list_for(conn, account.id, entity_kind, entity_id)


@router.get("/{attachment_id}/download")
def download(attachment_id: int, account: CurrentAccount, conn: Db) -> FileResponse:
    meta = attachments_core.get(conn, account.id, attachment_id)
    path = attachments_core.file_path(conn, account.id, attachment_id)
    return FileResponse(path, media_type=meta.mime, filename=meta.filename)


@router.delete("/{attachment_id}", response_model=attachments_core.Attachment)
def delete_attachment(
    attachment_id: int, account: CurrentAccount, conn: Db
) -> attachments_core.Attachment:
    return attachments_core.delete(conn, account.id, attachment_id)
