"""Push device-token registration (B4). The iOS app posts its APNs token here after the user
grants notification permission; a scheduled job pushes reminders to these tokens. Per-account
scoped like every other REST surface."""

from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel

from ..core import push
from .deps import CurrentAccount, Db

router = APIRouter(prefix="/api/push", tags=["push"])


class RegisterBody(BaseModel):
    token: str
    environment: str = "production"   # 'sandbox' for dev/TestFlight builds, 'production' for App Store
    platform: str = "ios"


class TokenBody(BaseModel):
    token: str


@router.post("/register", response_model=push.DeviceToken)
def register_token(body: RegisterBody, account: CurrentAccount, conn: Db) -> push.DeviceToken:
    return push.register(
        conn, account.id, body.token, environment=body.environment, platform=body.platform
    )


@router.post("/unregister")
def unregister_token(body: TokenBody, account: CurrentAccount, conn: Db) -> dict[str, bool]:
    return {"removed": push.remove(conn, account.id, body.token)}


@router.get("/tokens", response_model=list[push.DeviceToken])
def list_tokens(account: CurrentAccount, conn: Db) -> list[push.DeviceToken]:
    return push.list_tokens(conn, account.id)
