# Command reliability push — 2026-10-02

## Scope and authority
- Worktree branch: `astra/capture-reliability-1002`, based on `47170c2` (build 70).
- Own this worktree only. The main checkout belongs to a separate session.
- Capture reliability first, then valuable gaps between the shipped app/server/MCP and the product promise.
- No spending, third-party messages, publication, deployment, or store submissions in this run.
- Commit with the project identity and no attribution trailers. Keep all evidence and text public-safe.
- The operator explicitly selected Astra for this run; this supersedes historical model restrictions.

## Hydration (observed)
Read START-HERE, CLAUDE/AGENTS, maintainer override, shared operating contract, original design,
MCP guide, local roadmap/TODO/mission and duplicate-note closure, and indexed project memory.
No CORPUS.md is present in the checkout or maintainer ops tree. Several backlog entries are stale;
validate them against current code and tests before choosing work. Current repository guidance says
public: do not use a self-hosted CI runner. Duplicate-note work is complete in the baseline and is
not this run's assignment.

## Current priority
**Durable unsent note recovery.** Observed: editor savers/parked edits and the calendar's quick
capture draft exist only in memory. A process termination loses unsent work even though same-process
save/retry behavior is now solid. Implement account-and-server-scoped recovery, retain the original
create key/payload across a relaunch, and remove recovery records only after success or explicit
discard. Reauthentication must restore only the matching account's work. Check stale network
callbacks at sign-out so they cannot mutate another account's capture state.

## Verification plan
- Discriminating tests for relaunch recovery, uncertain creates, partial saves, explicit discard,
  account/server isolation, and stale completions.
- Simulator tests and Catalyst compilation using leased simulator/DerivedData; observe UI where changed.
- Record actual commands/results below; do not claim production behavior from local tests.

## Done / evidence
- Isolated worktree created from the shipped baseline. No edits to main.

## Next
Trace lifecycle and account activation, implement durable recovery, run regression controls, then
select the next customer-visible reliability/workflow gap.

## In progress — local recovery
- Added per-account/server atomic recovery files for editor snapshots and quick-capture text.
  Identity includes account creation time to separate a recreated account with a reused ID.
- Retirement of a note store blocks new requests from disappearing editors after sign-out;
  successful in-flight requests may still finalize their original recovery record.
- Hidden editor snapshots retain their veil; unreadable files are preserved and reported.
- Calendar's visible input now binds directly to the account store instead of a separate
  view-local string (otherwise persistence tests alone would miss the actual input surface).
- Simulator lease: `7F4A84D8-DCF7-4520-BD2F-8B9E54242624`; DD lease project/purpose
  `command-astra-1002/tests`. Evidence scratch: `/tmp/command-astra-1002/`.
- First build invocation stopped before compilation because the test target lacked a generated
  Info.plist under ad-hoc signing. The local build invocation now supplies
  `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- GENERATE_INFOPLIST_FILE=YES`.
- No feature verification claimed yet; compiling and exercising persistence regressions next.
