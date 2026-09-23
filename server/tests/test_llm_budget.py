"""The LLM-spend guard for proactive work.

Operator requirement (2026-08-02): a user who stops engaging must stop costing money.
Anything that spends LLM tokens on their behalf without them asking is capped at N sends
since they last opened the app; opening it resets the counter; N is env-tunable so it can
be retuned without a code change.

Scope is deliberately "anything that uses an LLM", NOT all pushes. A plain reminder is a
template push with no model call, so a dormant account with a recurring assignment costs
nothing worth guarding — capping those would silence real reminders for no saving. Hence
`llm_sends_since_open`: the column name states what it counts so nobody wires a template
push into it later.
"""

from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts as accounts_core
from command.core import llm_budget


def _acct(conn: sqlite3.Connection, name: str = "owner") -> int:
    return accounts_core.register(conn, name, "password1").id


def test_a_fresh_account_has_headroom(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    assert llm_budget.may_spend(conn, aid, cap=30) is True
    assert llm_budget.sends_since_open(conn, aid) == 0


def test_each_send_consumes_headroom(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    for _ in range(3):
        llm_budget.record_send(conn, aid)
    assert llm_budget.sends_since_open(conn, aid) == 3
    assert llm_budget.may_spend(conn, aid, cap=30) is True


def test_the_cap_is_enforced_at_the_boundary(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    for _ in range(29):
        llm_budget.record_send(conn, aid)
    assert llm_budget.may_spend(conn, aid, cap=30) is True, "29 sends is still under a cap of 30"
    llm_budget.record_send(conn, aid)
    assert llm_budget.sends_since_open(conn, aid) == 30
    assert llm_budget.may_spend(conn, aid, cap=30) is False, "the 30th send exhausts a cap of 30"


def test_opening_the_app_resets_the_counter(conn: sqlite3.Connection) -> None:
    """The whole point: engagement buys back the budget."""
    aid = _acct(conn)
    for _ in range(30):
        llm_budget.record_send(conn, aid)
    assert llm_budget.may_spend(conn, aid, cap=30) is False

    llm_budget.record_open(conn, aid)

    assert llm_budget.sends_since_open(conn, aid) == 0
    assert llm_budget.may_spend(conn, aid, cap=30) is True


def test_open_is_recorded_even_with_no_prior_sends(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    llm_budget.record_open(conn, aid)
    state = llm_budget.get_state(conn, aid)
    assert state.last_open_at is not None
    assert state.llm_sends_since_open == 0


def test_the_cap_is_configurable_not_hard_coded(conn: sqlite3.Connection) -> None:
    """The operator must be able to retune this without a code change."""
    aid = _acct(conn)
    for _ in range(5):
        llm_budget.record_send(conn, aid)
    assert llm_budget.may_spend(conn, aid, cap=5) is False
    assert llm_budget.may_spend(conn, aid, cap=50) is True


def test_a_cap_of_zero_disables_proactive_spend_entirely(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    assert llm_budget.may_spend(conn, aid, cap=0) is False


def test_a_negative_cap_means_unlimited(conn: sqlite3.Connection) -> None:
    """An explicit escape hatch for a self-hosted instance that does not want the guard."""
    aid = _acct(conn)
    for _ in range(1000):
        llm_budget.record_send(conn, aid)
    assert llm_budget.may_spend(conn, aid, cap=-1) is True


def test_accounts_are_independent(conn: sqlite3.Connection) -> None:
    a = _acct(conn, "one")
    b = _acct(conn, "two")
    for _ in range(30):
        llm_budget.record_send(conn, a)
    assert llm_budget.may_spend(conn, a, cap=30) is False
    assert llm_budget.may_spend(conn, b, cap=30) is True


def test_settings_expose_a_tunable_cap() -> None:
    from command.config import Settings

    assert Settings().max_llm_sends_before_open == 30


def test_settings_cap_is_env_overridable(monkeypatch: pytest.MonkeyPatch) -> None:
    from command.config import Settings

    monkeypatch.setenv("COMMAND_MAX_LLM_SENDS_BEFORE_OPEN", "7")
    assert Settings().max_llm_sends_before_open == 7


# ---------- the gate that must not lock out self-hosters ----------


def test_can_use_agent_mirrors_the_chat_gate(conn: sqlite3.Connection) -> None:
    """`agent_require_subscription` defaults FALSE. Gating proactive work on is_active()
    alone would mean every self-hosted instance silently never gets a briefing."""
    from command.core import entitlements

    aid = _acct(conn)
    entitlements.record_consent(conn, aid)

    # Self-hosted posture: no subscription required, nobody is "subscribed".
    assert entitlements.can_use_agent(conn, aid, require_subscription=False) is True
    # Hosted posture: subscription required and absent.
    assert entitlements.can_use_agent(conn, aid, require_subscription=True) is False


def test_can_use_agent_requires_consent_either_way(conn: sqlite3.Connection) -> None:
    """AI disclosure gates first use regardless of billing — Apple requires it before any
    user data reaches a third-party model."""
    from command.core import entitlements

    aid = _acct(conn)  # no consent recorded
    assert entitlements.can_use_agent(conn, aid, require_subscription=False) is False
    assert entitlements.can_use_agent(conn, aid, require_subscription=True) is False


def test_can_use_agent_allows_an_entitled_account(conn: sqlite3.Connection) -> None:
    from command.core import entitlements

    aid = _acct(conn)
    entitlements.record_consent(conn, aid)
    entitlements.grant_comp(conn, aid)
    assert entitlements.can_use_agent(conn, aid, require_subscription=True) is True
