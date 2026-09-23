"""Agent core: threads, metering, the tool layer, the model router, and the REST
SSE surface's pre-run gates (cap + config). No test hits the network — the tool
layer is exercised directly and the chat gates short-circuit before any model call.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from command.core import accounts, entitlements
from command.core import delegatees as delegatees_core
from command.core.agent import pricing, threads, tools, usage
from command.db import connection, init_db
from command.errors import NotFound


def _ctx(db_path: str, account_id: int, timezone: str = "UTC") -> SimpleNamespace:
    """A stand-in for pydantic-ai's RunContext: the tools only read `.deps`."""
    return SimpleNamespace(
        deps=tools.AgentDeps(
            db_path=db_path, account_id=account_id, account_timezone=timezone
        )
    )


def _auth(client: TestClient) -> None:
    assert client.post(
        "/api/auth/register", json={"username": "owner", "password": "password1"}
    ).status_code == 200


# --- metering ----------------------------------------------------------------

def test_pricing_and_usage(conn: object) -> None:
    assert abs(pricing.cost_usd("anthropic/claude-sonnet-5", 1_000_000, 1_000_000) - 12.0) < 1e-9
    assert pricing.cost_usd("unknown/model", 1_000_000, 0) == 2.0  # falls back to Sonnet-class
    assert pricing.WEB_SEARCH_FEE_USD == 0.005

    aid = accounts.register(conn, "owner-m", "password1").id  # type: ignore[arg-type]
    assert usage.over_cap(conn, aid, 10.0) is False  # type: ignore[arg-type]
    c1 = usage.record(conn, aid, "anthropic/claude-haiku-4.5", 1_000_000, 0)  # type: ignore[arg-type]
    assert abs(c1 - 1.0) < 1e-9
    c2 = usage.record(conn, aid, "anthropic/claude-haiku-4.5", 0, 0, extra_cost_usd=0.5)  # type: ignore[arg-type]
    assert abs(c2 - 0.5) < 1e-9
    u = usage.get_usage(conn, aid)  # type: ignore[arg-type]
    assert abs(u.cost_usd - 1.5) < 1e-9 and u.runs == 2
    assert abs(usage.remaining(conn, aid, 10.0) - 8.5) < 1e-9  # type: ignore[arg-type]
    # push over the cap (+$10 -> $11.5)
    usage.record(conn, aid, "anthropic/claude-opus-5", 2_000_000, 0)  # type: ignore[arg-type]
    assert usage.over_cap(conn, aid, 10.0) is True  # type: ignore[arg-type]
    assert usage.remaining(conn, aid, 10.0) == 0.0  # type: ignore[arg-type]


# --- threads -----------------------------------------------------------------

def test_threads_core_and_scoping(conn: object) -> None:
    a = accounts.register(conn, "owner-a", "password1").id  # type: ignore[arg-type]
    b = accounts.register(conn, "owner-b", "password1").id  # type: ignore[arg-type]

    t = threads.create_thread(conn, a)  # type: ignore[arg-type]
    assert t.title is None
    threads.add_message(conn, a, t.id, threads.ROLE_USER, "hello")  # type: ignore[arg-type]
    threads.add_message(conn, a, t.id, threads.ROLE_ASSISTANT, "hi", model="m", cost_usd=0.01)  # type: ignore[arg-type]
    msgs = threads.list_messages(conn, a, t.id)  # type: ignore[arg-type]
    assert [m.role for m in msgs] == ["user", "assistant"]
    assert msgs[1].cost_usd == 0.01 and msgs[1].model == "m"

    # account b cannot see or touch a's thread
    with pytest.raises(NotFound):
        threads.get_thread(conn, b, t.id)  # type: ignore[arg-type]
    with pytest.raises(NotFound):
        threads.add_message(conn, b, t.id, threads.ROLE_USER, "x")  # type: ignore[arg-type]
    with pytest.raises(NotFound):
        threads.list_messages(conn, b, t.id)  # type: ignore[arg-type]

    threads.set_title(conn, a, t.id, "Greeting")  # type: ignore[arg-type]
    items, nxt = threads.list_threads(conn, a)  # type: ignore[arg-type]
    assert len(items) == 1 and items[0].title == "Greeting" and nxt is None
    assert threads.list_threads(conn, b)[0] == []  # type: ignore[arg-type]


