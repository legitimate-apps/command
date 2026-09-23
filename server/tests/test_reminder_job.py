"""The reminder-delivery job (B4): due reminders push once, dedup holds, dead tokens are pruned."""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta

from command.core import apns, push, reminder_job
from command.core import assignments as A
from command.db import connect, init_db
from tests.test_assignments import _acct


class FakeSender:
    def __init__(self, *, unregistered: bool = False, ok: bool = True):
        self.calls: list[tuple[str, str]] = []
        self._unreg = unregistered
        self._ok = ok

    def __call__(self, token, *, title, body, environment="production"):
        self.calls.append((token, body))
        if self._unreg:
            return apns.PushResult(ok=False, status=410, reason="Unregistered", unregistered=True)
        return apns.PushResult(ok=self._ok, status=200 if self._ok else 500)


def _due_assignment(conn: sqlite3.Connection, aid: int, now: datetime) -> int:
    # A one-off scheduled 30 min from now with a 60-min lead → remind_at is already past (due).
    a = A.create(
        conn, aid, title="Call the dentist",
        scheduled_start=(now + timedelta(minutes=30)).isoformat(),
        lead_time_minutes=60,
    )
    return a.id


def test_due_reminder_pushes_once_and_dedups(conn: sqlite3.Connection) -> None:
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    _due_assignment(conn, aid, now)
    push.register(conn, aid, "TOKEN_A", environment="sandbox")
    sender = FakeSender()

    sent = reminder_job.send_account_reminders(conn, aid, now=now, sender=sender)
    assert sent == 1 and sender.calls == [("TOKEN_A", "Call the dentist")]

    # A second sweep sends nothing (already marked sent).
    sent2 = reminder_job.send_account_reminders(conn, aid, now=now, sender=sender)
    assert sent2 == 0 and len(sender.calls) == 1


def test_zero_lead_self_reminder_pushes_once_at_its_time(conn: sqlite3.Connection) -> None:
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    me = conn.execute(
        "SELECT id FROM delegatees WHERE account_id = ? AND is_self = 1", (aid,)
    ).fetchone()[0]
    A.create(
        conn, aid, title="Drink water", assignee_id=me, scheduled_start=now.isoformat()
    )
    push.register(conn, aid, "SELF_TOKEN", environment="sandbox")
    sender = FakeSender()

    # The scheduler's poll can land after the exact instant; the bounded lookback still finds it.
    poll_time = now + timedelta(seconds=30)
    assert reminder_job.send_account_reminders(conn, aid, now=poll_time, sender=sender) == 1
    assert sender.calls == [("SELF_TOKEN", "Drink water")]
    assert reminder_job.send_account_reminders(conn, aid, now=poll_time, sender=sender) == 0


def test_no_tokens_no_send(conn: sqlite3.Connection) -> None:
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    _due_assignment(conn, aid, now)
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=FakeSender()) == 0


def test_unregistered_token_is_pruned(conn: sqlite3.Connection) -> None:
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    _due_assignment(conn, aid, now)
    push.register(conn, aid, "DEAD", environment="production")
    reminder_job.send_account_reminders(conn, aid, now=now, sender=FakeSender(unregistered=True))
    assert push.list_tokens(conn, aid) == []  # dead token removed


def test_future_reminder_not_yet_due(conn: sqlite3.Connection) -> None:
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    # scheduled far out with a tiny lead → remind_at is in the future → not due.
    A.create(conn, aid, title="Later", scheduled_start=(now + timedelta(days=5)).isoformat(),
             lead_time_minutes=10)
    push.register(conn, aid, "T", environment="sandbox")
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=FakeSender()) == 0


def test_failed_delivery_is_retried_and_only_then_recorded(conn: sqlite3.Connection) -> None:
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    _due_assignment(conn, aid, now)
    push.register(conn, aid, "RETRY_TOKEN", environment="sandbox")

    failed = FakeSender(ok=False)
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=failed) == 0
    assert conn.execute("SELECT COUNT(*) FROM sent_reminders").fetchone()[0] == 0

    working = FakeSender()
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=working) == 1
    assert conn.execute("SELECT COUNT(*) FROM sent_reminders").fetchone()[0] == 1
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=working) == 0
    assert working.calls == [("RETRY_TOKEN", "Call the dentist")]


