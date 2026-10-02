# Command reliability push — 2026-10-02

**FINAL — selected work finished, verified, committed and pushed; PR #1 open.**

See the final handoff below; earlier sections preserve the run history.

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

## Final combined verification — 12:12 EDT
- OBSERVED **316 iOS tests passed, zero failures**, including all recovery, account isolation,
  existing capture/idempotency tests and expanded voice suite. Full log:
  `/tmp/command-astra-1002/ios-final-tests.log`; xcresult
  `Logs/Test/Test-Command-2026.10.02_12-10-22--0400.xcresult` in leased DD.
- Durable public-safe test output excerpts, exact invocation shape, screenshot evidence and
  verification limits are committed in `state/evidence/astra-1002/verification.md`.
- Design spec now states actual recovery coverage and limits; MCP guide already updated.

## Final handoff — 12:14 EDT

### Done
- `f5a12fc`: durable unsent editor/calendar note recovery plus account/session isolation.
- `977c54e`: voice permission/transcription/save race protection.
- `ededd4b`: newly generated completion activities inherit hidden assignment visibility.
- `dc72efe`: MCP and in-app assistant per-occurrence status with shared date validation.
- `124198d`: repeated same-account window bootstrap preserves active editors and disk ownership.
- `64a24af`: durable verification screenshots/excerpts and recovery design documentation.
- Final combined evidence: **316 iOS tests passed**, **778 server tests passed**, final Catalyst
  build succeeded, Ruff/mypy/lockfile clean, real UI + HTTP + SQLite recovery verified.
- PR: https://github.com/legitimate-apps/command/pull/1 . Initial server and PII CI passed;
  final documentation/state pushes can retrigger the same CI. Consult PR checks for latest run.
- Main checkout untouched. All code is on `astra/capture-reliability-1002`; no merge, release,
  server deployment, store submission, external messages, or new spend.

### Cleanup
- Both helpers finished; all their implementation commits are integrated. No unfinished helper work.
- Own simulator shutdown confirmed and lease/device disposed; no booted simulators remain.
- Own simulator companion stopped; all voice/helper and integrator DerivedData leases released.
- Disposable verification servers stopped. No owned build/test/server/emulator remains running.
- Worktrees retained for review. Raw local logs remain under `/tmp/command-astra-1002/` and
  `/tmp/command-mcp-*`; committed evidence survives scratch cleanup in
  `state/evidence/astra-1002/verification.md` and the helper state files.

### Remaining and exact next step
1. Review PR #1 and its final CI checks. It is ready for review; this run does not merge or deploy it.
2. Next capture-reliability item: **durable voice recording/review recovery across process death**.
   Start by reproducing process termination after recorder stop and during transcription; define
   account-scoped ownership/retention of audio and transcript, then add crash/relaunch tests before
   implementation. Current voice changes guard asynchronous races only; they do not claim this.
3. Log/schedule drafts still lack equivalent durable recovery. Note edits retain the existing
   last-write-wins behavior for genuinely simultaneous edits on different devices.
4. Physical microphone/AVAudioSession behavior and rendered Mac/iPad multiwindow interaction remain
   unverified. Multiwindow preservation has automated iOS coverage and Catalyst compilation.
5. Existing historical completion activities are not migrated; new facts inherit current visibility.

No unfinished source change is being handed off. No task has been started merely to spend usage.

## Bounded follow-on — 12:36 EDT (operator reopened scope)
- New deadline: commit/push this item by 12:50, then stop; no merges or deployments.
- Test-first scope: crash/relaunch voice reproduction plus ownership/retention design. Production
  recovery will only be implemented if it can be fully verified safely within the deadline.
- Added an opt-in native subprocess harness compiling unmodified production VoiceCaptureFlow,
  CreateAttempt and validation source. It SIGKILLs at stopped, in-flight transcription, edited
  review and uncertain-create checkpoints, then launches a fresh process. It never restores
  from its observer JSON. No simulator/microphone/server was started.