# --- tool layer (direct, no network) -----------------------------------------

def test_tool_layer_crud(tmp_path: object) -> None:
    dbp = str(tmp_path / "tools.db")  # type: ignore[operator]
    init_db(dbp)
    with connection(dbp) as c:
        aid = accounts.register(c, "owner-t", "password1").id
    ctx = _ctx(dbp, aid)

    note = json.loads(tools.create_note(ctx, body="buy oat milk"))
    assert note["body"] == "buy oat milk" and note["source"] == "typed"
    found = json.loads(tools.search_notes(ctx, query="milk"))
    assert any("milk" in n["body"] for n in found)
    people = json.loads(tools.list_people(ctx))
    assert sum(person["is_self"] is True for person in people) == 1

    goal = json.loads(tools.create_goal(ctx, title="Ship the app"))
    assert goal["title"] == "Ship the app"
    person = json.loads(tools.upsert_person(ctx, name="Sam", lead_time_minutes=4320))
    assert person["created"] is True and person["delegatee"]["name"] == "Sam"

    asg = json.loads(tools.create_assignment(
        ctx, title="Deep-clean garage", assignee_id=person["delegatee"]["id"], lead_time_minutes=4320,
    ))
    assert asg["title"] == "Deep-clean garage"
    done = json.loads(tools.set_assignment_status(ctx, assignment_id=asg["id"], status="done"))
    assert done["status"] == "done"

    assignments = json.loads(tools.list_assignments(ctx, status="done"))
    assert any(a["id"] == asg["id"] for a in assignments)


def test_agent_can_create_and_update_a_dated_reminder(tmp_path: object) -> None:
    """B1: the in-app agent can create a 'remind me every day until X' reminder (routine rrule
    with UNTIL) and reschedule/retract it — the capability whose absence caused the assistant to
    fabricate a reminder in the operator's chat."""
    dbp = str(tmp_path / "reminder.db")  # type: ignore[operator]
    init_db(dbp)
    with connection(dbp) as c:
        aid = accounts.register(c, "owner-r", "password1").id
    ctx = _ctx(dbp, aid)

    # A daily reminder bounded by an end date — expressible via rrule UNTIL + scheduled_end.
    made = json.loads(tools.create_assignment(
        ctx, title="Take meds", schedule_kind="routine",
        rrule="FREQ=DAILY;UNTIL=20260717T090000Z",
        scheduled_start="2026-07-10T09:00:00Z", scheduled_end="2026-07-17T09:00:00Z",
    ))
    assert "error" not in made, made
    assert made["schedule_kind"] == "routine" and made["scheduled_end"] == "2026-07-17T09:00:00Z"

    # Reschedule via the new update tool, then retract (cancel) — no delete needed.
    moved = json.loads(tools.update_assignment(
        ctx, assignment_id=made["id"], scheduled_start="2026-07-11T08:00:00Z",
    ))
    assert moved["scheduled_start"] == "2026-07-11T08:00:00Z"
    retracted = json.loads(tools.update_assignment(ctx, assignment_id=made["id"], status="cancelled"))
    assert retracted["status"] == "cancelled"


def test_assignment_tools_default_to_account_timezone(tmp_path: object) -> None:
    dbp = str(tmp_path / "assignment-tz.db")  # type: ignore[operator]
    init_db(dbp)
    with connection(dbp) as c:
        aid = accounts.register(c, "owner-assignment-tz", "password1").id
    ctx = _ctx(dbp, aid, "America/New_York")
    made = json.loads(
        tools.create_assignment(
            ctx,
            title="Evening reminder",
            scheduled_start="2026-11-01T21:00:00-05:00",
        )
    )
    assert made["timezone"] == "America/New_York"
    updated = json.loads(tools.update_assignment(ctx, assignment_id=made["id"], title="Evening"))
    assert updated["timezone"] == "America/New_York"