def test_same_assignment_occurrences_on_same_day_each_send(conn: sqlite3.Connection) -> None:
    now = datetime(2026, 7, 10, 22, 0, tzinfo=UTC)
    aid = _acct(conn)
    A.create(
        conn,
        aid,
        title="Twice daily",
        schedule_kind="routine",
        rrule="FREQ=DAILY;BYHOUR=9,21;BYMINUTE=0;BYSECOND=0",
        scheduled_start="2026-07-10T09:00:00+00:00",
    )
    push.register(conn, aid, "TWICE_TOKEN", environment="sandbox")
    sender = FakeSender()

    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=sender) == 2
    keys = conn.execute(
        "SELECT occurrence_date FROM sent_reminders ORDER BY occurrence_date"
    ).fetchall()
    assert [row[0] for row in keys] == [
        "2026-07-10T09:00:00+00:00",
        "2026-07-10T21:00:00+00:00",
    ]


def test_run_once_continues_after_one_accounts_sender_raises(tmp_path) -> None:
    db_path = str(tmp_path / "reminder-job.db")
    init_db(db_path)
    conn = connect(db_path)
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    try:
        account_ids = [_acct(conn, name) for name in ("first", "middle", "last")]
        for account_id, token in zip(account_ids, ("FIRST", "MIDDLE", "LAST"), strict=True):
            _due_assignment(conn, account_id, now)
            push.register(conn, account_id, token, environment="sandbox")
        conn.commit()
    finally:
        conn.close()

    calls: list[str] = []

    def sender(token, *, title, body, environment="production"):
        calls.append(token)
        if token == "MIDDLE":
            raise RuntimeError("simulated account-specific sender failure")
        return apns.PushResult(ok=True, status=200)

    assert reminder_job.run_once(db_path, now=now, sender=sender) == 2
    assert calls == ["FIRST", "MIDDLE", "LAST"]
    conn = connect(db_path)
    try:
        assert conn.execute("SELECT COUNT(*) FROM sent_reminders").fetchone()[0] == 2
    finally:
        conn.close()


def _due_assigned(conn: sqlite3.Connection, aid: int, now: datetime, assignee_id: int) -> int:
    a = A.create(
        conn, aid, title="Water the plants",
        scheduled_start=(now + timedelta(minutes=30)).isoformat(),
        lead_time_minutes=60,
        assignee_id=assignee_id,
    )
    return a.id


def test_delegatee_devices_only_get_their_own_assignments(conn: sqlite3.Connection) -> None:
    from command.core import delegatees as D

    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    helper, _ = D.upsert(conn, aid, name="Helper")
    other, _ = D.upsert(conn, aid, name="Other")
    _due_assignment(conn, aid, now)                    # unassigned → operator only
    _due_assigned(conn, aid, now, helper.id)           # helper's → operator + helper
    push.register(conn, aid, "OPERATOR", environment="sandbox")
    push.register(conn, aid, "HELPER", environment="sandbox", delegatee_id=helper.id)
    push.register(conn, aid, "OTHER", environment="sandbox", delegatee_id=other.id)
    sender = FakeSender()

    sent = reminder_job.send_account_reminders(conn, aid, now=now, sender=sender)
    assert sent == 2
    # Operator sees both; helper sees only theirs; the other delegatee sees nothing.
    got = {}
    for token, body in sender.calls:
        got.setdefault(token, []).append(body)
    assert sorted(got["OPERATOR"]) == ["Call the dentist", "Water the plants"]
    assert got["HELPER"] == ["Water the plants"]
    assert "OTHER" not in got


def test_delegatee_only_devices_still_deliver(conn: sqlite3.Connection) -> None:
    from command.core import delegatees as D

    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    helper, _ = D.upsert(conn, aid, name="Helper")
    _due_assigned(conn, aid, now, helper.id)
    push.register(conn, aid, "HELPER", environment="sandbox", delegatee_id=helper.id)
    sender = FakeSender()
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=sender) == 1
    assert sender.calls == [("HELPER", "Water the plants")]


def test_revoke_and_regenerate_drop_delegatee_tokens(conn: sqlite3.Connection) -> None:
    from command.core import accounts as ACC
    from command.core import delegatee_access
    from command.core import delegatees as D

    account = ACC.register(conn, "owner-tokens", "password1")
    helper, _ = D.upsert(conn, account.id, name="Helper")
    delegatee_access.create_invite(conn, account.id, helper.id)
    push.register(conn, account.id, "OPERATOR")
    push.register(conn, account.id, "HELPER", delegatee_id=helper.id)

    delegatee_access.revoke_invite(conn, account.id, helper.id)
    left = [t.token for t in push.list_tokens(conn, account.id)]
    assert left == ["OPERATOR"]

    # Regenerating an invite also invalidates previously registered delegatee devices.
    delegatee_access.create_invite(conn, account.id, helper.id)
    push.register(conn, account.id, "HELPER2", delegatee_id=helper.id)
    delegatee_access.create_invite(conn, account.id, helper.id)
    left = [t.token for t in push.list_tokens(conn, account.id)]
    assert left == ["OPERATOR"]


