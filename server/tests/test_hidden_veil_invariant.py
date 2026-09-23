"""No agent-facing surface may read a veil-bearing entity by id without going through the gate.

Notes, assignments and activities each carry `hidden` — the invisible-ink veil — documented on
the model as "excluded from agent reads by default". `search`/`list`/`calendar` honoured that;
`get` did not, and five call sites plus two delete-confirm summaries went straight to it.

The fix is only durable if the next one can't. `get_for_agent` is the gate; this asserts nothing
on an agent surface calls the ungated `get` for those three entities. Goals, delegatees and
attachments have no `hidden` column, so they are legitimately unaffected.
"""

from __future__ import annotations

import pathlib
import re

SRC = pathlib.Path(__file__).resolve().parents[1] / "src" / "command"

# Only these three have an invisible-ink veil to bypass.
VEILED = ("notes_core", "assignments_core", "activities_core")

UNGATED = re.compile(
    r"\b(" + "|".join(VEILED) + r")\.get\(", re.M
)


def _agent_surfaces() -> list[pathlib.Path]:
    paths = [SRC / "core" / "agent" / "tools.py"]
    paths += [p for p in sorted((SRC / "mcp" / "tools").glob("*.py")) if p.name != "__init__.py"]
    return paths


def test_no_agent_surface_reads_a_veiled_entity_through_the_ungated_get() -> None:
    offenders: list[str] = []
    for path in _agent_surfaces():
        for i, line in enumerate(path.read_text().split("\n"), start=1):
            if line.lstrip().startswith("#"):
                continue
            if UNGATED.search(line):
                offenders.append(f"{path.name}:{i}: {line.strip()[:80]}")

    assert not offenders, (
        "agent-facing reads of a veil-bearing entity that bypass `get_for_agent` — each one lets "
        "a hidden item be read by id, and ids are sequential:\n  " + "\n  ".join(offenders)
    )


def test_detail_reads_resolve_their_parent_through_the_veil() -> None:
    """Attachments and checklist items inherit the parent's veil; they have none of their own.

    Reading them without resolving the parent leaks a hidden item's filenames, file contents and
    checklist steps — the title is veiled but everything hanging off it is not. Each of these
    reads must sit in the same function as a `veil.require_parent_visible` call.
    """
    reads = re.compile(r"(attachments_core\.list_for|task_items_core\.list_items)\(")
    offenders: list[str] = []
    for path in _agent_surfaces():
        src = path.read_text()
        # Split into functions and require the gate inside whichever one performs the read.
        chunks = re.split(r"\n(?=\s*(?:async )?def )", src)
        for chunk in chunks:
            if reads.search(chunk) and "veil.require_parent_visible" not in chunk:
                fn = (re.search(r"def (\w+)", chunk) or [None, "?"])[1]
                offenders.append(f"{path.name}:{fn}")
    assert not offenders, (
        "detail reads that never check the parent's veil:\n  " + "\n  ".join(offenders)
    )


def test_reading_an_attachment_checks_the_veil_before_opening_the_file() -> None:
    """The contents are the worst thing to leak, so the gate must precede the file read."""
    for path in _agent_surfaces():
        src = path.read_text()
        for chunk in re.split(r"\n(?=\s*(?:async )?def )", src):
            if "attachments_core.file_path(" not in chunk:
                continue
            assert "veil.require_parent_visible" in chunk, f"{path.name}: unguarded file read"
            assert chunk.index("veil.require_parent_visible") < chunk.index(
                "attachments_core.file_path("
            ), f"{path.name}: veil check must come before the file is opened"


def test_the_gate_exists_on_all_three_veiled_modules() -> None:
    """A guard that points at a function nobody defined would pass by accident."""
    for module in ("notes", "assignments", "activities"):
        src = (SRC / "core" / f"{module}.py").read_text()
        assert "def get_for_agent(" in src, f"{module}.get_for_agent is missing"
        assert "include_hidden: bool" in src, f"{module}.get_for_agent must take include_hidden"


def test_a_remote_peer_can_never_opt_into_hidden_items() -> None:
    """The A2A inbound surface is the least-trusted caller there is — another agent entirely.

    `allow_hidden` is the operator's per-conversation opt-in from their own app. It must stay
    fail-closed for peers: `runner.run` defaults it to False, and the peer path must never pass
    it. A peer that could set it would read the operator's invisible-ink items over the network.
    """
    runner = (SRC / "core" / "agent" / "runner.py").read_text()
    assert "allow_hidden: bool = False" in runner, "runner.run must default allow_hidden to False"

    inbound = (SRC / "core" / "peers" / "inbound.py").read_text()
    assert "allow_hidden" not in inbound, (
        "the peer surface must not thread allow_hidden — it inherits the fail-closed default"
    )


