"""`update_assignment` must not re-anchor a routine it was only asked to rename.

The tool used to send `timezone=account_timezone` on EVERY edit. A routine created over MCP
with no zone expands in UTC; renaming it through the in-app assistant silently re-anchored it
to the account zone, moving a 02:00 UTC daily standup to 22:00 the previous evening and
detaching every occurrence status keyed on the old dates.
"""

from __future__ import annotations

import json
from typing import Any

from command.core import accounts
from command.core import assignments as A
from command.core.agent import tools
from command.db import connect, init_db


def test_renaming_a_routine_keeps_its_anchor(tmp_path: Any) -> None:
    db = str(tmp_path / "tz.db")
    init_db(db)
    conn = connect(db)
    aid = accounts.register(conn, "tz-owner", "password1").id
    a = A.create(conn, aid, title="standup", schedule_kind="routine", rrule="FREQ=DAILY",
                 scheduled_start="2026-09-01T02:00:00+00:00")
    A.set_occurrence_status(conn, aid, a.id, "2026-09-10", "done")
    conn.commit()

    class _Ctx:
        deps = tools.AgentDeps(db_path=db, account_id=aid, account_timezone="America/New_York")

    out = json.loads(tools.update_assignment(_Ctx(), a.id, title="Standup"))
    assert out["title"] == "Standup" and out["timezone"] is None
    occ = A.calendar(connect(db), aid, "2026-09-10T00:00:00+00:00", "2026-09-10T23:59:59+00:00")
    assert [(o.occurrence_date, o.occurs_at, o.status) for o in occ] == [
        ("2026-09-10", "2026-09-10T02:00:00+00:00", "done")
    ]
    # Asking for a zone still sets it.
    out = json.loads(tools.update_assignment(_Ctx(), a.id, timezone="Europe/Paris"))
    assert out["timezone"] == "Europe/Paris"
