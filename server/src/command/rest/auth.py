"""Auth + access-token REST endpoints for the iOS app."""

from __future__ import annotations

from fastapi import APIRouter, Request, Response
from pydantic import BaseModel, Field

from ..config import Settings, get_settings
from ..core import accounts as accounts_core
from ..core import delegatee_access, llm_budget
from ..core.ratelimit import SlidingWindowLimiter
from ..errors import AuthFailed, PermissionDenied, RateLimited
from . import cookies
from .deps import Config, CurrentAccount, Db, session_token_from_request

# Per-username login brute-force guard. Module-level so it accumulates state across
# requests (a fresh instance per request would defeat it). Sized from settings.
_login_limiter = SlidingWindowLimiter(
    max_attempts=get_settings().login_max_attempts,
    window_seconds=get_settings().login_window_seconds,
)
_invite_limiter = SlidingWindowLimiter(
    max_attempts=get_settings().login_max_attempts,
    window_seconds=get_settings().login_window_seconds,
)
# The per-token limiter above cannot slow a brute-force search, and it is important to be
# honest about why: it is keyed on the submitted token, and an attacker guessing the invite
# space submits a DIFFERENT token every time, so every attempt lands on a fresh key and is
# allowed. That keying is right for login — there the attacker holds the username constant and
# varies the password — but here the token IS the secret, so keying on it guards nothing. It
# still earns its place against a client retrying one wrong invite in a loop.
#
# What actually bounds a search is a bucket the attacker cannot vary. IP is useless here (the
# Cloudflare Tunnel makes every peer address loopback — see core/ratelimit's docstring), so
# this is deliberately global. Legitimate invite redemptions are rare and nearly always
# succeed, and a success does not count, so real users never approach this. A flood can
# temporarily block redemptions, which is the accepted trade: the operator can re-issue an
# invite, whereas an unbounded guessing channel cannot be un-run.
_INVITE_GLOBAL_KEY = "invite-attempts"
_invite_global_limiter = SlidingWindowLimiter(max_attempts=60, window_seconds=300.0)

router = APIRouter(prefix="/api", tags=["auth"])


class RegisterIn(BaseModel):
    username: str
    password: str
    display_name: str | None = Field(default=None, max_length=120)


class LoginIn(BaseModel):
    username: str
    password: str


class InviteIn(BaseModel):
    token: str = Field(min_length=1, max_length=255)


class InviteOut(BaseModel):
    delegatee_id: int
    delegatee_name: str
    operator_display_name: str | None


class AccountOut(BaseModel):
    id: int
    username: str
    display_name: str | None
    timezone: str | None
    created_at: str


class TokenOut(BaseModel):
    access_token: str


class TimezoneIn(BaseModel):
    timezone: str = Field(min_length=1, max_length=255)


class TimezoneOut(BaseModel):
    timezone: str


def _set_session_cookie(
    request: Request, response: Response, settings: Settings, raw: str
) -> None:
    secure = cookies.cookie_is_secure(settings, request.scope)
    cookies.set_session_cookie(response, settings, raw, secure=secure)


@router.post("/auth/register", response_model=AccountOut)
def register(
    body: RegisterIn, request: Request, response: Response, settings: Config, conn: Db
) -> AccountOut:
    # First-user-only by default. The instance belongs to whoever claims it; after that the door
    # is shut unless the operator reopens it with COMMAND_ALLOW_REGISTRATION=true. Without this,
    # a self-hosted server on a public hostname lets any passer-by create an account and spend
    # the owner's model budget — and there is no signal anywhere that it happened.
    if not settings.allow_registration and accounts_core.any_account_exists(conn):
        raise PermissionDenied(
            "This Command server already has an account and is not accepting new ones.",
            hint="It's a personal server. If it's yours, set COMMAND_ALLOW_REGISTRATION=true "
                 "to reopen signup; otherwise sign in, or point the app at your own server.",
        )
    account = accounts_core.register(
        conn, body.username, body.password, body.display_name, token_words=settings.token_words
    )
    raw, _ = accounts_core.create_session(conn, account.id, days=settings.session_days)
    _set_session_cookie(request, response, settings, raw)
    return AccountOut(**account.model_dump())


