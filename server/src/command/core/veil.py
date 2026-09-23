"""One place that answers: may an agent see what hangs off this parent?

The invisible-ink veil (`hidden`) lives on notes, assignments and activities. `get_for_agent` on
each of those modules keeps the *item* out of an agent's reach — but attachments and checklist
items hang off those parents and carry no `hidden` column of their own, so they were readable
even when their parent was not. An agent that could not read a hidden assignment could still
list its attachments, read those files, and read its checklist. A filename alone gives the thing
away.

Centralised rather than repeated at each of the five call sites: the veil is exactly the kind of
rule that rots when it is copied, and the failure is silent — nothing breaks, content just
leaks. Goals have no veil, so a goal parent is always visible; that is stated here once instead
of being an unexplained missing branch in five places.
"""

from __future__ import annotations

import sqlite3

from . import activities as activities_core
from . import assignments as assignments_core
from . import notes as notes_core


def require_parent_visible(
    conn: sqlite3.Connection,
    account_id: int,
    parent_kind: str,
    parent_id: int,
    *,
    include_hidden: bool,
) -> None:
    """Raise `NotFound` when an agent may not see this parent, so its detail stays unreadable.

    Delegates to each module's `get_for_agent`, so the veil is decided in exactly one place per
    entity and a veiled parent is reported as absent — never as "exists but forbidden", which
    would confirm the very thing being hidden.

    `include_hidden` has no default: a caller has to say which it means.
    """
    if parent_kind == "note":
        notes_core.get_for_agent(conn, account_id, parent_id, include_hidden=include_hidden)
    elif parent_kind == "assignment":
        assignments_core.get_for_agent(conn, account_id, parent_id, include_hidden=include_hidden)
    elif parent_kind == "activity":
        activities_core.get_for_agent(conn, account_id, parent_id, include_hidden=include_hidden)
    # Goals carry no `hidden` column — nothing to veil, and an unknown kind is the caller's own
    # validation problem (each surface already rejects unknown kinds with an actionable error).
