"""Inbound A2A surface — peer agents talking TO Command's agent.

The shared adapter authenticates the per-account access token (same credential
as the MCP surface), and each inbound task runs ONE agent turn through the same
runner/lock/metering path as an in-app chat turn, with the same budget/cap
debiting and the same consent + subscription gate. What differs is trust: a peer
gets the PEER toolset (no fetch_url / ask_peer, every tool checked against the
account's agent permission matrix, like MCP). The A2A ``contextId`` maps to a
native agent thread (``cmd-thread-<id>``) that A2A itself started — a peer can
never continue one of the operator's app threads.
"""

from __future__ import annotations

import sqlite3

import anyio

from ...config import Settings, get_settings
from ...db import connection
from ...errors import NotFound
from .. import accounts, entitlements
from ..agent import settle, threads, usage
from ..ratelimit import SlidingWindowLimiter
from . import registry
from .a2a_adapter import A2AAdapter, A2ATurnError

CONTEXT_PREFIX = "cmd-thread-"

# 30 inbound turns/hour per account. In-memory sliding window is the house
# pattern (single uvicorn worker; see core/ratelimit.py). Every request counts
# as a "hit" — the limiter's failure vocabulary reads oddly here but the
# mechanics are exactly a request window.
_rate = SlidingWindowLimiter(max_attempts=30, window_seconds=3600)

AGENT_DESCRIPTION = (
    "Command — a personal planning agent. It manages the user's calendar of "
    "assignments and reminders, captured notes (read and create; never delete), "
    "people, goals, and delegated work. Ask it in natural language to look "
    "things up or to plan, schedule, and record things for its user."
)

SKILLS = [
    {
        "id": "planning",
        "name": "Personal planning",
        "description": "Read/create notes, manage assignments, reminders, goals, "
        "people, and delegation for the account's user.",
        "tags": ["planning", "calendar", "notes", "tasks"],
    }
]


def _thread_for_context(
    conn: sqlite3.Connection, account_id: int, context_id: str | None
) -> threads.Thread:
    if context_id:
        if not context_id.startswith(CONTEXT_PREFIX):
            raise A2ATurnError(
                "Unknown context — omit contextId to start a new conversation."
            )
        try:
            thread_id = int(context_id.removeprefix(CONTEXT_PREFIX))
            thread = threads.get_thread(conn, account_id, thread_id)
        except (ValueError, NotFound):
            raise A2ATurnError(
                "Unknown context — omit contextId to start a new conversation."
            ) from None
        # Only a conversation a peer STARTED may be continued by a peer. Thread ids are
        # sequential, so without this a peer could name any of the operator's own chats, pull
        # its whole transcript into the run as history, and write into it. Same error as an
        # unknown id: whether an app thread exists is not the peer's business.
        if thread.origin != threads.ORIGIN_A2A:
            raise A2ATurnError("Unknown context — omit contextId to start a new conversation.")
        return thread
    return threads.create_thread(
        conn, account_id, title="Connected agent conversation", origin=threads.ORIGIN_A2A
    )


async def run_turn(
    db_path: str, text: str, context_id: str | None, account: accounts.Account
) -> tuple[str, str]:
    from ..agent import runner  # lazy: pydantic-ai is heavy (house convention)

    s = get_settings()
    key = f"a2a:{account.id}"
    if not _rate.allowed(key):
        raise A2ATurnError("Rate limit exceeded — try again in an hour.")
    _rate.record_failure(key)  # count this request against the window

    lock = settle.account_lock(account.id)
    if lock.locked():
        raise A2ATurnError("The agent is busy with another conversation — retry shortly.")
    async with lock:
        cap = s.agent_monthly_cap_usd
        with connection(db_path) as conn:
            # Same legal gate as the REST chat surface: no recorded AI-disclosure
            # consent -> no model call, no matter who's asking.
            if not entitlements.has_consent(conn, account.id):
                raise A2ATurnError(
                    "This account hasn't accepted the AI-assistant disclosure yet — "
                    "open the Command app and accept it first."
                )
            # The subscription gate, via the SAME predicate as chat and briefings. This path
            # checked consent only, so with subscriptions required a lapsed account could still
            # run the paid agent by asking through a peer.
            if not entitlements.can_use_agent(
                conn, account.id, require_subscription=s.agent_require_subscription
            ):
                raise A2ATurnError(
                    "This account needs an active Command Pro subscription to use the assistant."
                )
            budget_governed = s.credits_enabled and entitlements.is_store_subscribed(
                conn, account.id
            )
            if budget_governed:
                if entitlements.budget_remaining(conn, account.id) <= 0:
                    raise A2ATurnError(
                        "This account's assistant credits are used up for the period."
                    )
            elif usage.over_cap(conn, account.id, cap):
                raise A2ATurnError(
                    "This account's assistant usage cap is reached for the month."
                )
            thread = _thread_for_context(conn, account.id, context_id)
            history = [
                (m.role, m.content) for m in threads.list_messages(conn, account.id, thread.id)
            ]
            turn = threads.add_message(conn, account.id, thread.id, threads.ROLE_USER, text)
            exchange_id = registry.log_exchange(
                conn,
                account.id,
                peer_id=None,
                direction="in",
                context_id=f"{CONTEXT_PREFIX}{thread.id}",
                request_text=text,
                response_text=None,
                status="started",
            )

        try:
            # origin=a2a: the peer toolset (permission-matrix gated, no fetch_url/ask_peer);
            # thread/turn bind any destructive confirm token to this conversation's next turn.
            result = await runner.run(
                db_path, account.id, text, history=history,
                thread_id=thread.id, turn_id=turn.id, origin=threads.ORIGIN_A2A,
            )
        except Exception:
            with connection(db_path) as conn:
                conn.execute(
                    "UPDATE peer_exchanges SET status = 'error:run' WHERE id = ?", (exchange_id,)
                )
                conn.commit()
            raise

        await settle.record_run(
            db_path,
            account.id,
            result.model,
            {
                "input_tokens": result.input_tokens,
                "output_tokens": result.output_tokens,
                "extra_cost_usd": result.extra_cost_usd,
            },
            cap,
            output=result.output,
            thread_id=thread.id,
            set_title=None,
            budget_governed=budget_governed,
        )
        with connection(db_path) as conn:
            conn.execute(
                "UPDATE peer_exchanges SET response_text = ?, status = 'ok' WHERE id = ?",
                (result.output, exchange_id),
            )
            conn.commit()
        return result.output, f"{CONTEXT_PREFIX}{thread.id}"


def build_adapter(db_path: str, settings: Settings) -> A2AAdapter:
    def authenticate(token: str | None) -> accounts.Account | None:
        if not token:
            return None
        with connection(db_path) as conn:
            return accounts.account_for_access_token(conn, token)

    def run_agent_turn(
        text: str, context_id: str | None, account: object
    ) -> tuple[str, str]:
        # handle_rpc runs in a Starlette worker thread (anyio.to_thread); hop
        # back onto the event loop for the async runner.
        if not isinstance(account, accounts.Account):
            raise TypeError("authenticated A2A principal must be an Account")
        return anyio.from_thread.run(run_turn, db_path, text, context_id, account)

    base_url = settings.public_base_url or "http://localhost:8000"
    return A2AAdapter(
        agent_name="Command",
        agent_description=AGENT_DESCRIPTION,
        public_base_url=base_url,
        version="1.0.0",
        authenticate=authenticate,
        run_agent_turn=run_agent_turn,
        skills=SKILLS,
    )
