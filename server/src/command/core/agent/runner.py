"""The multi-model agent runner.

Builds a pydantic-ai Agent over the shared toolset for any configured tier (Claude
Sonnet/Opus/Haiku plus GLM, Kimi and GPT alternates, all routed via OpenRouter on one
key), picks between the default pair nondeterministically, and runs
a bounded tool-loop — either to completion (`run`) or streaming live events for SSE
(`stream`). pydantic-ai is imported here (heavy), so import this module lazily — not
at app startup.
"""

from __future__ import annotations

import json
import random
from collections.abc import AsyncIterator, Sequence
from dataclasses import dataclass
from typing import Any
from zoneinfo import ZoneInfo

from pydantic_ai import (
    Agent,
    BinaryContent,
    FunctionToolCallEvent,
    FunctionToolResultEvent,
    PartDeltaEvent,
    PartStartEvent,
    TextPartDelta,
)
from pydantic_ai.messages import (
    ModelMessage,
    ModelRequest,
    ModelResponse,
    TextPart,
    UserPromptPart,
)
from pydantic_ai.models.openai import OpenAIChatModel, OpenAIChatModelSettings
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits

from ...config import get_settings
from ...db import connection
from .. import accounts as accounts_core
from .. import clock
from .. import confirm as confirm_core
from ..ai import key as ai_key
from . import tiers
from .threads import ORIGIN_A2A, ORIGIN_APP
from .tools import PEER_TOOLS, SYSTEM_PROMPT, TOOLS, AgentDeps


@dataclass
class AgentResult:
    output: str
    model: str
    input_tokens: int
    output_tokens: int
    extra_cost_usd: float = 0.0
    searches: int = 0
    # Prompt-cache split of `input_tokens` (which is the provider's inclusive total).
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0


def stamp_cache_breakpoint(tools: list[Any]) -> list[Any]:
    """Mark the last tool definition as an Anthropic prompt-cache breakpoint.

    Everything ordered before the breakpoint is cached, and Anthropic's prefix runs
    tools -> system -> messages, so this caches the whole tool-schema block — by far
    the largest static thing we re-send on every step of every loop. Measured live
    against the deployment on 2026-08-03 (Haiku 4.5, 38 tools): the tool block is
    6,169 tokens of a 7,674-token request.

    Tools are byte-stable (their order is pinned by a test), so this placement always
    hits. `stamp_system_cache_breakpoint` extends the cached prefix past the tools to
    cover the static system prompt as well.
    """
    if not tools:
        return tools
    last = dict(tools[-1])
    last["cache_control"] = {"type": "ephemeral"}
    return [*tools[:-1], last]


def stamp_system_cache_breakpoint(messages: list[Any]) -> list[Any]:
    """Mark the static system prompt as a second Anthropic prompt-cache breakpoint.

    `run()`/`stream()` pass a per-second timestamp as `instructions`, so it looks like the
    system block can never be cached. It can: pydantic-ai renders instructions as their OWN
    system message inserted *after* the agent's `system_prompt`, and these slugs keep
    multiple system messages separate (`openai_chat_supports_multiple_system_messages` is
    True — a merge would concatenate them into one volatile string). The wire is therefore

        system[0]  SYSTEM_PROMPT           byte-stable
        system[1]  time + peers preamble   changes every request
        user       the turn

    so a breakpoint on system[0] caches tools + SYSTEM_PROMPT while the volatile preamble
    stays *after* the cut and never invalidates it. Stamping the whole system block instead
    would write a fresh entry on every request.

    A/B'd live against the deployment on 2026-08-03, same prompt, same model:
        without this breakpoint  cache_read 6,169   uncached 1,505
        with    this breakpoint  cache_read 7,315   uncached   359
    i.e. 1,146 fewer full-price input tokens per request, which is SYSTEM_PROMPT's own size.
    """
    if not messages or messages[0].get("role") != "system":
        return messages
    content = messages[0].get("content")
    # Only a plain string is safe to re-wrap; anything else is already in parts form and
    # not the shape this assumes, so leave it (and its cache behaviour) alone.
    if not isinstance(content, str) or not content:
        return messages
    head = {
        **messages[0],
        "content": [
            {"type": "text", "text": content, "cache_control": {"type": "ephemeral"}}
        ],
    }
    return [head, *messages[1:]]