@router.post("/auth/login", response_model=AccountOut)
def login(
    body: LoginIn, request: Request, response: Response, settings: Config, conn: Db
) -> AccountOut:
    key = body.username.strip().lower()
    if not _login_limiter.allowed(key):
        raise RateLimited(
            "Too many failed login attempts. Please wait a few minutes and try again."
        )
    try:
        account = accounts_core.login(conn, body.username, body.password)
    except AuthFailed:
        _login_limiter.record_failure(key)
        raise
    _login_limiter.reset(key)
    raw, _ = accounts_core.create_session(conn, account.id, days=settings.session_days)
    _set_session_cookie(request, response, settings, raw)
    return AccountOut(**account.model_dump())


@router.post("/auth/invite", response_model=InviteOut)
def redeem_invite(
    body: InviteIn, request: Request, response: Response, settings: Config, conn: Db
) -> InviteOut:
    key = body.token.strip()
    if not _invite_limiter.allowed(key) or not _invite_global_limiter.allowed(_INVITE_GLOBAL_KEY):
        raise RateLimited("Too many failed invite attempts. Please wait a few minutes and try again.")
    try:
        session = delegatee_access.redeem_invite(conn, key, days=settings.session_days)
    except AuthFailed:
        _invite_limiter.record_failure(key)
        # The one that actually bounds a guessing run — the attacker cannot vary this key.
        _invite_global_limiter.record_failure(_INVITE_GLOBAL_KEY)
        raise
    _invite_limiter.reset(key)
    # A successful redemption clears the global bucket too, so a burst of typos from real
    # people cannot strand the next legitimate delegatee.
    _invite_global_limiter.reset(_INVITE_GLOBAL_KEY)
    _set_session_cookie(request, response, settings, session.raw_token)
    return InviteOut(
        delegatee_id=session.delegatee.id,
        delegatee_name=session.delegatee.name,
        operator_display_name=session.account.display_name,
    )


@router.post("/auth/logout")
def logout(request: Request, response: Response, settings: Config, conn: Db) -> dict[str, bool]:
    token = session_token_from_request(request, settings)
    if token:
        accounts_core.destroy_session(conn, token)
    response.delete_cookie(settings.cookie_name, path="/")
    return {"ok": True}


@router.get("/auth/me", response_model=AccountOut)
def me(account: CurrentAccount, conn: Db) -> AccountOut:
    # Bootstrap is the first call of every launch, so it IS the app opening — refund the
    # proactive-LLM budget here as well as on the explicit ping, so a user who opens the app
    # never has to also hit a separate endpoint for their briefings to resume.
    llm_budget.record_open(conn, account.id)
    return AccountOut(**account.model_dump())


@router.post("/app/opened")
def app_opened(account: CurrentAccount, conn: Db) -> dict[str, bool]:
    """The app (or web surface) came to the foreground.

    Resets the proactive-LLM send counter: engagement buys the budget back. Deliberately
    explicit rather than inferred from "any authenticated request" — a background push
    registration or token refresh must not look like engagement, or a dormant device keeps
    renewing its own budget and the churn guard never trips.
    """
    llm_budget.record_open(conn, account.id)
    return {"ok": True}


@router.put("/account/timezone", response_model=TimezoneOut)
def set_timezone(body: TimezoneIn, account: CurrentAccount, conn: Db) -> TimezoneOut:
    updated = accounts_core.set_timezone(conn, account.id, body.timezone)
    return TimezoneOut(timezone=updated.timezone or body.timezone)


@router.get("/access-token", response_model=TokenOut)
def get_access_token(account: CurrentAccount, settings: Config, conn: Db) -> TokenOut:
    return TokenOut(access_token=accounts_core.get_access_token(conn, account.id, words=settings.token_words))


@router.post("/access-token/regenerate", response_model=TokenOut)
def regenerate_access_token(account: CurrentAccount, settings: Config, conn: Db) -> TokenOut:
    return TokenOut(
        access_token=accounts_core.regenerate_access_token(conn, account.id, words=settings.token_words)
    )


class DeleteAccountIn(BaseModel):
    password: str


@router.post("/account/delete", status_code=204)
def delete_account(
    body: DeleteAccountIn, account: CurrentAccount, conn: Db, settings: Config, response: Response
) -> None:
    """Permanently delete the signed-in account and all of its data.

    POST rather than DELETE because it carries a body (the password re-auth), which several
    HTTP stacks strip from a DELETE. Clears the session cookie on the way out so the client
    cannot keep using a session whose account no longer exists.
    """
    accounts_core.delete_account(conn, account.id, password=body.password)
    response.delete_cookie(settings.cookie_name, path="/")
