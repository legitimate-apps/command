"""The narrow REST surface available to an invited delegatee."""

from __future__ import annotations

from fastapi import APIRouter, Query, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel

from ..core import assignments as assignments_core
from ..core import attachments as attachments_core
from ..core import delegatee_access
from ..core import push as push_core
from .assignments import TRUNCATED_HEADER
from .deps import CurrentDelegatee, Db

router = APIRouter(prefix="/api/my", tags=["my-work"])


class ProfileOut(BaseModel):
    delegatee_id: int
    delegatee_name: str
    operator_display_name: str | None


class StatusIn(BaseModel):
    status: str


@router.get("/profile", response_model=ProfileOut)
def profile(current: CurrentDelegatee) -> ProfileOut:
    account, delegatee = current
    return ProfileOut(
        delegatee_id=delegatee.id,
        delegatee_name=delegatee.name,
        operator_display_name=account.display_name,
    )


@router.get("/assignments", response_model=list[assignments_core.Assignment])
def assignments(current: CurrentDelegatee, conn: Db) -> list[assignments_core.Assignment]:
    account, delegatee = current
    return delegatee_access.my_assignments(conn, account.id, delegatee.id)


@router.get("/calendar", response_model=list[assignments_core.Occurrence])
def calendar(
    response: Response,
    current: CurrentDelegatee, conn: Db, start: str = Query(...), end: str = Query(...)
) -> list[assignments_core.Occurrence]:
    """Same window/cap contract as `/api/assignments/calendar`, incl. `X-Calendar-Truncated`."""
    account, delegatee = current
    occurrences, truncated = delegatee_access.my_calendar(
        conn, account.id, delegatee.id, start, end
    )
    response.headers[TRUNCATED_HEADER] = "true" if truncated else "false"
    return occurrences


@router.post("/assignments/{assignment_id}/status", response_model=assignments_core.Assignment)
def set_assignment_status(
    assignment_id: int, body: StatusIn, current: CurrentDelegatee, conn: Db
) -> assignments_core.Assignment:
    account, delegatee = current
    return delegatee_access.set_my_assignment_status(
        conn, account.id, delegatee.id, assignment_id, body.status
    )


@router.post("/assignments/{assignment_id}/occurrences/{occurrence_date}/status")
def set_occurrence_status(
    assignment_id: int, occurrence_date: str, body: StatusIn,
    current: CurrentDelegatee, conn: Db,
) -> dict[str, bool]:
    account, delegatee = current
    delegatee_access.set_my_occurrence_status(
        conn, account.id, delegatee.id, assignment_id, occurrence_date, body.status
    )
    return {"updated": True}


class PushRegisterIn(BaseModel):
    token: str
    environment: str = "production"
    platform: str = "ios"


class PushTokenIn(BaseModel):
    token: str


@router.post("/push/register", response_model=push_core.DeviceToken)
def register_push(
    body: PushRegisterIn, current: CurrentDelegatee, conn: Db
) -> push_core.DeviceToken:
    """Register the delegatee device's APNs token. Stamped with delegatee_id so the reminder
    job routes only this delegatee's own assignments to it."""
    account, delegatee = current
    return push_core.register(
        conn,
        account.id,
        body.token,
        environment=body.environment,
        platform=body.platform,
        delegatee_id=delegatee.id,
    )


@router.post("/push/unregister")
def unregister_push(body: PushTokenIn, current: CurrentDelegatee, conn: Db) -> dict[str, bool]:
    account, delegatee = current
    # Scoped to THIS delegatee's own devices — see `push.remove`. Registration stamps the
    # delegatee id, so unregistration has to check it, or this endpoint hands any delegatee a
    # way to switch off the operator's notifications.
    return {
        "removed": push_core.remove(
            conn, account.id, body.token, only_delegatee_id=delegatee.id
        )
    }


@router.get("/assignments/{assignment_id}/attachments",
            response_model=list[attachments_core.Attachment])
def assignment_attachments(
    assignment_id: int, current: CurrentDelegatee, conn: Db
) -> list[attachments_core.Attachment]:
    """Read-only: attachments the operator put on one of THIS delegatee's assignments."""
    account, delegatee = current
    return delegatee_access.my_assignment_attachments(conn, account.id, delegatee.id, assignment_id)


@router.get("/attachments/{attachment_id}/download")
def download_attachment(attachment_id: int, current: CurrentDelegatee, conn: Db) -> FileResponse:
    account, delegatee = current
    meta = delegatee_access.my_attachment_for_download(conn, account.id, delegatee.id, attachment_id)
    path = attachments_core.file_path(conn, account.id, attachment_id)
    return FileResponse(path, media_type=meta.mime, filename=meta.filename)