class _CacheAwareOpenAIChatModel(OpenAIChatModel):
    """OpenAIChatModel that emits an Anthropic cache breakpoint via OpenRouter.

    pydantic-ai's own `CachePoint` marker is silently dropped by `OpenAIChatModel`
    ("OpenAI doesn't support prompt caching via CachePoint"), so the supported hook
    is this documented-overridable tool mapper. Verified on the wire through
    OpenRouter: without it, cache reads are 0 on every request.
    """

    def _get_tool_choice(self, model_settings: Any, model_request_parameters: Any) -> Any:
        tools, tool_choice = super()._get_tool_choice(model_settings, model_request_parameters)
        return stamp_cache_breakpoint(tools), tool_choice

    async def _map_messages(self, *args: Any, **kwargs: Any) -> Any:
        # Second breakpoint, on the system prompt. `_map_messages` is the documented
        # override point for message shape; args are forwarded untouched so a signature
        # change upstream can't silently drop the model_settings pydantic-ai now passes.
        return stamp_system_cache_breakpoint(await super()._map_messages(*args, **kwargs))


def _model(slug: str) -> OpenAIChatModel:
    s = get_settings()
    provider = OpenAIProvider(base_url=s.ai_base_url, api_key=ai_key.api_key() or "")
    settings: OpenAIChatModelSettings | None = None
    # OpenRouter provider routing: keep the user's notes away from any upstream that
    # may train on prompts. Matters most for the wide-fanout non-Anthropic slugs.
    dc = s.ai_provider_data_collection.strip().lower()
    if dc in {"deny", "allow"}:
        settings = OpenAIChatModelSettings(extra_body={"provider": {"data_collection": dc}})
    # Prompt caching is an Anthropic-family feature; other vendors either cache
    # automatically or ignore the key, so only stamp it where it's known to work.
    cls = (
        _CacheAwareOpenAIChatModel
        if s.agent_prompt_cache and slug.startswith("anthropic/")
        else OpenAIChatModel
    )
    return cls(slug, provider=provider, settings=settings)


def build_agent(slug: str, *, origin: str = ORIGIN_APP) -> Agent[AgentDeps, str]:
    """`origin='a2a'` (a connected peer started the run) swaps in PEER_TOOLS: the same tools
    minus fetch_url/ask_peer, each gated by the account's agent permission matrix."""
    return Agent(
        _model(slug),
        deps_type=AgentDeps,
        tools=PEER_TOOLS if origin == ORIGIN_A2A else TOOLS,
        system_prompt=SYSTEM_PROMPT,
        retries=2,
    )


def pick_model_slug() -> str:
    """Nondeterministic route: P(Sonnet) = agent_claude_weight, else Fast/Haiku."""
    s = get_settings()
    return s.agent_model_claude if random.random() < s.agent_claude_weight else s.agent_model_fast


def resolve_model_slug(choice: str | None, *, has_images: bool = False) -> str:
    """Map a user-facing model choice to a concrete slug. 'auto' (or unknown/None)
    uses the nondeterministic router; the rest force a tier so the user can ask
    harder questions on Opus, save budget on GLM, or try an alternate house.

    `has_images` is load-bearing: a text-only tier (GLM) can't take an image
    turn, so those fall back to the multimodal default rather than erroring at the
    provider. The run reports the slug it actually used, so the client's model chip
    shows the substitution instead of silently lying about the tier."""
    s = get_settings()
    slug = tiers.slug_for(choice) or pick_model_slug()
    if has_images and slug in tiers.text_only_slugs():
        slug = s.agent_model_claude
    return slug


def _run_context(
    db_path: str, account_id: int, *,
    thread_id: int | None = None, turn_id: int | None = None, origin: str = ORIGIN_APP,
) -> tuple[AgentDeps, str]:
    """Resolve the account timezone once per run and build the dynamic time preamble — plus,
    for a conversation turn, any destructive plan the previous turn left awaiting approval."""
    with connection(db_path) as conn:
        timezone = accounts_core.get_timezone(conn, account_id)
    now = clock.now(ZoneInfo(timezone)).isoformat(timespec="seconds")
    preamble = f"Current date/time: {now}. User timezone: {timezone}."
    if origin == ORIGIN_A2A:
        preamble += (
            " This request comes from a CONNECTED AGENT (another app acting for the user), not "
            "the user directly. fetch_url and ask_peer are unavailable, and the account's "
            "connected-agent permission settings apply to every tool."
        )
    else:
        with connection(db_path) as conn:
            peer_rows = conn.execute(
                "SELECT name, card_json FROM peers WHERE account_id = ? AND enabled = 1 ORDER BY name",
                (account_id,),
            ).fetchall()
        if peer_rows:
            summaries = []
            for r in peer_rows:
                description = str(json.loads(r["card_json"]).get("description", "")).strip()
                summaries.append(f"{r['name']} — {description[:200]}" if description else r["name"])
            preamble += " Connected agents (reachable via ask_peer): " + "; ".join(summaries) + "."
    if thread_id is not None and turn_id is not None:
        with connection(db_path) as conn:
            pending = confirm_core.pending_for_turn(conn, account_id, thread_id, turn_id)
        if pending:
            lines = "; ".join(
                f"{p.tool}({json.dumps(p.args, sort_keys=True)}) — \"{p.summary or ''}\" "
                f"confirm_token={p.confirm_token}"
                for p in pending
            )
            preamble += (
                " Destructive plans from your previous reply are awaiting the user's approval: "
                f"{lines}. Execute one (call the tool again with its confirm_token) ONLY if the "
                "user's message just now clearly approves it; otherwise do not use the token."
            )
    return (
        AgentDeps(
            db_path=db_path, account_id=account_id, account_timezone=timezone,
            thread_id=thread_id, turn_id=turn_id, origin=origin,
        ),
        preamble,
    )


