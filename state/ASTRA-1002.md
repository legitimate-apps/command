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
Integrate verified voice and MCP helper commits, verify rendered recovery/relaunch behavior,
compile Catalyst, then push this branch and open a PR. No new item after 12:10; wrap at 12:20.

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

## Crash recovery — 11:44 EDT
- Recovered own and both helper worktrees after the terminal crash. All source changes survived;
  no feature commit had yet been created. Main remains untouched.
- Resumed two helpers only: finish the existing voice race fixes and MCP occurrence-completion fix.
  No extra backlog items started. Helpers run no simulators; the unused voice simulator is released.
- Renewed own simulator and DerivedData leases. The simulator registry's adopt command preserves
  the dead owner PID; transferred only this run's owned lease to the resumed process after checking
  the old owner was gone. Other sessions' leases are untouched.
- OBSERVED: native macOS XCTest harness compiles actual recovery/transport/store sources and runs
  54 tests with 0 failures (3.880 seconds). This is logic/transport evidence, not iOS UI evidence.
- OBSERVED: helper server full suite before crash had 771 passes and 2 failures. Resumed helper
  is correcting the production serializer and test fixture, then revalidating.
- Full iOS suite is now running on the single owned simulator, capped at two build jobs.
- Latest operator timing: useful work until 12:25 EDT, then wrap up; absolute stop 13:00/refill.

## Verified step — 11:54 EDT
- OBSERVED: full iOS simulator suite **300 tests, 0 failures**; xcodebuild TEST SUCCEEDED.
  Evidence: `/tmp/command-astra-1002/ios-tests.log`; xcresult under the leased DD
  `Logs/Test/Test-Command-2026.10.02_11-47-40--0400.xcresult`.
- OBSERVED: native recovery/transport suite **54 tests, 0 failures**. Discrimination controls
  disabled persistence and stale-response protection only in copied harness sources: two tests
  then produced six failed assertions. Restored implementations: both passed. Logs in
  `/tmp/command-astra-1002/{macos-recovery-tests,recovery-controls,recovery-controls-restored}.log`.
- Implemented durable unsent editor/draft recovery, stable uncertain-create retries across restart,
  hidden-state preservation, account-scoped retirement, and transport session identities that
  prevent stale retries/responses/401 callbacks from crossing a sign-in boundary.
- UI behavior and Catalyst build remain pending. This evidence does not claim production deployment.
- Latest timing checkpoint: commit each verified step immediately; start nothing new at 12:10,
  wrap at 12:20. Absolute stop remains 13:00/reset.

## Verified voice integration — 11:57 EDT
- Integrated `977c54e` (helper source commit `2ade749`): stale permission, transcription and save
  completions cannot revive cancelled capture or discard newer review/audio.
- OBSERVED: full iOS app compiled and all **20 voice XCTest cases passed**, no failures.
  Evidence: `/tmp/command-astra-1002/ios-voice-tests.log`, xcresult
  `Logs/Test/Test-Command-2026.10.02_11-54-55--0400.xcresult` in the leased DD.
- Helper native controls: original implementation failed 35 assertions across 11 methods;
  restored fixed source passed all 20 cases. Details in `state/ASTRA-VOICE-1002.md`.
- Actual microphone prompts/audio hardware remain outside this verification claim.
- Recovery and voice commits are pushed to the remote branch. MCP integration and rendered
  relaunch check are next; no new feature scope is being opened.

## Verified MCP integration and Catalyst — 12:00 EDT
- Integrated helper commits `1bc8935` and `1f947ab`: agents can complete one original recurring
  occurrence without completing the series; invalid dates fail before writes; newly generated
  completion facts inherit hidden assignment privacy. Shared core covers REST/MCP/in-app paths.
- OBSERVED in helper worktree on exactly these server sources: **778 pytest tests passed**,
  Ruff clean, mypy clean across 102 files. Native timezone/DST/boundary regression cases pass.
  Detailed commands, controls and MCP/REST/SQLite observations: `state/ASTRA-MCP-1002.md`.
- OBSERVED: integrated app **Mac Catalyst BUILD SUCCEEDED**. Log:
  `/tmp/command-astra-1002/catalyst-build.log`. This is compilation evidence, not Mac UI evidence.

## Verified multiwindow correction — 12:08 EDT
- Independent review found repeated same-account bootstrap (another iPad/Mac window) retired
  existing editors and transferred their recovery-file ownership. Account activation now preserves
  the store for the same server/account scope and replaces it only for a changed scope or teardown.
- OBSERVED: full app recompilation plus **15 recovery persistence iOS tests passed**, including
  retaining editor/store identity and persisting edits typed after repeated activation.
  Evidence: `/tmp/command-astra-1002/ios-window-tests.log`.
- OBSERVED: quick draft survived termination with exact text. Offline editor recovery JSON retained
  both the original uncertain-create payload/key and later body edits; relaunch displayed the
  unsaved banner and Review showed exact text. Final save/DB check remains next.
- PR opened: https://github.com/legitimate-apps/command/pull/1 . Both initial CI checks passed:
  PII scan (5s) and server lock/type/test (5m17s). Latest correction is iOS-only.

## Verified actual capture recovery — 12:10 EDT
- OBSERVED simulator UI: typed quick draft, terminated the app, relaunched and read the exact same
  text from the accessibility tree and screen. Evidence: `draft-before.json`, `draft-after.json`,
  `draft-recovered.jpg` under `/tmp/command-astra-1002/`.
- OBSERVED offline editor: stopped only the disposable server, typed a title/body, confirmed
  “Not saved — Could not connect to the server.” Disk JSON contained the original create payload
  and UUID plus all later edits. Terminated the app, restarted server, relaunched Notes: the recovery
  banner appeared and Review showed exact title/body. `recovery-banner.jpg`, `review-tree.json`.
- OBSERVED Retry: HTTP POST `/api/notes` **201**, PATCH `/api/notes/1` **200**; SQLite contains
  exactly **one note** with title “Offline recovery title” and complete body. UI shows the saved row;
  recovery banner gone, editor recovery file removed, separate unsent quick draft retained.
  Evidence: server log, `retry-tree.json`, `recovery-saved.jpg` in the same scratch directory.
- OBSERVED final Catalyst build after multiwindow correction: **BUILD SUCCEEDED** in
  `/tmp/command-astra-1002/catalyst-final-build.log`.
- Latest timing: start nothing new after 12:15; wrap at 12:25. Full combined iOS verification and
  durable evidence/PR update are the remaining steps, then stop owned resources.
