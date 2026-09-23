"""The system prompt is the only thing that tells the agent WHEN to use its 38 tools.

Two failure modes this guards, both silent:

1. A tool ships, nothing mentions it, and the model never reaches for it. The capability
   exists in the codebase and not in the product.
2. The prompt names a tool that has been renamed or removed, so the model is instructed to
   call something that does not exist and burns a turn discovering that.

The prompt is also NOT prompt-cached — the cache breakpoint sits on the last tool, and a
per-second timestamp is rendered into the system message (see runner.stamp_cache_breakpoint
and commit 550f6d8). Every token here is paid at full price on every request of every
conversation, so its size is a real running cost, not a style question.
"""

from __future__ import annotations

import re

from command.core.agent import tools as T


def _tool_names() -> set[str]:
    return {t.__name__ for t in T.TOOLS}


def test_every_tool_the_prompt_names_actually_exists() -> None:
    """A prompt that instructs the model to call a nonexistent tool wastes a live turn."""
    referenced = set(re.findall(r"\b([a-z][a-z0-9_]{4,})\b", T.SYSTEM_PROMPT))
    # Only consider words that look like our tool names (contain an underscore).
    candidates = {w for w in referenced if "_" in w}
    known = _tool_names() | {
        # Non-tool identifiers the prompt legitimately mentions.
        "schedule_kind", "scheduled_start", "scheduled_end", "lead_time_minutes",
        "confirm_token", "is_self", "task_items",
        "recent_notes",   # search_notes' labelled no-match payload

    }
    unknown = candidates - known
    assert not unknown, f"prompt references unknown identifiers: {sorted(unknown)}"


def test_the_highest_value_capabilities_are_advertised() -> None:
    """Each of these was invisible to the model until the prompt named it — they are the ones
    whose absence silently changes what the product can do."""
    for tool in (
        "get_calendar",              # the assistant was blind to the calendar entirely
        "find_free_time",
        "find_conflicts",
        "find_stale_assignments",    # "what needs chasing"
        "triage_unprocessed_notes",  # the planning entry point
        "mark_note_processed",       # closes the loop; without it notes resurface forever
        "search_people",             # check-before-create, or the roster grows duplicates
        "read_attachment",
    ):
        assert tool in T.SYSTEM_PROMPT, f"{tool} exists but the prompt never tells the model to use it"


def test_the_honesty_rules_survive_editing() -> None:
    """These are the guardrails against the agent claiming work it never did. Any prompt edit
    that drops them is a regression regardless of what it adds."""
    lowered = T.SYSTEM_PROMPT.lower()
    assert "never claim you created" in lowered
    assert "cannot delete the user's notes" in lowered
    assert "confirm_token" in T.SYSTEM_PROMPT


def test_prompt_stays_within_a_sane_budget() -> None:
    """Uncached and re-sent every request. A prompt that grows without limit is a permanent
    tax on every conversation; this is a tripwire, not a hard design limit."""
    approx_tokens = len(T.SYSTEM_PROMPT) // 4
    assert approx_tokens < 1500, (
        f"system prompt is ~{approx_tokens} tokens and is paid on EVERY request. "
        "Trim it, or move stable guidance behind the tool-schema cache breakpoint."
    )