def _user_prompt(
    message: str, images: Sequence[tuple[bytes, str]] | None
) -> str | list[Any]:
    """The current turn's user prompt. Plain text when there are no images;
    otherwise a multimodal sequence (text first, then each image as native
    `BinaryContent`) so the model reads the pictures, not a description of them."""
    if not images:
        return message
    parts: list[Any] = []
    if message:
        parts.append(message)
    parts.extend(BinaryContent(data=data, media_type=media_type) for data, media_type in images)
    return parts


def _history(turns: Sequence[tuple[str, str]] | None) -> list[ModelMessage]:
    """Rebuild prior visible turns as pydantic-ai message history (oldest first).

    Tool calls aren't replayed — the readable user/assistant transcript is enough
    continuity for a follow-up, and keeps reconstruction lossless and simple."""
    msgs: list[ModelMessage] = []
    for role, content in turns or []:
        if not content:
            continue
        if role == "user":
            msgs.append(ModelRequest(parts=[UserPromptPart(content=content)]))
        elif role == "assistant":
            msgs.append(ModelResponse(parts=[TextPart(content=content)]))
    return msgs


def _usage_tokens(result: Any) -> tuple[int, int]:
    if result is None:
        return 0, 0
    u = result.usage  # property in pydantic-ai v1.x
    return (u.input_tokens or 0, u.output_tokens or 0) if u else (0, 0)


def _cache_tokens(result: Any) -> tuple[int, int]:
    """(cache_read, cache_write) for the run, both 0 when the provider reports none."""
    if result is None:
        return 0, 0
    u = result.usage
    if not u:
        return 0, 0
    return int(getattr(u, "cache_read_tokens", 0) or 0), int(getattr(u, "cache_write_tokens", 0) or 0)


def _safe_args(args: Any) -> Any:
    if isinstance(args, str):
        try:
            return json.loads(args)
        except Exception:
            return {"_raw": args[:500]}
    if isinstance(args, dict):
        return args
    return {}


_ENTITY_TOOLS: dict[str, tuple[str, str | None]] = {
    "create_assignment": ("assignment", None),
    "update_assignment": ("assignment", None),
    "set_assignment_status": ("assignment", None),
    "delete_assignment": ("assignment", "assignment"),
    "create_note": ("note", None),
    "create_goal": ("goal", None),
    "delete_goal": ("goal", "goal"),
    "upsert_person": ("person", "delegatee"),
    "remove_person": ("person", "delegatee"),
}


def _tool_entity(tool_name: str, content: Any) -> dict[str, Any] | None:
    """Best-effort compact entity metadata for write-tool SSE completion chips."""
    config = _ENTITY_TOOLS.get(tool_name)
    if config is None:
        return None
    if isinstance(content, str):
        try:
            payload = json.loads(content)
        except (TypeError, json.JSONDecodeError):
            return None
    elif isinstance(content, dict):
        payload = content
    else:
        return None
    kind, nested_key = config
    if nested_key:
        payload = payload.get(nested_key)
    if not isinstance(payload, dict) or not isinstance(payload.get("id"), int):
        return None
    label = payload.get("title") or payload.get("name") or payload.get("body")
    if not isinstance(label, str) or not label.strip():
        return None
    return {"kind": kind, "id": payload["id"], "label": label.strip()[:120]}


async def run(
    db_path: str, account_id: int, message: str, *,
    model_slug: str | None = None, model_choice: str | None = None,
    history: Sequence[tuple[str, str]] | None = None, allow_hidden: bool = False,
    images: Sequence[tuple[bytes, str]] | None = None,
    thread_id: int | None = None, turn_id: int | None = None, origin: str = ORIGIN_APP,
) -> AgentResult:
    s = get_settings()
    slug = model_slug or resolve_model_slug(model_choice, has_images=bool(images))
    agent = build_agent(slug, origin=origin)
    deps, preamble = _run_context(
        db_path, account_id, thread_id=thread_id, turn_id=turn_id, origin=origin
    )
    deps.allow_hidden = allow_hidden
    result = await agent.run(
        _user_prompt(message, images), deps=deps, message_history=_history(history),
        instructions=preamble,
        usage_limits=UsageLimits(request_limit=s.agent_max_steps),
    )
    in_tok, out_tok = _usage_tokens(result)
    c_read, c_write = _cache_tokens(result)
    return AgentResult(
        output=str(result.output), model=slug,
        input_tokens=in_tok, output_tokens=out_tok,
        extra_cost_usd=deps.meter.extra_cost_usd, searches=deps.meter.searches,
        cache_read_tokens=c_read, cache_write_tokens=c_write,
    )


