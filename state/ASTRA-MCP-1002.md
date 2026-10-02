# MCP workflow run — 2026-10-02

Base: 47170c2. Branch: astra/mcp-workflow-1002. Isolated worktree.

Chosen work: make a single recurring occurrence completable through MCP and the in-app
assistant. Both current status tools only update the entire assignment; this can mark all
future routine occurrences done. The guide already promises per-occurrence completion facts.
Also validate occurrence keys in shared core: the current REST/core path accepts nonexistent
dates and writes false completion facts. Preserve original keys after rescheduling.

Plan: discriminating regression tests, extend existing tool signatures, shared validation,
full server pytest/ruff/mypy, disposable localhost MCP/REST wire verification, small commit.
No production mutation, publication, deployment or release. No Apple changes/builds needed.

Hydrated: public START-HERE/CLAUDE/AGENTS, private maintainer override/roadmap/backlog and project
memory index. No CORPUS.md exists in the checkout or maintainer ops tree. Old audit/backlog
entries are treated as hypotheses; many already have code and tests.

Status: DONE — verified and committed; ready for integrator cherry-pick.

## Recovery and completed implementation

Recovered after the interrupted run; preserved its source edits and regression cases.
The interrupted full run had 771 passes and two failures. Fixed the real in-app serializer
failure (dict passed to model-only serializer) and the test's nonexistent hidden-setting API.
The visibility test then revealed a real shared-core omission: generated completion activity
was public even when its assignment was hidden. New completion facts now inherit the parent
assignment's hidden flag for whole-assignment and occurrence completions.

Implemented:
- Optional `occurrence_date` on external MCP and in-app assistant status tools. Omission
  keeps the existing whole-assignment behavior; supplying the calendar key updates one day.
- Shared-core validation rejects nonexistent/noncanonical occurrence keys before any write.
  Rescheduled items retain their original key; legacy fixed-offset dates and DST stay aligned
  with the calendar. Multi-day one-offs still accept each calendar day.
- MCP guide explains original keys, whole-series omission, skips and completion deduplication.
- Tests cover tool calls, permission denial, ownership, hidden visibility, repeated completion,
  invalid keys, whole-series compatibility, REST errors, date boundaries and timezone cases.

OBSERVED discriminating controls:
- Before implementation, the new core/MCP/in-app regressions failed: arbitrary dates were
  accepted, MCP completed the whole series, and in-app status rejected the new argument.
  Preserved output: `/tmp/command-mcp-occurrence-red.log` (one failure there was a fixture API
  mistake, subsequently fixed; it is not claimed as a behavioral regression).
- Executing the original activity module with the two new privacy regressions gives exactly
  `2 failed, 17 deselected`: visible activities leak from hidden assignments for both status
  modes. Output: `/tmp/command-mcp-hidden-red.log`. No source files changed for that control.

OBSERVED actual localhost wire verification (disposable server/database, no live data):
- Authenticated MCP repeated completion result:
  `{"assignment_id":1,"occurrence_date":"2026-10-02","status":"done"}`.
- REST calendar: Oct 1 todo; original Oct 2 done (moved to Oct 3 08:00Z); Oct 3 todo.
  Parent assignment remains todo.
- MCP invalid key returns `isError=true`; REST nonexistent date returns HTTP 404 `not_found`
  with a hint to use the calendar's occurrence_date.
- SQLite has exactly one completion row: `[1,"2026-10-02","assignment_completion"]`.
- Script `/tmp/command-mcp-wire.py`; output `/tmp/command-mcp-wire.log`; server logs
  `/tmp/command-mcp-wire-server.log`. Server terminated and temporary database removed.

Final checks (OBSERVED):
- `cd server && uv run pytest -q`: **778 passed in 266.09s (0:04:26)**.
  Full terminal output: `/tmp/command-mcp-final-green-suite.log`.
- `uv run ruff check .`: **All checks passed!**
- `uv run mypy src`: **Success: no issues found in 102 source files**.
- `git diff --check`: clean.
- Additional timezone/core run: `35 passed in 10.09s`.

The intermediate recovered run reached 774 passes with one incorrect expected error string
in a new test. Corrected it to the actual existing not-found wording; the final suite above
includes that corrected test and all timezone cases.

Done in two logical commits: hidden completion inheritance, then occurrence tool support.
Next: integrator cherry-picks both commits, reviews combined branch and handles branch push/PR.
No unfinished implementation or owned long-running server remains. Production and UI behavior
were not exercised; this item changes server/tool behavior only. Existing historical activity
visibility is not rewritten; newly generated completion facts inherit current parent visibility.
No simulator, Apple build, production mutation, deploy, release, spending or publication.
