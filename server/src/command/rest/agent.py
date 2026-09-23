"""Agent REST surface: a streaming chat endpoint plus thread/usage reads.

`POST /api/agent/chat` runs the routed agent and streams Server-Sent Events
(tool calls, compact write-result entity metadata, text deltas, a terminal `done`). The generator runs *after*
the request-scoped DB dependency is torn down, so it opens its own short-lived
connections — it never touches the `Db` dependency. The monthly cap is enforced
before any model call; the user/assistant turn pair and the run's cost are
persisted when the run finishes.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import contextlib
import json
import logging
from collections.abc import AsyncIterator
from typing import Any, cast

from fastapi import APIRouter, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from ..core import accounts as accounts_core
from ..core import entitlements, revenuecat
from ..core.agent import settle, threads, tiers, usage
from ..core.ai import key as ai_key
from ..db import connection
from ..errors import AuthFailed, Conflict, NotFound, ValidationError
from .common import Page
from .deps import (
    Config,
    CurrentAccount,
    Db,
    cookie_refresher,
    session_policy,
    session_token_from_request,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/agent", tags=["agent"])


# Per-account run serialization + settlement live in core/agent/settle.py so the
# inbound A2A surface shares the exact same lock + metering path.
_account_lock = settle.account_lock
_record_run = settle.record_run


# Inline image input limits. Images ride base64 in the chat body (no storage
# subsystem — they're sent to the model for this turn only, never persisted), so
# keep them small: the client already downscales to ~1024px JPEG before encoding.
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif"}
MAX_IMAGES = 4
MAX_IMAGE_BYTES = 6 * 1024 * 1024  # per image, decoded


class ChatImage(BaseModel):
    media_type: str  # one of ALLOWED_IMAGE_TYPES
    data: str        # base64-encoded image bytes (no data: URI prefix)


class ChatRequest(BaseModel):
    message: str
    thread_id: int | None = None
    # "auto" (default) or a tier id from GET /api/agent/models
    model: str | None = None
    # per-chat opt-in to let the agent read hidden items (defaults off each chat)
    allow_hidden: bool = False
    # Optional image attachments, sent natively to a vision-capable model this turn.
    images: list[ChatImage] = []


def _decode_images(images: list[ChatImage]) -> tuple[list[tuple[bytes, str]], str | None]:
    """Validate + base64-decode inbound images. Returns (decoded, error). On any
    problem returns ([], message) so the caller can surface an actionable SSE error
    rather than 500-ing mid-stream."""
    if len(images) > MAX_IMAGES:
        return [], f"Attach at most {MAX_IMAGES} images per message."
    decoded: list[tuple[bytes, str]] = []
    for img in images:
        media_type = img.media_type.strip().lower()
        if media_type not in ALLOWED_IMAGE_TYPES:
            return [], f"Unsupported image type '{img.media_type}'. Use JPEG, PNG, WebP, or GIF."
        try:
            raw = base64.b64decode(img.data, validate=True)
        except (binascii.Error, ValueError):
            return [], "An attached image was not valid base64."
        if not raw:
            return [], "An attached image was empty."
        if len(raw) > MAX_IMAGE_BYTES:
            return [], "An attached image is too large (max 6 MB each)."
        decoded.append((raw, media_type))
    return decoded, None


def _sse(obj: dict[str, object]) -> str:
    return f"data: {json.dumps(obj, default=str)}\n\n"


# SSE comment line (ignored by every EventSource parser) sent while a run is quiet. A long tool
# step or a slow model can go well past a client's idle timeout (URLSession's default is 60s)
# with no bytes on the wire, and the client then kills a turn that is still working.
KEEPALIVE_SECONDS = 15.0
_PING = ": ping\n\n"


class _Failed:
    __slots__ = ("exc",)

    def __init__(self, exc: Exception) -> None:
        self.exc = exc


_END = object()


async def _with_keepalive(
    events: AsyncIterator[dict[str, Any]], interval: float
) -> AsyncIterator[dict[str, Any] | None]:
    """Re-yield `events`, yielding None whenever `interval` seconds pass without one.

    The source runs in its own task feeding a queue, and the wait is on the QUEUE: timing out
    `queue.get()` is harmless, whereas timing out the generator's own `__anext__` would cancel
    the agent mid-step. No polling — the loop sleeps in `wait_for` until an event or the
    interval. Errors from the source are re-raised here; closing this generator (client gone,
    or the caller breaking after `done`) cancels the source task.
    """
    queue: asyncio.Queue[object] = asyncio.Queue()

    async def pump() -> None:
        try:
            async for event in events:
                await queue.put(event)
        except Exception as exc:
            await queue.put(_Failed(exc))
        finally:
            await queue.put(_END)

    task = asyncio.create_task(pump())
    try:
        while True:
            try:
                item = await asyncio.wait_for(queue.get(), timeout=interval)
            except TimeoutError:
                yield None
                continue
            if item is _END:
                return
            if isinstance(item, _Failed):
                raise item.exc
            yield cast(dict[str, Any], item)
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


def _derive_title(message: str) -> str:
    line = next((ln.strip() for ln in message.splitlines() if ln.strip()), "")
    if not line:
        return "New chat"
    return line[:48] + "…" if len(line) > 48 else line


@router.post("/chat")
async def chat(payload: ChatRequest, request: Request, settings: Config) -> StreamingResponse:
    """Stream an agent run as SSE. Body: {message, thread_id?}. Starts a new thread
    when thread_id is omitted. Enforces the per-account monthly spend cap up front."""
    db_path = settings.db_path
    cap = settings.agent_monthly_cap_usd
    message = payload.message.strip()
    thread_id_req = payload.thread_id
    model_choice = payload.model
    allow_hidden = payload.allow_hidden
    images_in = payload.images

    # Resolve the account with a short-lived connection that commits + closes *now*.
    # A request-scoped dependency connection would stay open (holding the session
    # last_seen write lock) for the whole stream and deadlock the generator's writes.
    token = session_token_from_request(request, settings)
    account = None
    if token:
        with connection(db_path) as conn:
            account = accounts_core.get_session_account(
                conn,
                token,
                policy=session_policy(settings),
                on_renew=cookie_refresher(request, settings, token),
            )
    if account is None:
        raise AuthFailed("Not authenticated.", hint="log in via POST /api/auth/login")
    account_id = account.id

    async def gen() -> AsyncIterator[str]:
        if not ai_key.configured():
            yield _sse({"type": "error", "error": "The agent isn't configured on this server yet."})
            return
        images, image_error = _decode_images(images_in)
        if image_error is not None:
            yield _sse({"type": "error", "error": image_error})
            return
        if not message and not images:
            yield _sse({"type": "error", "error": "Message is empty."})
            return

        # Serialize a single account's runs so the check-then-act cap gate can't be
        # raced by two concurrent chats into an over-limit double-spend.
        budget_governed = False
        async with _account_lock(account_id):
            # Setup turn: enforce AI-disclosure consent + subscription (when on) + the
            # budget/cap, resolve/create the thread, persist the user message.
            try:
                with connection(db_path) as conn:
                    # Server-side backstop for the Apple AI-disclosure requirement: never
                    # forward the user's data to the model without a recorded consent row
                    # (the app gates this too, but a non-app caller must not bypass it).
                    if not entitlements.has_consent(conn, account_id):
                        yield _sse({
                            "type": "error", "code": "consent_required",
                            "error": "Please accept the AI-assistant disclosure to continue.",
                        })
                        return
                    # A paid-subscription account is governed by its per-period USD budget
                    # (E4); comp/unsubscribed accounts stay on the flat monthly cap. Inert
                    # unless credits are live.
                    budget_governed = settings.credits_enabled and entitlements.is_store_subscribed(
                        conn, account_id
                    )
                    if settings.agent_require_subscription and not entitlements.is_active(
                        conn, account_id
                    ):
                        yield _sse({
                            "type": "error", "code": "subscription_required",
                            "error": "Subscribe to Command Pro to use the assistant.",
                            "product_id": settings.agent_product_id, "price": settings.agent_price_display,
                        })
                        return
                    if budget_governed:
                        # Gate the next turn when the per-period budget is spent. A single
                        # final turn may dip it slightly negative before this fires, so test
                        # for depletion (<= 0), matching the flat cap's one-turn overshoot.
                        if entitlements.budget_remaining(conn, account_id) <= 0:
                            yield _sse({
                                "type": "error", "code": "budget_exhausted",
                                "error": "You've used all your assistant credits for this billing "
                                         "period. They renew with your subscription.",
                            })
                            return
                    elif usage.over_cap(conn, account_id, cap):
                        used = usage.get_usage(conn, account_id).cost_usd
                        yield _sse({
                            "type": "error", "code": "cap_reached",
                            "error": f"You've reached this month's ${cap:.0f} agent limit.",
                            "cost_usd": used, "cap_usd": cap,
                        })
                        return
                    if thread_id_req is not None:
                        thread = threads.get_thread(conn, account_id, thread_id_req)
                    else:
                        thread = threads.create_thread(conn, account_id)
                    prior = [
                        (m.role, m.content)
                        for m in threads.list_messages(conn, account_id, thread.id)
                    ]
                    # Images aren't persisted (no storage subsystem); record the text, or a
                    # marker for an image-only turn so the reopened transcript isn't blank.
                    persisted = message or (f"[{len(images)} image{'s' if len(images) != 1 else ''}]")
                    turn = threads.add_message(
                        conn, account_id, thread.id, threads.ROLE_USER, persisted
                    )
            except NotFound as exc:
                yield _sse({"type": "error", "error": exc.message})
                return

            thread_id = thread.id
            thread_untitled = thread.title is None
            # `user_message_id` (additive): the persisted id of the message just sent, so the
            # client can anchor "Edit & resend" / "Regenerate" (POST .../truncate) without a
            # refetch.
            yield _sse({"type": "thread", "thread_id": thread_id, "user_message_id": turn.id})

            # Run the agent, forwarding live events; capture the terminal `done`
            # (runner.stream ALWAYS yields one, even on a mid-run error, so the run's
            # real spend is always metered below).
            from ..core.agent import runner  # lazy: pydantic-ai is heavy

            final: dict[str, Any] | None = None
            try:
                async for event in _with_keepalive(
                    runner.stream(
                        db_path, account_id, message, model_choice=model_choice, history=prior,
                        allow_hidden=allow_hidden, images=images,
                        thread_id=thread_id, turn_id=turn.id,
                    ),
                    KEEPALIVE_SECONDS,
                ):
                    if event is None:
                        yield _PING   # nothing to say yet — keep the client's idle timer fed
                        continue
                    if event.get("type") == "done":
                        final = event
                        break
                    yield _sse(event)
            except Exception:
                logger.exception("agent stream failed for account %s", account_id)

            if final is None:
                yield _sse({"type": "error", "error": "The agent produced no output."})
                return

            output = str(final.get("output") or "")
            model = str(final.get("model") or "")
            run_error = final.get("error")
            has_output = bool(output) and not run_error
            # Meter cost ALWAYS (retried on lock contention); persist the assistant turn
            # + title only when there is genuine output.
            cost, remaining = await _record_run(
                db_path, account_id, model, final, cap,
                output=output if has_output else None, thread_id=thread_id,
                set_title=_derive_title(persisted) if (thread_untitled and has_output) else None,
                budget_governed=budget_governed,
            )

            if run_error:
                yield _sse({"type": "error", "error": run_error, "remaining_usd": remaining})
                return

            yield _sse({
                "type": "done", "thread_id": thread_id, "output": output, "model": model,
                "cost_usd": cost, "remaining_usd": remaining, "searches": final.get("searches", 0),
            })

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Connection": "keep-alive"},
    )


@router.get("/threads", response_model=Page[threads.Thread])
def list_threads(
    account: CurrentAccount, conn: Db,
    limit: int = Query(50, ge=1, le=200), cursor: str | None = Query(None),
) -> Page[threads.Thread]:
    items, nxt = threads.list_threads(conn, account.id, limit=limit, cursor=cursor)
    return Page(items=items, next_cursor=nxt)


class ThreadDetail(BaseModel):
    thread: threads.Thread
    messages: list[threads.Message]


@router.get("/threads/{thread_id}", response_model=ThreadDetail)
def get_thread(thread_id: int, account: CurrentAccount, conn: Db) -> ThreadDetail:
    thread = threads.get_thread(conn, account.id, thread_id)
    msgs = threads.list_messages(conn, account.id, thread_id)
    return ThreadDetail(thread=thread, messages=msgs)


class TruncateIn(BaseModel):
    # Exactly one: `after_message_id` keeps that message; `from_message_id` removes it too.
    after_message_id: int | None = None
    from_message_id: int | None = None


class TruncateOut(BaseModel):
    ok: bool
    remaining: int


@router.post("/threads/{thread_id}/truncate", response_model=TruncateOut)
def truncate_thread(
    thread_id: int, body: TruncateIn, account: CurrentAccount, conn: Db
) -> TruncateOut:
    """Delete every message in the thread with id > `after_message_id` — or >= `from_message_id`
    (for "Edit & resend" / "Regenerate"). 404 if the thread isn't this account's; 422 if the
    message isn't in it; 409 while one of the account's runs is still streaming (it would write
    its reply into the transcript being cut)."""
    if _account_lock(account.id).locked():
        raise Conflict(
            "A reply is still being generated.", hint="wait for it to finish, then truncate"
        )
    if (body.after_message_id is None) == (body.from_message_id is None):
        raise ValidationError(
            "Pass exactly one of after_message_id or from_message_id.",
            hint="from_message_id replaces a message (edit & resend); after_message_id keeps it",
        )
    if body.from_message_id is not None:
        remaining = threads.truncate_after(
            conn, account.id, thread_id, body.from_message_id, inclusive=True
        )
    else:
        assert body.after_message_id is not None
        remaining = threads.truncate_after(conn, account.id, thread_id, body.after_message_id)
    return TruncateOut(ok=True, remaining=remaining)


class UsageSummary(BaseModel):
    period: str
    cost_usd: float
    cap_usd: float            # governing total: the per-period budget when credits govern, else the flat cap
    remaining_usd: float      # governing remaining (budget for a subscriber, else cap - cost)
    runs: int
    input_tokens: int
    output_tokens: int
    credits_enabled: bool = False   # whether the USD-budget monetization model is live
    budget_governed: bool = False   # true ⇒ the client shows remaining x CREDIT_MULTIPLIER with a $


class ModelTier(BaseModel):
    id: str            # send as ChatRequest.model
    slug: str          # the model it runs, e.g. "openai/gpt-6-sol"; the app names the tier from it
    images: bool       # False ⇒ an image turn falls back to the default model


class ModelTiers(BaseModel):
    tiers: list[ModelTier]


@router.get("/models", response_model=ModelTiers)
def get_models(account: CurrentAccount) -> ModelTiers:
    """The tiers the picker offers, in order ("auto" is implicit and not listed)."""
    text_only = tiers.text_only_slugs()
    return ModelTiers(tiers=[
        ModelTier(id=tier, slug=slug, images=slug not in text_only)
        for tier, slug in tiers.model_tiers()
    ])


@router.get("/usage", response_model=UsageSummary)
def get_usage(account: CurrentAccount, conn: Db, settings: Config) -> UsageSummary:
    u = usage.get_usage(conn, account.id)
    cap = settings.agent_monthly_cap_usd
    budget_governed = settings.credits_enabled and entitlements.is_store_subscribed(conn, account.id)
    if budget_governed:
        total = settings.agent_subscription_price_usd / entitlements.CREDIT_MULTIPLIER
        remaining = max(0.0, entitlements.budget_remaining(conn, account.id))
        return UsageSummary(
            period=u.period, cost_usd=u.cost_usd, cap_usd=round(total, 4),
            remaining_usd=round(remaining, 4), runs=u.runs,
            input_tokens=u.input_tokens, output_tokens=u.output_tokens,
            credits_enabled=True, budget_governed=True,
        )
    return UsageSummary(
        period=u.period, cost_usd=u.cost_usd, cap_usd=cap,
        remaining_usd=max(0.0, cap - u.cost_usd), runs=u.runs,
        input_tokens=u.input_tokens, output_tokens=u.output_tokens,
        credits_enabled=settings.credits_enabled, budget_governed=False,
    )


class EntitlementStatus(BaseModel):
    active: bool                  # entitled to use the assistant right now
    requires_subscription: bool   # whether the server is gating on a subscription
    product_id: str
    price_display: str
    trial_days: int
    consent_given: bool           # AI-disclosure consent recorded
    status: str                   # none | active | grace | expired | comp
    period_type: str | None
    expires_at: str | None
    will_renew: bool
    credits_enabled: bool = False       # whether the USD-budget monetization model is live
    budget_usd_remaining: float = 0.0   # real backend USD; client shows x CREDIT_MULTIPLIER with a $
    # The RevenueCat app_user_id for this account: `<instance_id>:<account_id>`. The app must
    # `Purchases.logIn(billing_user_id)` — a bare account id collides across self-hosted
    # instances (every instance has an account 1).
    billing_user_id: str


def _entitlement_status(conn: Db, account_id: int, settings: Config) -> EntitlementStatus:
    e = entitlements.get(conn, account_id)
    return EntitlementStatus(
        billing_user_id=entitlements.billing_user_id(conn, account_id),
        active=entitlements.is_active(conn, account_id),
        requires_subscription=settings.agent_require_subscription,
        product_id=settings.agent_product_id,
        price_display=settings.agent_price_display,
        trial_days=settings.agent_trial_days,
        consent_given=e.consent_at is not None,
        status=e.status, period_type=e.period_type,
        expires_at=e.expires_at, will_renew=e.will_renew,
        credits_enabled=settings.credits_enabled,
        budget_usd_remaining=(
            round(e.ai_budget_usd_remaining, 4) if settings.credits_enabled else 0.0
        ),
    )


@router.get("/entitlement", response_model=EntitlementStatus)
def get_entitlement(account: CurrentAccount, conn: Db, settings: Config) -> EntitlementStatus:
    """The app reads this to decide whether to show the paywall / the consent gate.

    With COMMAND_REVENUECAT_API_KEY set it first confirms the account with RevenueCat
    (debounced), so a purchase counts here even when the webhook points at another server."""
    revenuecat.refresh_if_due(conn, account.id, settings)
    return _entitlement_status(conn, account.id, settings)


@router.post("/consent", response_model=EntitlementStatus)
def post_consent(account: CurrentAccount, conn: Db, settings: Config) -> EntitlementStatus:
    """Record the user's AI-disclosure consent (Apple requires it before sending
    their data to a third-party model). Idempotent."""
    entitlements.record_consent(conn, account.id)
    return _entitlement_status(conn, account.id, settings)