def test_agent_destructive_requires_approval(tmp_path: object) -> None:
    """B2: in-app deletions are gated by the two-call confirm-token flow — no token means no delete."""
    dbp = str(tmp_path / "destructive.db")  # type: ignore[operator]
    init_db(dbp)
    with connection(dbp) as c:
        aid = accounts.register(c, "owner-d", "password1").id
        thread = threads.create_thread(c, aid)
        turn1 = threads.add_message(c, aid, thread.id, threads.ROLE_USER, "delete the one-off")
    ctx = _ctx(dbp, aid)
    ctx.deps.thread_id, ctx.deps.turn_id = thread.id, turn1.id

    asg = json.loads(tools.create_assignment(ctx, title="One-off thing"))
    aid_ = asg["id"]

    # First call: no token → a plan, not a deletion.
    plan = json.loads(tools.delete_assignment(ctx, assignment_id=aid_))
    assert plan["needs_confirm"] is True and plan["confirm_token"] and "One-off thing" in plan["summary"]
    assert any(a["id"] == aid_ for a in json.loads(tools.list_assignments(ctx)))  # still there

    # A bogus token must fail (ConfirmRequired → error), not delete.
    bad = json.loads(tools.delete_assignment(ctx, assignment_id=aid_, confirm_token="nope"))
    assert "error" in bad
    assert any(a["id"] == aid_ for a in json.loads(tools.list_assignments(ctx)))

    # The real token, in the SAME turn, is refused (the user hasn't answered yet)...
    same = json.loads(tools.delete_assignment(ctx, assignment_id=aid_, confirm_token=plan["confirm_token"]))
    assert "NEXT message" in same["error"]
    assert any(a["id"] == aid_ for a in json.loads(tools.list_assignments(ctx)))

    # ...and deletes on the user's next message.
    with connection(dbp) as c:
        turn2 = threads.add_message(c, aid, thread.id, threads.ROLE_USER, "yes")
    ctx.deps.turn_id = turn2.id
    ok = json.loads(tools.delete_assignment(ctx, assignment_id=aid_, confirm_token=plan["confirm_token"]))
    assert ok.get("deleted") is True
    assert not any(a["id"] == aid_ for a in json.loads(tools.list_assignments(ctx)))


def test_agent_cannot_remove_me_actor(tmp_path: object) -> None:
    """B2: the self 'Me' delegatee is protected from removal."""
    dbp = str(tmp_path / "me.db")  # type: ignore[operator]
    init_db(dbp)
    with connection(dbp) as c:
        aid = accounts.register(c, "owner-me", "password1").id
        me = delegatees_core.ensure_self(c, aid).id
    out = json.loads(tools.remove_person(_ctx(dbp, aid), delegatee_id=me))
    assert "error" in out and "Me" in out["error"]


def test_agent_toolset_and_prompt_guardrails() -> None:
    """B1: update_assignment is registered and the system prompt forbids fabricating results."""
    names = {t.__name__ for t in tools.TOOLS}
    assert {"create_assignment", "update_assignment", "set_assignment_status", "fetch_url"} <= names
    assert {"delete_assignment", "delete_activity", "delete_goal", "remove_person"} <= names
    assert "delete_note" not in names  # notes are never deletable (Hard Rule 1)
    prompt = tools.SYSTEM_PROMPT.lower()
    assert "never" in prompt and "fabricate" in prompt
    assert "returned" in prompt  # only report real ids returned by tools
    assert "do push to the user's phone" in prompt
    assert "never ask" in prompt and "timezone" in prompt
    assert "is_self" in prompt and "never create" in prompt
    assert "cannot access the web" in prompt


def test_guard_converts_domain_error_to_json() -> None:
    @tools._guard
    def boom() -> str:
        raise NotFound("missing thing")

    assert json.loads(boom()) == {"error": "missing thing"}