- OBSERVED: **7 cases: 3 controls pass, 4 explicitly expected durability failures**. Strict
  `--require-recovery` mode produces **4 ordinary failures**. Thus voice process-death recovery
  remains missing; this is a reproducer, not a claim that the feature is implemented.
- Logs: `/tmp/command-astra-1002/voice-process-{characterization,required}.log`.
- One leased native DerivedData directory is in use for the harness and will be released.

## Bounded follow-on FINAL — 12:39 EDT

Done:
- `5dc9105`: real SIGKILL/fresh-process voice recovery reproductions using production flow code.
- Independent review hardened observation shape and pre-kill engine checks so harness failures
  cannot be counted as expected durability failures.
- `ios/recovery-repro/README.md` documents lease/run commands, expected-failure semantics,
  strict acceptance mode, and the exact production/integration limits.
- `docs/decisions/2026-10-02-voice-recovery.md` defines ownership, storage, lifecycle, retention,
  privacy, original payload/key replay, acknowledged assistant handoff, and implementation gates.
- Durable evidence: `state/evidence/astra-1002/voice-process-reproduction.md`.
- OBSERVED final rerun: **7 cases, 3 passing controls, 4 expected failures** (0.137s); strict
  `--require-recovery` mode: **4 failures** (0.143s, exit 1), confirming current missing durability.
  Swift executable compiled successfully from actual production sources. `git diff --check` clean.

In progress: **none**. Production voice persistence was not started. A partially wired store
would not safely resolve unfinished M4A finalization, view-lifecycle deletion, account ownership,
and downstream acknowledgment in this deadline. The requested reproduction/design deliverable
is complete; the missing feature is explicitly represented by failing acceptance requirements.

Exact next step: read the design and run both reproducer modes from `ios/recovery-repro/README.md`.
Then add account-scoped durable-store tests (scope/recreated accounts, interrupted writes, ownership,
terminal cleanup) and verify actual AVAudioRecorder M4A behavior under process kill before wiring
persistence into the recorder/sheet. Adapt the probe to the real coordinator restoration entry
point; never restore from observer JSON. Do not remove expected-failure markers until implemented.

Cleanup: read-only review helper finished; no helper implementation pending. The one native
DerivedData lease was released. No simulator/emulator was created, and no probe/build/server
process remains. Changes are on the same review branch/PR; no merge or deployment.

## Reset-window implementation step 1 — 12:57 EDT
- Operator reopened implementation until reset/stop instruction. Implemented an opt-in production
  VoiceRecordingRecoveryStore and VoiceCaptureFlow restoration path for **stopped audio only**.
- Atomic manifest publication follows successful protected audio copy; account/server/recreated
  account scopes are isolated. Original temporary audio is released only after transfer succeeds.
  Explicit terminal cleanup removes the manifest before audio so leftover files cannot replay.
- Process probe now uses this actual production restore API, never its observer file. OBSERVED:
  stopped and transcribing SIGKILL/relaunch assertions now PASS; review text and uncertain create
  key remain expected failures (**5 passing cases, 2 expected failures**).
- OBSERVED **26 native XCTest cases passed**, including all 20 existing voice-flow cases and six
  new storage tests (source removal, scope isolation, discard, corruption, failed copy, path safety).
  Logs: `/tmp/command-astra-1002/voice-audio-{step,xctest}.log`.
- IMPORTANT: RecordingSheet still uses the nonpersistent default; account/UI lifecycle integration
  is not yet wired. This is a verified production primitive, NOT a shipped end-to-end voice fix.
- Next: persist review text/engine atomically and turn the corresponding process assertion green;
  then pending original request/key, account coordinator, sheet dismissal semantics and app tests.

## Reset-window implementation step 2 — 12:59 EDT
- Added atomic review text/engine checkpoints to the same recording manifest and production flow
  restoration. Transcription results checkpoint text+engine together; later editor changes persist.
  Corrupt/write failures retain audio and surface an error rather than silently deleting evidence.
- OBSERVED hard-kill suite now **6 passing cases, 1 expected failure**: stopped audio, in-flight
  transcription audio and edited review all restore through the production API. Uncertain-create
  identity is still missing and intentionally red. Log: `voice-review-step.log` in run scratch.
