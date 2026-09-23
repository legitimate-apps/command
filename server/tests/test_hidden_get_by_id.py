"""The invisible-ink veil must survive a direct read by id, not just search.

`hidden` is documented on the Note / Assignment / Activity models as "excluded from agent reads
by default", and `search`/`list`/`calendar` honoured it. `get` did not — so any hidden item could
be read in full by asking for its id, and ids are sequential integers, which makes that
enumeration rather than a lucky guess. Measured before the fix:

    notes.search       -> []                      <- correctly veiled
    notes.get(1)       -> hidden=True  body='SECRET: therapy appointment notes'
    assignments.get(1) -> hidden=True  title='SECRET: divorce lawyer call'

The delete tools leaked it a second way: they fetch the target to build the confirm summary
("Delete assignment 'X'"), so an ungated fetch put a hidden title into the model's context even
though the item was supposed to be invisible.

`get_for_agent` raises NotFound rather than a permission error on purpose — answering "that
exists but you may not see it" leaks exactly what the veil is for.
"""

from __future__ import annotations

import sqlite3

import pytest

from command.core import accounts, activities, assignments, notes
from command.errors import NotFound


def _acct(conn: sqlite3.Connection, name: str = "veil") -> int:
    return accounts.register(conn, name, "password1").id


def test_hidden_note_is_invisible_by_id_but_readable_when_asked_for(conn: sqlite3.Connection) -> None:
    aid = _acct(conn)
    note = notes.create(conn, aid, "SECRET: therapy appointment notes")
    notes.set_hidden(conn, aid, note.id, True)

    with pytest.raises(NotFound):
        notes.get_for_agent(conn, aid, note.id, include_hidden=False)

    revealed = notes.get_for_agent(conn, aid, note.id, include_hidden=True)
    assert revealed.body == "SECRET: therapy appointment notes"

    # The operator's own app path is deliberately unchanged — it renders hidden notes veiled.
    assert notes.get(conn, aid, note.id).hidden is True


def test_a_visible_note_is_unaffected(conn: sqlite3.Connection) -> None:
    aid = _acct(conn, "veil-visible")
    note = notes.create(conn, aid, "ordinary note")
    assert notes.get_for_agent(conn, aid, note.id, include_hidden=False).body == "ordinary note"


def test_hidden_assignment_is_invisible_by_id(conn: sqlite3.Connection) -> None:
    aid = _acct(conn, "veil-a")
    a = assignments.create(conn, aid, title="SECRET: divorce lawyer call", hidden=True)
    with pytest.raises(NotFound):
        assignments.get_for_agent(conn, aid, a.id, include_hidden=False)
    assert assignments.get_for_agent(conn, aid, a.id, include_hidden=True).title.startswith("SECRET")


def test_hidden_activity_is_invisible_by_id(conn: sqlite3.Connection) -> None:
    aid = _acct(conn, "veil-l")
    act = activities.create(conn, aid, title="SECRET: AA meeting", hidden=True)
    with pytest.raises(NotFound):
        activities.get_for_agent(conn, aid, act.id, include_hidden=False)
    assert activities.get_for_agent(conn, aid, act.id, include_hidden=True).title.startswith("SECRET")


def test_the_veil_is_indistinguishable_from_a_missing_id(conn: sqlite3.Connection) -> None:
    """A different error for "hidden" than for "absent" would confirm the item exists."""
    aid = _acct(conn, "veil-shape")
    note = notes.create(conn, aid, "hidden one")
    notes.set_hidden(conn, aid, note.id, True)

    with pytest.raises(NotFound) as veiled:
        notes.get_for_agent(conn, aid, note.id, include_hidden=False)
    with pytest.raises(NotFound) as absent:
        notes.get_for_agent(conn, aid, 999_999, include_hidden=False)
    # Same exception type, and the message differs only by the id the caller already supplied.
    assert str(veiled.value).replace(str(note.id), "N") == str(absent.value).replace("999999", "N")


def test_cross_account_reads_still_fail_regardless_of_the_veil(conn: sqlite3.Connection) -> None:
    """The veil must not accidentally become the only thing standing between two accounts."""
    mine = _acct(conn, "veil-mine")
    theirs = _acct(conn, "veil-theirs")
    note = notes.create(conn, theirs, "their visible note")
    with pytest.raises(NotFound):
        notes.get_for_agent(conn, mine, note.id, include_hidden=True)


# --- the veil must extend to what hangs off a veiled parent -------------------


def test_attachments_and_checklists_inherit_the_parents_veil(conn: sqlite3.Connection) -> None:
    """Attachments and checklist items carry no `hidden` column of their own.

    Without `veil.require_parent_visible` an agent that could not read a hidden assignment could
    still list its attachments (filenames are revealing on their own — "divorce-settlement.pdf"),
    read those files' contents, and read its checklist steps.
    """
    from command.core import attachments, task_items, veil

    aid = _acct(conn, "veil-children")
    a = assignments.create(conn, aid, title="SECRET: divorce lawyer call", hidden=True)
    attachments.save(
        conn, aid, "assignment", a.id,
        filename="settlement-draft.txt", mime="text/plain", data=b"the terms",
    )
    task_items.add(conn, aid, "assignment", a.id, text="call the solicitor")

    # The raw core reads still work — the operator's own app needs them.
    assert len(attachments.list_for(conn, aid, "assignment", a.id)) == 1
    assert len(task_items.list_items(conn, aid, "assignment", a.id)) == 1

    # The agent-facing gate refuses, and refuses as "absent".
    with pytest.raises(NotFound):
        veil.require_parent_visible(conn, aid, "assignment", a.id, include_hidden=False)
    veil.require_parent_visible(conn, aid, "assignment", a.id, include_hidden=True)


def test_a_visible_parent_lets_its_detail_through(conn: sqlite3.Connection) -> None:
    from command.core import veil

    aid = _acct(conn, "veil-children-ok")
    a = assignments.create(conn, aid, title="ordinary task")
    veil.require_parent_visible(conn, aid, "assignment", a.id, include_hidden=False)


def test_a_goal_parent_has_no_veil_to_apply(conn: sqlite3.Connection) -> None:
    """Goals carry no `hidden` column, so the gate must pass rather than raise on an
    unhandled kind — a wrong refusal here would silently break every goal checklist."""
    from command.core import goals, veil

    aid = _acct(conn, "veil-goal")
    g = goals.create(conn, aid, title="ship the thing")
    veil.require_parent_visible(conn, aid, "goal", g.id, include_hidden=False)