def test_web_search_tool_meters(tmp_path: object, monkeypatch: pytest.MonkeyPatch) -> None:
    from command.core.ai.search import SearchResult

    dbp = str(tmp_path / "ws.db")  # type: ignore[operator]
    init_db(dbp)
    with connection(dbp) as c:
        aid = accounts.register(c, "owner-w", "password1").id
    ctx = _ctx(dbp, aid)

    monkeypatch.setattr(tools, "_ai_web_search", lambda q, **k: SearchResult(
        ok=True, text="Bitcoin is up.", sources=[{"title": "X", "url": "https://x"}],
        model="anthropic/claude-haiku-4.5", input_tokens=200, output_tokens=120, searches=1,
    ))
    out = json.loads(tools.web_search(ctx, "btc price"))
    assert out["answer"] == "Bitcoin is up." and out["sources"][0]["url"] == "https://x"
    assert ctx.deps.meter.searches == 1
    assert ctx.deps.meter.extra_cost_usd > pricing.WEB_SEARCH_FEE_USD  # fee + token cost

    # failure path: no charge, graceful error
    ctx2 = _ctx(dbp, aid)
    monkeypatch.setattr(tools, "_ai_web_search", lambda q, **k: SearchResult(ok=False))
    out2 = json.loads(tools.web_search(ctx2, "x"))
    assert "error" in out2 and ctx2.deps.meter.extra_cost_usd == 0.0


def test_fetch_url_meters(tmp_path: object, monkeypatch: pytest.MonkeyPatch) -> None:
    dbp = str(tmp_path / "fetch.db")  # type: ignore[operator]
    init_db(dbp)
    with connection(dbp) as c:
        aid = accounts.register(c, "owner-fetch", "password1").id
    ctx = _ctx(dbp, aid)
    monkeypatch.setattr(tools, "_fetch_public_url", lambda url: (url, "Readable article text"))
    out = json.loads(tools.fetch_url(ctx, "https://example.com/article"))
    assert out["text"] == "Readable article text"
    assert ctx.deps.meter.extra_cost_usd == pricing.FETCH_URL_FEE_USD


def test_fetch_url_ssrf_guard_rejects_private_and_non_http(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        tools.socket,
        "getaddrinfo",
        lambda *args, **kwargs: [
            (tools.socket.AF_INET, tools.socket.SOCK_STREAM, 6, "", ("127.0.0.1", 80))
        ],
    )
    with pytest.raises(ValueError, match="non-public"):
        tools._validate_public_url("http://example.test/private")
    with pytest.raises(ValueError, match="http or https"):
        tools._validate_public_url("file:///etc/passwd")


def test_html_to_readable_text() -> None:
    parser = tools._ReadableHTML()
    parser.feed("<h1>Title</h1><script>secret()</script><p>Hello <b>world</b>.</p>")
    assert "Title" in parser.text() and "Hello" in parser.text()
    assert "secret" not in parser.text()


# --- model router ------------------------------------------------------------

def test_pick_model_slug_is_weighted() -> None:
    from command.config import get_settings
    from command.core.agent import runner

    s = get_settings()
    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(runner.random, "random", lambda: 0.0)  # below weight -> Claude
        assert runner.pick_model_slug() == s.agent_model_claude
        mp.setattr(runner.random, "random", lambda: 0.999)  # at/above weight -> Fast
        assert runner.pick_model_slug() == s.agent_model_fast


def test_resolve_model_slug() -> None:
    from command.config import get_settings
    from command.core.agent import runner

    s = get_settings()
    assert runner.resolve_model_slug("opus") == s.agent_model_opus
    assert runner.resolve_model_slug("sonnet") == s.agent_model_claude
    assert runner.resolve_model_slug("fast") == s.agent_model_fast
    assert runner.resolve_model_slug("qwen") == s.agent_model_fast  # legacy client alias
    assert runner.resolve_model_slug("glm") == s.agent_model_glm
    assert runner.resolve_model_slug("kimi") == s.agent_model_kimi
    assert runner.resolve_model_slug("gpt") == s.agent_model_gpt
    assert runner.resolve_model_slug("terra") == s.agent_model_gpt  # pre-GPT-6 client alias
    # auto / unknown / None fall through to the weighted router
    for choice in (None, "auto", "banana"):
        assert runner.resolve_model_slug(choice) in {s.agent_model_claude, s.agent_model_fast}