def test_an_occurrence_marked_skipped_is_not_pushed(conn: sqlite3.Connection) -> None:
    """Marking an occurrence `skipped` is the user saying "I'm not doing this one". Pushing
    "Reminder: <title>" at its scheduled instant anyway is arguing with them.

    `upcoming_reminders` used to exclude only done/cancelled, and the delivery job pushes
    whatever it returns with `due` — nothing downstream re-checked the status, so this fired.
    """
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    assignment_id = _due_assignment(conn, aid, now)
    push.register(conn, aid, "TOKEN_A", environment="sandbox")

    occurrences = A.calendar(
        conn, aid,
        (now - timedelta(days=1)).isoformat(),
        (now + timedelta(days=1)).isoformat(),
    )
    target = next(o for o in occurrences if o.assignment_id == assignment_id)
    assert target.occurrence_date is not None
    A.set_occurrence_status(conn, aid, assignment_id, target.occurrence_date, "skipped")

    sender = FakeSender()
    sent = reminder_job.send_account_reminders(conn, aid, now=now, sender=sender)
    assert sent == 0, "a skipped occurrence must not notify"
    assert sender.calls == []


def test_a_blocked_occurrence_still_pushes(conn: sqlite3.Connection) -> None:
    """The mirror of the above, so the fix doesn't over-reach. `blocked` is unresolved work —
    being reminded of it is the entire point, and it must stay out of INACTIVE_STATUSES."""
    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    assignment_id = _due_assignment(conn, aid, now)
    push.register(conn, aid, "TOKEN_A", environment="sandbox")

    occurrences = A.calendar(
        conn, aid,
        (now - timedelta(days=1)).isoformat(),
        (now + timedelta(days=1)).isoformat(),
    )
    target = next(o for o in occurrences if o.assignment_id == assignment_id)
    assert target.occurrence_date is not None
    A.set_occurrence_status(conn, aid, assignment_id, target.occurrence_date, "blocked")

    sender = FakeSender()
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=sender) == 1
    assert sender.calls == [("TOKEN_A", "Call the dentist")]


def test_a_deactivated_delegatee_stops_receiving_pushes(conn: sqlite3.Connection) -> None:
    """Deactivating someone is how you cut off a contractor who has left.

    It already blocked their API access — `delegatee_for_session` requires `d.active = 1` —
    but nothing cut their PUSH. Device tokens are only deleted on invite revoke/regenerate,
    and deactivation goes through `delegatees.upsert`, a different path reachable from both
    the app and the agent. So their phone kept showing the titles of assignments still
    assigned to them, indefinitely, after they had been switched off.
    """
    from command.core import delegatees as D

    now = datetime(2026, 7, 10, 9, 0, tzinfo=UTC)
    aid = _acct(conn)
    helper, _ = D.upsert(conn, aid, name="Helper")
    _due_assigned(conn, aid, now, helper.id)
    push.register(conn, aid, "OPERATOR", environment="sandbox")
    push.register(conn, aid, "HELPER", environment="sandbox", delegatee_id=helper.id)

    # While active, they get their own assignment (the behaviour we must not break).
    sender = FakeSender()
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=sender) == 1
    assert {t for t, _ in sender.calls} == {"OPERATOR", "HELPER"}

    # Deactivate through the ordinary path — same slug, active=False — and re-arm delivery by
    # clearing the send-once ledger so the only variable is the delegatee's active flag.
    D.upsert(conn, aid, name="Helper", slug=helper.slug, active=False)
    conn.execute("DELETE FROM sent_reminders")

    sender2 = FakeSender()
    assert reminder_job.send_account_reminders(conn, aid, now=now, sender=sender2) == 1
    recipients = {t for t, _ in sender2.calls}
    assert "HELPER" not in recipients, "a deactivated delegatee must stop being notified"
    assert recipients == {"OPERATOR"}, "the operator's own safety-net copy still arrives"

    # Reactivating resumes delivery without the device having to re-register.
    D.upsert(conn, aid, name="Helper", slug=helper.slug, active=True)
    conn.execute("DELETE FROM sent_reminders")
    sender3 = FakeSender()
    reminder_job.send_account_reminders(conn, aid, now=now, sender=sender3)
    assert "HELPER" in {t for t, _ in sender3.calls}
