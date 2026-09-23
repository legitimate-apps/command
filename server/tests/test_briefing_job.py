"""The briefing sweep — where every gate has to actually bite.

This is the money path. Each guard below exists because skipping it costs the operator real
spend on someone who is not reading the result, so each gets its own test rather than being
covered incidentally.

Order matters: the budget and entitlement checks run BEFORE the digest is built and before
any model is touched, so an ineligible account never reaches the expensive part.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import briefing_job, briefings, entitlements, llm_budget, push

# Monday 09:00 UTC. These tests exercise the job's GATES (entitlement, budget, devices, one
# per day), so the instant only has to be one where the cadence itself says yes: at or after
# the default hour_local=8 and inside `briefings.CATCHUP_HOURS`. It used to be 12:00, which is
# exactly the first hour that window excludes — cadence said "not due" and five gate tests
# failed for a reason that had nothing to do with what they were testing.
T0 = datetime(2026, 8, 3, 9, 0, 0, tzinfo=UTC)


class _Sender:
    """Records sends instead of talking to APNs."""

    def __init__(self) -> None:
        self.sent: list[tuple[str, str]] = []

    def __call__(self, token: str, *, title: str, body: str, environment: str = "sandbox"):
        self.sent.append((title, body))

        class _R:
            ok = True
            unregistered = False

        return _R()


def _ready_account(conn: sqlite3.Connection, name: str = "owner") -> int:
    """An account that SHOULD receive a briefing: consented, opted in, with a device and
    something worth saying."""
    aid = accounts_core.register(conn, name, "password1").id
    entitlements.record_consent(conn, aid)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
    push.register(conn, aid, token="a" * 64, environment="sandbox")
    A.create(conn, aid, title="Dentist",
             scheduled_start="2026-08-03T14:00:00+00:00",
             scheduled_end="2026-08-03T15:00:00+00:00")
    return aid


def _run(conn: sqlite3.Connection, aid: int, sender: _Sender, *, cap: int = 30) -> bool:
    return briefing_job.send_briefing_if_due(
        conn, aid, now=T0, sender=sender, cap=cap, require_subscription=False
    )


def test_a_ready_account_gets_its_briefing(conn: sqlite3.Connection) -> None:
    aid = _ready_account(conn)
    sender = _Sender()
    assert _run(conn, aid, sender) is True
    assert len(sender.sent) == 1
    assert "Dentist" in sender.sent[0][1] or "on today" in sender.sent[0][1]


def test_a_send_consumes_llm_budget(conn: sqlite3.Connection) -> None:
    aid = _ready_account(conn)
    assert llm_budget.sends_since_open(conn, aid) == 0
    _run(conn, aid, _Sender())
    assert llm_budget.sends_since_open(conn, aid) == 1


def test_an_exhausted_budget_blocks_the_briefing(conn: sqlite3.Connection) -> None:
    """The churn guard. Checked before generating, so nothing expensive happens."""
    aid = _ready_account(conn)
    for _ in range(30):
        llm_budget.record_send(conn, aid)
    sender = _Sender()
    assert _run(conn, aid, sender) is False
    assert sender.sent == []


def test_opening_the_app_restores_the_briefing(conn: sqlite3.Connection) -> None:
    aid = _ready_account(conn)
    for _ in range(30):
        llm_budget.record_send(conn, aid)
    assert _run(conn, aid, _Sender()) is False
    llm_budget.record_open(conn, aid)
    assert _run(conn, aid, _Sender()) is True


def test_disabled_preferences_block_the_briefing(conn: sqlite3.Connection) -> None:
    aid = _ready_account(conn)
    briefings.set_prefs(conn, aid, {"enabled": False})
    assert _run(conn, aid, _Sender()) is False


def test_missing_consent_blocks_the_briefing(conn: sqlite3.Connection) -> None:
    """No user data reaches a model before the AI disclosure is accepted."""
    aid = accounts_core.register(conn, "noconsent", "password1").id
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
    push.register(conn, aid, token="b" * 64, environment="sandbox")
    A.create(conn, aid, title="Thing", scheduled_start="2026-08-03T14:00:00+00:00")
    assert _run(conn, aid, _Sender()) is False


def test_subscription_gate_blocks_when_required(conn: sqlite3.Connection) -> None:
    aid = _ready_account(conn)
    sender = _Sender()
    assert briefing_job.send_briefing_if_due(
        conn, aid, now=T0, sender=sender, cap=30, require_subscription=True
    ) is False
    assert sender.sent == []


def test_self_hosted_posture_still_gets_briefings(conn: sqlite3.Connection) -> None:
    """require_subscription=False is the self-hosted default; nobody there is subscribed and
    they must still be served."""
    aid = _ready_account(conn)
    assert entitlements.is_active(conn, aid) is False
    assert _run(conn, aid, _Sender()) is True


def test_nothing_to_say_means_no_notification(conn: sqlite3.Connection) -> None:
    """An empty day must not spend budget or buzz the phone."""
    aid = accounts_core.register(conn, "quiet", "password1").id
    entitlements.record_consent(conn, aid)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
    push.register(conn, aid, token="c" * 64, environment="sandbox")
    sender = _Sender()
    assert _run(conn, aid, sender) is False
    assert sender.sent == []
    assert llm_budget.sends_since_open(conn, aid) == 0, "an empty digest must not cost budget"


def test_no_device_no_send(conn: sqlite3.Connection) -> None:
    aid = accounts_core.register(conn, "nodevice", "password1").id
    entitlements.record_consent(conn, aid)
    briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
    A.create(conn, aid, title="Thing", scheduled_start="2026-08-03T14:00:00+00:00")
    assert _run(conn, aid, _Sender()) is False


def test_only_one_briefing_per_day(conn: sqlite3.Connection) -> None:
    aid = _ready_account(conn)
    assert _run(conn, aid, _Sender()) is True
    assert _run(conn, aid, _Sender()) is False, "the sweep runs constantly; don't re-send"
    assert llm_budget.sends_since_open(conn, aid) == 1


def test_the_sent_marker_uses_the_clock_the_decision_used(conn: sqlite3.Connection) -> None:
    """The dedupe marker must be stamped from `now`, not from a fresh wall-clock reading.

    `is_due` compares this marker's local date against `now`'s local date, so sourcing the two
    from different clocks lets one guard be decided by a value nothing else in the function
    agreed to. In production that costs a whole briefing: with `hour_local=23` a send at
    23:59:59.9 stamps tomorrow's local date and suppresses tomorrow's send.

    Asserted directly on the stored value, because the symptom is only visible through
    `test_only_one_briefing_per_day` on days when the real date differs from the injected one —
    that test passed for a full day and started failing at midnight, which is the worst way for
    a suite to tell you something is wrong.
    """
    aid = _ready_account(conn)
    assert _run(conn, aid, _Sender()) is True
    stored = briefing_job._last_sent_at(conn, aid)
    assert stored is not None, "a delivered briefing must record when it went"
    assert datetime.fromisoformat(stored) == T0