def test_cached_tokens_are_priced_the_way_openrouter_actually_bills() -> None:
    """Pinned to two real OpenRouter responses on Haiku 4.5 ($1/$5 per Mtok), captured
    2026-07-25 with the tool-block breakpoint live. `prompt_tokens` INCLUDES the cached
    portion, so a naive full-rate charge over-bills a cache read by ~6x."""
    from command.core.agent import pricing

    model = "anthropic/claude-haiku-4.5"
    # Cache READ: prompt=5390 of which 5054 cached, 5 output -> OpenRouter charged $0.000866
    read = pricing.cost_usd(model, 5390, 5, cache_read_tokens=5054)
    assert abs(read - 0.000866) < 5e-7, read
    # Cache WRITE (first call): same shape -> OpenRouter charged $0.006679
    write = pricing.cost_usd(model, 5390, 5, cache_write_tokens=5054)
    assert abs(write - 0.006679) < 5e-7, write
    # The naive pricing we'd have used sits between the two and is wrong for both.
    naive = pricing.cost_usd(model, 5390, 5)
    assert read < naive < write
    assert naive / read > 6  # the over-charge a user would have eaten on every cached turn


def test_cache_breakpoint_goes_on_the_last_tool_only() -> None:
    """Anthropic caps breakpoints per request, and everything BEFORE the marked tool
    is what gets cached — so exactly one, on the last entry."""
    from command.core.agent.runner import stamp_cache_breakpoint

    tools = [{"type": "function", "function": {"name": f"t{i}"}} for i in range(3)]
    out = stamp_cache_breakpoint(tools)

    assert out[-1]["cache_control"] == {"type": "ephemeral"}
    assert all("cache_control" not in t for t in out[:-1])
    assert [t["function"]["name"] for t in out] == ["t0", "t1", "t2"]  # order preserved
    assert all("cache_control" not in t for t in tools)  # input not mutated
    assert stamp_cache_breakpoint([]) == []  # a tool-less request is a no-op


def test_system_cache_breakpoint_marks_only_the_static_system_prompt() -> None:
    """system[0] is the static SYSTEM_PROMPT; system[1] is the per-request time preamble.
    Marking [0] caches tools+prompt; marking [1] (or a merged block) would rewrite the
    cache every request and never read one."""
    from command.core.agent.runner import stamp_system_cache_breakpoint

    msgs = [
        {"role": "system", "content": "STATIC PROMPT"},
        {"role": "system", "content": "Current date/time: 2026-08-03T12:00:00."},
        {"role": "user", "content": "hi"},
    ]
    out = stamp_system_cache_breakpoint(msgs)

    assert out[0]["content"] == [
        {"type": "text", "text": "STATIC PROMPT", "cache_control": {"type": "ephemeral"}}
    ]
    assert out[1:] == msgs[1:]  # the volatile preamble and the turn are untouched
    assert msgs[0]["content"] == "STATIC PROMPT"  # input not mutated

    # No system message, already-parts content, and an empty list are all no-ops rather
    # than a crash — a malformed stamp would break every request, not just caching.
    assert stamp_system_cache_breakpoint([]) == []
    user_first = [{"role": "user", "content": "hi"}]
    assert stamp_system_cache_breakpoint(user_first) == user_first
    parts_form = [{"role": "system", "content": [{"type": "text", "text": "x"}]}]
    assert stamp_system_cache_breakpoint(parts_form) == parts_form