async def stream(
    db_path: str, account_id: int, message: str, *,
    model_slug: str | None = None, model_choice: str | None = None,
    history: Sequence[tuple[str, str]] | None = None, allow_hidden: bool = False,
    images: Sequence[tuple[bytes, str]] | None = None,
    thread_id: int | None = None, turn_id: int | None = None,
) -> AsyncIterator[dict[str, Any]]:
    """Run the agent and yield live events for SSE. Event shapes:

    - {"type":"start","model":slug}
    - {"type":"tool","name":...,"args":{...}}   when the model calls a tool
    - {"type":"tool_done","name":...,"entity":...?} when that tool returns
    - {"type":"text","delta":...}               assistant text as it streams
    - {"type":"done","output":...,"model":...,"input_tokens":...,"output_tokens":...,
       "extra_cost_usd":...,"searches":...,"error":None}   terminal event with usage

    The terminal `done` is ALWAYS emitted — including when the model call raises
    mid-run — with an `error` message set and the best-available token/meter usage
    captured, so the caller can meter the real provider spend (tokens + web-search
    fees) instead of losing the charge on a partial run.
    """
    s = get_settings()
    slug = model_slug or resolve_model_slug(model_choice, has_images=bool(images))
    agent = build_agent(slug)
    deps, preamble = _run_context(db_path, account_id, thread_id=thread_id, turn_id=turn_id)
    deps.allow_hidden = allow_hidden
    yield {"type": "start", "model": slug}

    output = ""
    in_tok = out_tok = 0
    c_read = c_write = 0
    error: str | None = None
    try:
        async with agent.iter(
            _user_prompt(message, images), deps=deps, message_history=_history(history),
            instructions=preamble,
            usage_limits=UsageLimits(request_limit=s.agent_max_steps),
        ) as agent_run:
            try:
                async for node in agent_run:
                    if Agent.is_model_request_node(node):
                        async with node.stream(agent_run.ctx) as request_stream:
                            async for req_event in request_stream:
                                # A text part's first chunk arrives in PartStartEvent; the
                                # rest as deltas — emit both so no leading text is dropped.
                                if isinstance(req_event, PartStartEvent):
                                    part = req_event.part
                                    if isinstance(part, TextPart) and part.content:
                                        yield {"type": "text", "delta": part.content}
                                elif isinstance(req_event, PartDeltaEvent) and isinstance(
                                    req_event.delta, TextPartDelta
                                ):
                                    delta = req_event.delta.content_delta
                                    if delta:
                                        yield {"type": "text", "delta": delta}
                    elif Agent.is_call_tools_node(node):
                        async with node.stream(agent_run.ctx) as handle_stream:
                            async for tool_event in handle_stream:
                                if isinstance(tool_event, FunctionToolCallEvent):
                                    yield {
                                        "type": "tool",
                                        "name": tool_event.part.tool_name,
                                        "args": _safe_args(tool_event.part.args),
                                    }
                                elif isinstance(tool_event, FunctionToolResultEvent):
                                    tool_name = tool_event.part.tool_name or ""
                                    done: dict[str, Any] = {
                                        "type": "tool_done", "name": tool_name
                                    }
                                    entity = _tool_entity(
                                        tool_name, tool_event.part.content
                                    )
                                    if entity is not None:
                                        done["entity"] = entity
                                    yield done
                result = agent_run.result
                output = str(result.output) if result is not None else ""
            finally:
                # Capture cumulative usage even on a partial/errored run: `agent_run.usage`
                # is a live RunUsage property available at any point, so tokens billed
                # before a mid-run failure are still metered, not silently absorbed.
                try:
                    u = agent_run.usage
                    in_tok, out_tok = (u.input_tokens or 0, u.output_tokens or 0)
                    c_read = int(getattr(u, "cache_read_tokens", 0) or 0)
                    c_write = int(getattr(u, "cache_write_tokens", 0) or 0)
                except Exception:
                    pass
    except Exception:
        error = "The agent hit an error. Please try again."

    yield {
        "type": "done",
        "output": output,
        "model": slug,
        "input_tokens": in_tok,
        "output_tokens": out_tok,
        "extra_cost_usd": deps.meter.extra_cost_usd,
        "searches": deps.meter.searches,
        # Cache split so settle() prices reads at 0.1x instead of full rate.
        "cache_read_tokens": c_read,
        "cache_write_tokens": c_write,
        "error": error,
    }
