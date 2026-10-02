# Voice process-death reproduction

**Current implementation checkpoint:** all eight cases pass through the opt-in production
account-scoped audio/review/request restore API. The eighth case reconciles later edits after
an uncertain create using the original request identity and a PATCH to its returned note ID.
RecordingSheet is not yet wired to recovery; this is not end-to-end app recovery.

An opt-in native macOS harness for the current voice recovery gap. It copies unmodified
production `VoiceCaptureFlow`, `VoiceRecordingRecoveryStore`, `CreateAttempt`, and shared validation source into a tiny SwiftPM
executable, then Python tests kill and relaunch that executable. No third-party dependency,
microphone, simulator, server, or app account is used.

Run from the repo root with an owned DerivedData lease:

```sh
VOICE_REPRO_DD=$(dd-lease path --project command-voice-repro --purpose tests)
trap 'dd-lease release "$VOICE_REPRO_DD"' EXIT
python3 ios/recovery-repro/test_voice_process_recovery.py --build-dir "$VOICE_REPRO_DD"
python3 ios/recovery-repro/test_voice_process_recovery.py --build-dir "$VOICE_REPRO_DD" --require-recovery
```

Historical test-first baseline (before the production store was implemented):

- Default characterization: **7 cases, 3 controls passed, 4 expected failures**.
- `--require-recovery`: **4 ordinary failures**, exit 1. This is the test-first acceptance baseline,
  not a passing recovery feature. It intentionally stays outside the normal green iOS test suite.
- An unexpected success in default mode fails the suite, forcing the expected-failure marker
  to be revisited when production behavior changes.

Each crash setup waits for an atomic observation at its exact boundary, confirms the expected
state, sends SIGKILL, confirms signal termination and surviving audio, then launches a new PID.
Harness/precondition failures occur in `setUp` and cannot count as expected recovery failures.
Every child has a bounded wait and cleanup. Temporary fixtures are deleted at test end.

The observation file is an **external oracle** only: the worker never reads it. A fresh launch
constructs a flow through production store discovery and restoration. The uncertain-create
cases restore the original body, engine, locale and key, including separately retained later
edits. They capture the request callback before a response; they do not contact a real server.

The WAV fixture is valid finalized 16 kHz mono audio, but no decoding is invoked. These tests
exercise flow discovery, metadata and retry identity across actual process death. They do
not prove recovery of unfinished M4A, AVAudioSession behavior, actual app bootstrap, account
isolation, or UI integration. The stop checkpoint begins at `flow.adopt`, not an actual recorder.

Implementation plan and ownership/retention contract:
[Voice recovery design](../../docs/decisions/2026-10-02-voice-recovery.md).
A future coordinator must be exercised through its production restore entry point. Merely teaching
this test worker to reload its observations would conceal the defect and is not an implementation.

## Implementation step 1 (12:57 EDT)

The probe now uses the production account-scoped audio store and explicit flow restoration.
Stopped/transcribing audio passes SIGKILL/relaunch checks: **5 cases pass, 2 remain expected
failures** (review state and retry identity). The recording sheet is not wired to this store yet.
The four-failure output above is the historical baseline. See the run state for current progress.

## Implementation step 2 (12:59 EDT)

Production restoration now reloads atomic review text and engine checkpoints as well as audio.
Current result: **6 passing cases, 1 expected failure** (uncertain-create identity). The sheet
still uses its nonpersistent default. Native source tests cover review restore and write failure.

## Implementation step 3 (13:02 EDT)

The unchanged reviewed capture now restores its persisted create key and payload. A failed
request checkpoint blocks submission. Strict mode: **7 passed, no expected failures**. Native
source suite: **30 passed**. Production app/account/UI integration and later-edit reconciliation
remain required; passing this initial matrix alone does not establish complete voice recovery.
