"""A destructive MCP tool must be gated by a confirm-token, and must say so.

Hard Rule 2: the MCP surface is server-controlled and destructive ops require a confirm-token.
The mechanism exists (`core/confirm.py`: issue a token with a plan, consume it on the second
call), but nothing forces a *new* delete tool to use it. Adding one that goes straight to
`*_core.delete(...)` would look exactly like the four correct ones at a glance, and the failure is
silent: the agent simply deletes the operator's data with no confirmation step.

Annotations are untrusted hints (CLAUDE.md, Hard Rule 2) — so this checks both directions rather
than believing the annotation:

* every tool that actually calls a destructive `core/` function must issue AND consume a confirm
  token, take a `confirm_token` parameter, and be honestly annotated `destructiveHint=True`;
* every tool annotated `destructiveHint=True` must really be gated, so the annotation can't drift
  away from the behaviour either.

Verified against the tree at the time of writing: exactly four destructive tools
(`activities_delete`, `assignments_delete`, `delegatees_remove`, `goals_delete`), all correct.
"""

from __future__ import annotations

import pathlib
import re

TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1] / "src" / "command" / "mcp" / "tools"

# Calls into core/ that destroy account data. `set_archived` / `set_hidden` are deliberately NOT
# here: they are reversible state changes, not destruction.
DESTRUCTIVE_CALL = re.compile(r"_core\.(delete|remove|purge|destroy|revoke|wipe)\w*\(")


def _tool_blocks() -> list[tuple[str, str, str]]:
    """Every MCP tool as (file, tool_name, source-of-decorator-plus-body).

    Splitting on the decorator keeps each tool's annotations and its implementation in one chunk,
    which is what lets the two directions below be checked against each other.
    """
    blocks = []
    for path in sorted(TOOLS_DIR.glob("*.py")):
        if path.name == "__init__.py":
            continue
        chunks = path.read_text().split("@mcp.tool(")
        for chunk in chunks[1:]:
            m = re.search(r'name="([^"]+)"', chunk)
            blocks.append((path.name, m.group(1) if m else "<unnamed>", chunk))
    return blocks


def _gated(block: str) -> bool:
    return "confirm.issue" in block and "confirm.consume" in block


def test_every_destructive_tool_is_confirm_gated_and_honestly_annotated() -> None:
    blocks = _tool_blocks()
    assert len(blocks) > 25, f"only parsed {len(blocks)} tools — the layout moved"

    problems: list[str] = []
    destructive = []
    for file, name, block in blocks:
        if not DESTRUCTIVE_CALL.search(block):
            continue
        destructive.append(name)
        if not _gated(block):
            problems.append(f"{file}:{name} destroys data without issuing+consuming a confirm token")
        if "confirm_token" not in block.split(")\n", 1)[-1][:400]:
            problems.append(f"{file}:{name} has no confirm_token parameter")
        if "destructiveHint=True" not in block:
            problems.append(f"{file}:{name} destroys data but is not annotated destructiveHint=True")

    assert destructive, "found no destructive tools at all — the detector stopped working"
    assert not problems, "ungated destructive MCP tools:\n  " + "\n  ".join(problems)


def test_no_tool_claims_to_be_destructive_without_actually_being_gated() -> None:
    """The annotation must not drift away from the behaviour either.

    A tool marked destructive but not gated is the same bug seen from the other side, and it is
    the one a reviewer trusting the annotation would never look for.
    """
    problems = [
        f"{file}:{name}"
        for file, name, block in _tool_blocks()
        if "destructiveHint=True" in block and not _gated(block)
    ]
    assert not problems, "annotated destructive but not confirm-gated:\n  " + "\n  ".join(problems)


def test_the_detector_would_catch_an_ungated_delete() -> None:
    """Guard the guard — an invariant test that matches nothing passes forever."""
    ungated = (
        'name="thing_delete",\n  destructiveHint=True,\n )\n'
        " async def f(x: int):\n  things_core.delete(conn, account_id, x)\n"
    )
    assert DESTRUCTIVE_CALL.search(ungated), "detector missed a plain core delete"
    assert not _gated(ungated), "a block with no confirm calls must not read as gated"