async def test_cache_aware_model_stamps_both_breakpoints_on_the_real_wire_shape(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """End-to-end through pydantic-ai's own mapper: the instructions preamble must land in
    its OWN system message after the system prompt. If a future pydantic-ai merged them,
    system[0] would carry the timestamp and the cache would never hit — catch that here."""
    from pydantic_ai.messages import ModelRequest, SystemPromptPart, UserPromptPart
    from pydantic_ai.models import ModelRequestParameters

    from command.config import get_settings
    from command.core.agent.runner import _CacheAwareOpenAIChatModel, _model

    get_settings.cache_clear()
    monkeypatch.setenv("COMMAND_AI_API_KEY", "test-key")  # the SDK rejects an empty key
    try:
        model = _model("anthropic/claude-sonnet-5")
        assert isinstance(model, _CacheAwareOpenAIChatModel)
        request = ModelRequest(
            parts=[SystemPromptPart(content="STATIC PROMPT"), UserPromptPart(content="hi")],
            instructions="Current date/time: 2026-08-03T12:00:00.",
        )
        mapped = await model._map_messages([request], ModelRequestParameters())
    finally:
        get_settings.cache_clear()

    assert mapped[0]["role"] == "system"
    assert mapped[0]["content"][0]["text"] == "STATIC PROMPT"
    assert mapped[0]["content"][0]["cache_control"] == {"type": "ephemeral"}
    # The volatile preamble is a separate, UNSTAMPED system message after the breakpoint.
    assert mapped[1]["role"] == "system"
    assert "Current date/time" in mapped[1]["content"]
    assert not isinstance(mapped[1]["content"], list)


def test_only_anthropic_slugs_get_the_caching_model(monkeypatch: pytest.MonkeyPatch) -> None:
    """Other vendors cache automatically or ignore the key; don't stamp them."""
    from command.config import get_settings
    from command.core.agent.runner import _CacheAwareOpenAIChatModel, _model

    get_settings.cache_clear()
    monkeypatch.setenv("COMMAND_AI_API_KEY", "test-key")  # the SDK rejects an empty key
    try:
        assert isinstance(_model("anthropic/claude-sonnet-5"), _CacheAwareOpenAIChatModel)
        assert not isinstance(_model("z-ai/glm-5.3"), _CacheAwareOpenAIChatModel)
        assert not isinstance(_model("openai/gpt-6-sol"), _CacheAwareOpenAIChatModel)
        monkeypatch.setenv("COMMAND_AGENT_PROMPT_CACHE", "false")
        get_settings.cache_clear()
        assert not isinstance(_model("anthropic/claude-sonnet-5"), _CacheAwareOpenAIChatModel)
    finally:
        get_settings.cache_clear()


def test_every_configured_tier_has_a_pricing_row() -> None:
    """A slug missing from the rate table silently bills at the Sonnet-class default,
    which under-counts Opus by 2.5x and over-counts GLM by ~4x. Catch that here."""
    from command.config import get_settings
    from command.core.agent import pricing

    s = get_settings()
    for slug in (
        s.agent_model_claude, s.agent_model_fast, s.agent_model_opus,
        s.agent_model_glm, s.agent_model_kimi, s.agent_model_gpt,
        s.ai_search_model,
    ):
        assert slug in pricing._RATES, f"{slug} has no pricing row"


# --- vision routing + multimodal prompt --------------------------------------

def test_text_only_tier_falls_back_to_the_multimodal_default_on_image_turns() -> None:
    """GLM is text-only on OpenRouter. An image turn must re-route rather than
    error at the provider — and must NOT re-route when there are no images."""
    from command.config import get_settings
    from command.core.agent import runner

    s = get_settings()
    assert s.agent_model_glm in runner.text_only_slugs()
    assert runner.resolve_model_slug("glm", has_images=False) == s.agent_model_glm
    assert runner.resolve_model_slug("glm", has_images=True) == s.agent_model_claude


def test_every_multimodal_tier_keeps_images_on_its_selected_slug() -> None:
    """Every tier except the text-only ones takes images on its own slug."""
    from command.config import get_settings
    from command.core.agent import runner

    s = get_settings()
    assert runner.resolve_model_slug("fast", has_images=True) == s.agent_model_fast
    assert runner.resolve_model_slug("opus", has_images=True) == s.agent_model_opus
    assert runner.resolve_model_slug("sonnet", has_images=True) == s.agent_model_claude
    assert runner.resolve_model_slug("kimi", has_images=True) == s.agent_model_kimi
    assert runner.resolve_model_slug("gpt", has_images=True) == s.agent_model_gpt
    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(runner.random, "random", lambda: 0.999)  # auto -> Fast/Haiku
        assert runner.resolve_model_slug("auto", has_images=True) == s.agent_model_fast
        assert runner.resolve_model_slug("auto", has_images=False) == s.agent_model_fast


def test_dynamic_run_context_uses_account_timezone(tmp_path: object) -> None:
    from command.core.agent import runner

    dbp = str(tmp_path / "tz.db")  # type: ignore[operator]
    init_db(dbp)
    with connection(dbp) as c:
        aid = accounts.register(c, "owner-tz", "password1").id
        accounts.set_timezone(c, aid, "America/New_York")
    deps, preamble = runner._run_context(dbp, aid)
    assert deps.account_timezone == "America/New_York"
    assert "Current date/time:" in preamble and "User timezone: America/New_York." in preamble


def test_tool_done_entity_summary() -> None:
    from command.core.agent import runner

    assert runner._tool_entity(
        "create_assignment", '{"id": 42, "title": "Saffron milk"}'
    ) == {"kind": "assignment", "id": 42, "label": "Saffron milk"}
    assert runner._tool_entity(
        "upsert_person", '{"delegatee":{"id":7,"name":"Sam"},"created":true}'
    ) == {"kind": "person", "id": 7, "label": "Sam"}
    assert runner._tool_entity("search_notes", "[]") is None
    assert runner._tool_entity("create_goal", '{"error":"failed"}') is None


def test_user_prompt_multimodal() -> None:
    from pydantic_ai import BinaryContent

    from command.core.agent import runner

    # No images -> plain string (unchanged behavior).
    assert runner._user_prompt("hello", None) == "hello"
    assert runner._user_prompt("hello", []) == "hello"

    # With images -> [text, BinaryContent...] so the model reads the pixels.
    prompt = runner._user_prompt("what's this?", [(b"\xff\xd8\xff", "image/jpeg")])
    assert isinstance(prompt, list)
    assert prompt[0] == "what's this?"
    assert isinstance(prompt[1], BinaryContent) and prompt[1].media_type == "image/jpeg"

    # Image-only turn (empty text) -> just the image part, no empty string.
    only = runner._user_prompt("", [(b"\x89PNG", "image/png")])
    assert isinstance(only, list) and len(only) == 1 and isinstance(only[0], BinaryContent)


# --- image input validation (no model call) ----------------------------------

def test_decode_images_validation() -> None:
    import base64

    from command.rest.agent import MAX_IMAGES, ChatImage, _decode_images

    good = base64.b64encode(b"\xff\xd8\xff\xe0jpegbytes").decode()

    # Happy path: decodes to (bytes, media_type).
    decoded, err = _decode_images([ChatImage(media_type="image/jpeg", data=good)])
    assert err is None and decoded[0][1] == "image/jpeg" and decoded[0][0].startswith(b"\xff\xd8")

    # Unsupported type.
    _, err = _decode_images([ChatImage(media_type="image/tiff", data=good)])
    assert err is not None and "Unsupported" in err

    # Not valid base64.
    _, err = _decode_images([ChatImage(media_type="image/png", data="!!!not base64!!!")])
    assert err is not None and "base64" in err

    # Too many images.
    many = [ChatImage(media_type="image/png", data=good)] * (MAX_IMAGES + 1)
    _, err = _decode_images(many)
    assert err is not None and "at most" in err


def test_chat_rejects_bad_image(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    """An invalid attachment is reported as an SSE error before any model call."""
    _auth(client)
    from command.config import get_settings

    monkeypatch.setattr(get_settings(), "ai_api_key", "test-key-not-real")
    r = client.post("/api/agent/chat", json={
        "message": "look", "images": [{"media_type": "image/heic", "data": "Zm9v"}],
    })
    assert r.status_code == 200 and "Unsupported image type" in r.text


# --- REST surface: reads + pre-run gates (no model call) ---------------------

def test_usage_endpoint_starts_empty(client: TestClient) -> None:
    _auth(client)
    u = client.get("/api/agent/usage").json()
    assert u["cost_usd"] == 0 and u["runs"] == 0
    assert u["cap_usd"] == 10.0 and u["remaining_usd"] == 10.0


def test_threads_endpoints(client: TestClient) -> None:
    _auth(client)
    assert client.get("/api/agent/threads").json()["items"] == []
    assert client.get("/api/agent/threads/999").status_code == 404


def test_agent_endpoints_require_auth(client: TestClient) -> None:
    assert client.get("/api/agent/usage").status_code == 401
    assert client.get("/api/agent/threads").status_code == 401
    assert client.post("/api/agent/chat", json={"message": "hi"}).status_code == 401


def test_chat_requires_config(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    _auth(client)
    from command.config import get_settings

    monkeypatch.setattr(get_settings(), "ai_api_key", None)
    r = client.post("/api/agent/chat", json={"message": "hi"})
    assert r.status_code == 200 and "isn't configured" in r.text


def test_chat_requires_consent(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    """/chat refuses before any model call when AI-disclosure consent isn't recorded — a
    server-side backstop for the Apple requirement, independent of the app's own gate (E5)."""
    _auth(client)
    from command.config import get_settings

    monkeypatch.setattr(get_settings(), "ai_api_key", "test-key-not-real")
    r = client.post("/api/agent/chat", json={"message": "hi"})
    assert r.status_code == 200 and "consent_required" in r.text


def test_errored_run_still_meters_spend(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    """A run that bills tokens/web fees then errors mid-stream must still be metered
    against the cap — the terminal event always carries usage, even on error (E1)."""
    _auth(client)
    from command.config import get_settings
    from command.core import entitlements
    from command.core.agent import runner

    s = get_settings()
    monkeypatch.setattr(s, "ai_api_key", "test-key-not-real")
    with connection(s.db_path) as conn:
        aid = conn.execute("SELECT id FROM accounts WHERE username = 'owner'").fetchone()[0]
        entitlements.record_consent(conn, aid)

    async def fake_stream(*args: object, **kwargs: object):  # type: ignore[no-untyped-def]
        yield {"type": "start", "model": "anthropic/claude-opus-5"}
        yield {
            "type": "tool_done",
            "name": "create_assignment",
            "entity": {"kind": "assignment", "id": 42, "label": "Saffron milk"},
        }
        yield {
            "type": "done", "output": "", "model": "anthropic/claude-opus-5",
            "input_tokens": 2000, "output_tokens": 400, "extra_cost_usd": 0.01,
            "searches": 1, "error": "The agent hit an error. Please try again.",
        }

    monkeypatch.setattr(runner, "stream", fake_stream)
    r = client.post("/api/agent/chat", json={"message": "hi"})
    assert r.status_code == 200 and "error" in r.text
    assert '"entity": {"kind": "assignment", "id": 42, "label": "Saffron milk"}' in r.text
    with connection(s.db_path) as conn:
        u = usage.get_usage(conn, aid)
    assert u.cost_usd > 0 and u.runs == 1  # errored, but the spend was recorded


def test_chat_enforces_cap(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    _auth(client)
    from command.config import get_settings

    s = get_settings()
    monkeypatch.setattr(s, "ai_api_key", "test-key-not-real")  # pass the configured gate
    with connection(s.db_path) as conn:
        aid = conn.execute("SELECT id FROM accounts WHERE username = 'owner'").fetchone()[0]
        entitlements.record_consent(conn, aid)  # consent precedes the cap gate
        usage.record(conn, aid, "anthropic/claude-opus-5", 4_000_000, 0)  # $20 > $10 cap
    r = client.post("/api/agent/chat", json={"message": "hello"})
    assert r.status_code == 200
    assert "cap_reached" in r.text and "data:" in r.text