def test_the_agent_is_actually_told_about_the_veil_at_runtime() -> None:
    """Enforcing the veil silently is only half the job — the agent has to understand it.

    `mcp/instructions.py` is what the model actually reads at session start;
    `docs/mcp/MCP-GUIDE.md` is the written contract. The guide had no mention of `hidden` at all
    and the instructions were a separate string, so an agent meeting a veiled id would report
    "that doesn't exist" to the operator — confidently wrong about their own data — and would
    never know `include_hidden` existed when they asked for it.
    """
    from command.mcp.instructions import INSTRUCTIONS

    lowered = INSTRUCTIONS.lower()
    assert "hidden" in lowered, "the runtime instructions must describe the veil"
    assert "include_hidden" in lowered, "and must name the parameter that lifts it"
    # The load-bearing half: don't tell the operator their data is gone.
    assert "doesn't exist" in lowered or "does not exist" in lowered, (
        "the instructions must warn against reporting a veiled item as nonexistent"
    )

    guide = (SRC.parents[2] / "docs" / "mcp" / "MCP-GUIDE.md").read_text().lower()
    assert "include_hidden" in guide, "the written contract must document the veil too"


def _functions(path: pathlib.Path) -> list[str]:
    return re.split(r"\n(?=\s*(?:async )?def )", path.read_text())


# Writes BY ID on a veil-bearing entity (or on something that hangs off one). Each echoes the
# row back — or succeeds/fails depending on whether the id exists — so each must resolve the
# target through the veil first, in the same function, before the write.
WRITES_BY_ID = re.compile(
    r"\b(notes_core\.set_processed|assignments_core\.update|assignments_core\.assign"
    r"|assignments_core\.set_status|activities_core\.update|task_items_core\.add"
    r"|task_items_core\.update)\("
)
GATE = re.compile(r"(get_for_agent\(|veil\.require_parent_visible\()")


def test_agent_writes_by_id_go_through_the_veil_first() -> None:
    offenders: list[str] = []
    for path in _agent_surfaces():
        for chunk in _functions(path):
            write = WRITES_BY_ID.search(chunk)
            if write is None:
                continue
            gate = GATE.search(chunk)
            if gate is None or gate.start() > write.start():
                fn = (re.search(r"def (\w+)", chunk) or [None, "?"])[1]
                offenders.append(f"{path.name}:{fn} ({write.group(1)})")
    assert not offenders, (
        "agent-facing writes that act on (and echo) a hidden item without the veil check:\n  "
        + "\n  ".join(offenders)
    )


# Reads that return a LIST containing veil-bearing rows (or their titles/ids). They take an
# `include_hidden` argument; agent surfaces must pass it explicitly rather than let a default
# decide — this is how list_goal_notes returned hidden note bodies, and find_conflicts /
# find_stale returned hidden titles (the latter onto the lock screen via the briefing).
LIST_READS = re.compile(
    r"\b(goals_core\.list_notes|goals_core\.link_notes|schedule_core\.find_conflicts"
    r"|schedule_core\.find_stale_assignments)\("
)


def _call_args(src: str, open_paren: int) -> str:
    """The argument text of the call whose `(` is at `open_paren` (balanced, nested-safe)."""
    depth = 0
    for i in range(open_paren, len(src)):
        depth += {"(": 1, ")": -1}.get(src[i], 0)
        if depth == 0:
            return src[open_paren + 1 : i]
    return src[open_paren + 1 :]


def test_agent_list_reads_state_their_veil() -> None:
    offenders: list[str] = []
    paths = [*_agent_surfaces(), SRC / "core" / "briefings.py"]
    for path in paths:
        src = path.read_text()
        for m in LIST_READS.finditer(src):
            if "include_hidden=" not in _call_args(src, m.end() - 1):
                offenders.append(f"{path.name}: {m.group(1)}")
    assert not offenders, "list reads that don't say whether hidden rows are in:\n  " + "\n  ".join(
        offenders
    )


def test_the_write_and_list_detectors_would_fire() -> None:
    bad = "def t(ctx):\n    with c as conn:\n        return notes_core.set_processed(conn, 1, 2, True)\n"
    assert WRITES_BY_ID.search(bad) and not GATE.search(bad)
    src = "schedule_core.find_stale_assignments(conn, aid, now=clock.now(), limit=5)"
    m = LIST_READS.search(src)
    assert m is not None and "include_hidden=" not in _call_args(src, m.end() - 1)
    assert "limit=5" in _call_args(src, m.end() - 1)   # nested parens don't cut it short


def test_the_detector_would_catch_a_reintroduced_bypass() -> None:
    """Guard the guard — a regex that matches nothing passes forever."""
    assert UNGATED.search("        return notes_core.get(conn, account_id, note_id)")
    assert UNGATED.search("target = activities_core.get(conn, ctx.deps.account_id, activity_id)")
    # The gated form and unrelated modules must not trip it.
    assert not UNGATED.search("notes_core.get_for_agent(conn, account_id, note_id, include_hidden=x)")
    assert not UNGATED.search("goals_core.get(conn, account_id, goal_id)")