- OBSERVED **28 native XCTest cases passed**, including existing voice behavior plus review restore
  and failed-write preservation. Log: `/tmp/command-astra-1002/voice-review-xctest.log`.
- App/account/sheet integration is STILL NOT wired; microphone-in-progress recovery, durable
  assistant handoff, original pending create reconciliation, and full app verification remain.
- Next immediate action: compile the integrated iOS target (no simulator boot) to verify the new
  production source on its actual platform. Then tackle original request reconciliation before
  enabling this store in RecordingSheet. Do not describe these primitives as complete app recovery.

## Reset-window implementation step 3 — 13:02 EDT
- Persist and restore CreateAttempt (key plus encoded original text/engine payload) before a
  request may begin. A failed metadata checkpoint now prevents the network submission.
- OBSERVED original process-death baseline in strict mode: **all 7 cases pass, no expected
  failures**. The unchanged reviewed capture reuses its key after hard kill and fresh process.
- OBSERVED **30 native XCTest cases pass**, including same-payload restoration and proof that a
  failed request checkpoint does not invoke the transport. Logs: `voice-key-{step,xctest}.log`.
- OBSERVED step-2 integrated iOS build succeeded (`voice-recovery-ios-build.log`); checking the
  latest step-3 target is next. No simulator has been booted in this implementation window.
- IMPORTANT REMAINING: these guarantees use opt-in production restore APIs in the process probe.
  RecordingSheet/account coordinator still do not opt in. Editing text after an uncertain create
  still follows existing changed-payload/new-intent behavior; preserving one note while applying
  later edits requires recording the returned note ID and PATCH reconciliation, not just a key.
  Assistant durable handoff, same-capture multiwindow ownership and actual M4A kill behavior remain.

## Reset-window disk-failure hardening — 13:07 EDT
- Independent review found two real failure paths. Added regressions first: both failed against
  the prior source (**2 tests, 7 assertion failures**, `voice-disk-controls-red.log`).
- A request checkpoint now atomically stores its submitted review/engine AND attempt, preventing
  a recovered disk from pairing an old review with a newer pending key. A failed durable adoption
  remains visible after transcription and blocks note submission without a checkpoint.
- OBSERVED fixed source: **32 native tests passed** and **7 strict process-death cases passed**.
  Logs: `/tmp/command-astra-1002/voice-disk-{green,process}.log`.
- OBSERVED step-3 integrated iOS build succeeded (`voice-key-ios-build.log`). Latest hardening is
  native-verified; subsequent app build remains to do.
- Remaining review finding: one corrupt manifest currently blocks discovery of intact siblings.
  Fix discovery to report unreadable records separately before wiring recovery UI. Capture owner
  fencing, original-request/later-edit reconciliation and durable assistant transfer remain too.

## Reset-window discovery hardening — 13:09 EDT
- Added a failing sibling-recovery regression, then changed discovery to return intact recordings
  plus an explicit unreadable flag. Damaged metadata/audio no longer hides other pending captures;
  unreadable files are preserved. The process probe uses this production discovery API.
- OBSERVED baseline control failed; fixed **33 native tests passed** and **7 strict process-death
  cases passed**. Logs: `voice-discovery-{red,green,process}.log` under the run scratch directory.
- Remaining next guarantee: capture owner fencing so a superseded flow cannot overwrite or delete
  files restored by another flow/window. App/UI wiring and full reconciliation remain deferred
  until these ownership and submission boundaries are complete.

## Reset-window ownership fencing — 13:11 EDT
- Added three failing regressions first: superseded flow deletion, review overwrite and network
  submission (**3 tests, 5 failed assertions** on prior code; `voice-owner-red.log`).
- Explicit restore claims a per-capture owner token. Superseded flows cannot persist reviews,
  start note requests/transcription, accept stale async results, or delete the current audio.
  Tokens are scoped by the account recovery directory and capture ID, and released on cleanup.
