"""Every `core/` call made from a tool surface must be account-scoped.

An access token resolves to exactly one account, and the whole multi-tenant guarantee is that an
agent only ever sees that account's data (CLAUDE.md, "MCP design principles"). That guarantee is
not enforced by a type — it rests on each of ~95 call sites remembering to pass `account_id`. One
omission is a cross-account read, and it would look completely ordinary in review.

So this asserts the property mechanically instead of trusting a reviewer to re-check ~95 call
sites whenever a tool is added. It parses the tool modules and requires every `*_core.fn(...)`
call to mention an account scope in its arguments.

Deliberately a source-level check rather than a runtime one: the failure mode is a call site that
*forgot* an argument, which no amount of exercising the tools with a single account can reveal.
Verified against the tree at the time of writing: 43 calls in the agent tool layer, 51 across the
MCP tool modules, all scoped but for the one pure string helper allowlisted below.
"""

from __future__ import annotations

import pathlib
import re

SRC = pathlib.Path(__file__).resolve().parents[1] / "src" / "command"

# Pure helpers that touch neither the database nor account-owned state, so there is nothing to
# scope. Keep this list tiny and justify every entry — it is the only way to weaken the check.
ALLOWED_UNSCOPED = {
    ("delegatees_core", "slugify"),  # str -> str; no connection parameter, no rows read
}

# Any of these appearing in the argument list counts as scoping the call.
SCOPE_TOKENS = ("account_id", "account.id")


def _core_calls(src: str) -> list[tuple[str, str, str, int]]:
    """Every `<module>_core.<fn>(...)` call with its full argument span and line number.

    Brace-matched rather than regex-captured so nested calls and multi-line argument lists —
    both common here — are read correctly instead of being truncated at the first `)`.
    """
    calls = []
    for m in re.finditer(r"(\w+_core)\.(\w+)\(", src):
        i = m.end()
        depth, j = 1, i
        while j < len(src) and depth:
            if src[j] == "(":
                depth += 1
            elif src[j] == ")":
                depth -= 1
            j += 1
        calls.append((m.group(1), m.group(2), src[i : j - 1], src[: m.start()].count("\n") + 1))
    return calls


def _tool_sources() -> list[pathlib.Path]:
    paths = [SRC / "core" / "agent" / "tools.py"]
    paths += [p for p in sorted((SRC / "mcp" / "tools").glob("*.py")) if p.name != "__init__.py"]
    return paths


def test_every_tool_layer_core_call_is_account_scoped() -> None:
    unscoped: list[str] = []
    total = 0
    for path in _tool_sources():
        for module, fn, args, line in _core_calls(path.read_text()):
            total += 1
            if (module, fn) in ALLOWED_UNSCOPED:
                continue
            if not any(tok in args for tok in SCOPE_TOKENS):
                unscoped.append(f"{path.name}:{line} {module}.{fn}({args.strip()[:60]!r})")

    assert total > 80, f"only found {total} core calls — the parser or the layout moved"
    assert not unscoped, (
        "tool-surface calls into core/ with no account scope — each is a potential "
        "cross-account read:\n  " + "\n  ".join(unscoped)
    )


def test_the_scoping_check_would_actually_catch_an_unscoped_call() -> None:
    """Guard the guard: a check that cannot fail is worse than no check.

    The assertion above passes on a clean tree, which is indistinguishable from a parser that
    silently matches nothing. This feeds it a call site that is definitely unscoped.
    """
    sample = "x = notes_core.list_(conn, limit=10)\ny = notes_core.get(conn, account_id, 1)\n"
    calls = _core_calls(sample)
    assert len(calls) == 2
    unscoped = [c for c in calls if not any(t in c[2] for t in SCOPE_TOKENS)]
    assert [c[1] for c in unscoped] == ["list_"]
