"""Background push jobs don't hold SQLite's write lock across network calls; delegatee upsert
changes only what it was given. Regressions from the 2026-09 audit (each failed pre-fix).

- `reminder_job.run_once` / `briefing_job.run_once` ran every account on ONE connection, so the
  first write (a sent-marker, a pruned token) opened a transaction that stayed open through
  every later APNs call — up to 10 s each — and REST writes failed with "database is locked".
- `delegatees.upsert` wrote every field with its default: "add Sam" reset his lead time and
  metadata and re-activated him after the operator had switched him off.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta
from typing import Any

from command.core import accounts as accounts_core
from command.core import assignments as A
from command.core import (
    briefing_job,
    briefings,
    delegatee_access,
    delegatees,
    entitlements,
    push,
    reminder_job,
)
from command.db import connect, init_db

T0 = datetime(2026, 8, 3, 9, 0, 0, tzinfo=UTC)


class _ProbingSender:
    """During each 'network call', try a write from ANOTHER connection with no busy wait —
    exactly what a REST request does while the job is sending."""

    def __init__(self, db: str) -> None:
        self.db = db
        self.blocked = 0
        self.calls = 0

    def __call__(self, token: str, *, title: str, body: str, environment: str = "sandbox") -> Any:
        self.calls += 1
        other = sqlite3.connect(self.db, timeout=0)
        try:
            other.execute("CREATE TABLE IF NOT EXISTS probe (x)")
            other.execute("INSERT INTO probe VALUES (1)")
            other.commit()
        except sqlite3.OperationalError:
            self.blocked += 1
        finally:
            other.close()

        class _R:
            ok = True
            unregistered = False

        return _R()


def test_reminder_sweep_never_holds_the_write_lock_during_a_send(tmp_path: Any) -> None:
    db = str(tmp_path / "r.db")
    init_db(db)
    conn = connect(db)
    for name in ("one", "two"):
        aid = accounts_core.register(conn, name, "password1").id
        push.register(conn, aid, token=name[0] * 64, environment="sandbox")
        for i in range(2):
            at = T0 - timedelta(minutes=5 + i)
            A.create(conn, aid, title=f"{name}-{i}", scheduled_start=at.isoformat())
    conn.commit()
    conn.close()

    sender = _ProbingSender(db)
    assert reminder_job.run_once(db, now=T0, sender=sender) == 4
    assert sender.calls == 4
    assert sender.blocked == 0, "a REST write would have failed with 'database is locked'"


def test_briefing_sweep_commits_per_account(tmp_path: Any) -> None:
    db = str(tmp_path / "b.db")
    init_db(db)
    conn = connect(db)
    for name in ("one", "two"):
        aid = accounts_core.register(conn, name, "password1").id
        entitlements.record_consent(conn, aid)
        briefings.set_prefs(conn, aid, {"enabled": True, "hour_local": 8})
        push.register(conn, aid, token=name[0] * 64, environment="sandbox")
        A.create(conn, aid, title="Dentist", scheduled_start="2026-08-03T14:00:00+00:00",
                 scheduled_end="2026-08-03T15:00:00+00:00")
    conn.commit()

    sender = _ProbingSender(db)
    sent = briefing_job.run_once(conn, now=T0, sender=sender, cap=30, require_subscription=False)
    assert sent == 2 and sender.blocked == 0


def test_upsert_changes_only_what_it_is_given(conn: sqlite3.Connection) -> None:
    aid = accounts_core.register(conn, "owner", "password1").id
    sam, created = delegatees.upsert(conn, aid, name="Sam", lead_time_minutes=2880,
                                     metadata={"phone": "555"})
    assert created and sam.active and sam.kind == "human"
    session = delegatee_access.redeem_invite(conn, delegatee_access.create_invite(conn, aid, sam.id))

    off, _ = delegatees.upsert(conn, aid, name="Sam", active=False)
    assert off.active is False and off.lead_time_minutes == 2880
    assert delegatee_access.delegatee_for_session(conn, session.raw_token) is None

    again, created = delegatees.upsert(conn, aid, name="Sam")   # an agent's "add Sam"
    assert created is False
    assert (again.lead_time_minutes, again.metadata, again.active) == (2880, {"phone": "555"}, False)

    on, _ = delegatees.upsert(conn, aid, name="Sam", active=True)   # explicit reactivation
    assert on.active is True
    # ...which does not resurrect the logins that deactivation ended.
    assert delegatee_access.delegatee_for_session(conn, session.raw_token) is None