- OBSERVED fixed source: **36 native XCTest cases passed**, **7 strict process-death cases passed**.
  Logs: `/tmp/command-astra-1002/voice-owner-{green,process}.log`.
- Scope is file/flow ownership, not the future app-wide microphone coordinator. Sheet/account
  integration, complete pending-create reconciliation and acknowledged assistant handoff remain.

## Reset-window note reconciliation primitive — 13:17 EDT
- Added a failing later-edit regression first: uncertain create followed by changed review created
  two notes on the legacy path (1 test, 2 failures; `voice-reconcile-red.log`).
- Added saveRecoveredNote operations with a durable original body/engine/locale/key, acknowledged
  note ID and saved text. It replays the original create, checkpoints the returned ID before PATCH,
  and applies later review edits to that same note. Edits during PATCH remain pending against its ID.
- OBSERVED **39 native XCTest cases passed**, including lost-create response + later edits,
  create acknowledgment + failed PATCH + restart (no second create), and edits arriving during
  PATCH. Existing **7 strict process-death cases still pass**. Logs: `voice-reconcile-{green,process}.log`.
- This NEW durable save entry point is not yet called by RecordingSheet. Legacy saveNote retains
  its old changed-payload semantics; wire the durable entry point when enabling account recovery.
  Need an extended hard-kill test for later-edit reconciliation, then app integration/verification.

## Reset-window reconciliation across SIGKILL — 13:20 EDT
- Extended actual process-kill probe: persist an original create, edit review while awaiting its
  response, SIGKILL, restore, replay original body/key/locale, then PATCH the returned ID with later
  text and remove recovery after acknowledgment. No observer-file restoration or real server used.
- Guarded the legacy save entry point from bypassing an existing durable reconciliation. Its
  regression failed on prior source (1 test, 3 failures); fixed source has **40 native tests passing**.
- OBSERVED **8 strict process-death cases pass** (`voice-reconcile-hardkill.log`), including the new
  edited-pending-request case. Native output: `voice-reconcile-final-native.log`.
- Review identified next corrections before UI wiring: restore must reread current manifest by ID
  instead of trusting a cached listing; reject blank initial submission before freezing its payload.

## Reset-window restoration correctness — 13:23 EDT
- Added independent-review regressions first: stale listing could erase acknowledged note identity,
  and a blank first request permanently froze an invalid payload (**2 tests, 5 failures** before fix).
- Restoration now rereads the current manifest by capture ID synchronously before claiming ownership.
  Blank initial review is rejected before a pending request is created; corrected text remains savable.
- OBSERVED **42 native XCTest cases passed**, **8 strict process-death cases passed**. Logs:
  `voice-restore-validation-{red,green,process}.log` under `/tmp/command-astra-1002/`.
- Next: integrated target compilation, then shared app lifecycle/microphone ownership and note-only
  recovery UI integration with proper account deletion/teardown. No partial UI activation is present.

## Reset-window terminal cleanup — 13:30 EDT
- OBSERVED integrated iOS Simulator and Mac Catalyst builds passed at commit 32f7e8b
  (`voice-current-{ios,catalyst}-build.log`). No simulator was booted.
- Added a failing filesystem-cleanup regression: after note acknowledgment, deleting the manifest
  before a failed audio unlink stranded the editable flow (1 test, 4 failed assertions).
- Terminal cleanup now atomically renames the capture directory before unlinking. A failed rename
  retains the pending capture; a failed unlink leaves a terminal private directory, visibly reports
  cleanup pending, and discovery retries only these explicitly retired directories.
- OBSERVED fixed source: **43 native XCTest cases passed**, **8 strict process-death cases passed**.
  Evidence: `/tmp/command-astra-1002/voice-terminal-{red,green,process}.log`.
- Updated the reproduction README and ownership design status to distinguish the implemented
  opt-in primitives from the historical failing baseline and still-unwired RecordingSheet.
- Still unfinished: shared microphone/account lifecycle coordinator, retained sheet disappearance,
  real recorder crash behavior, acknowledged assistant handoff and actual app recovery UI. Next:
  wire-test durable note reconciliation against the local REST server before activating app recovery.
