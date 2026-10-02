# Voice process-death reproduction

An opt-in native macOS harness for the current voice recovery gap. It copies unmodified
production `VoiceCaptureFlow`, `CreateAttempt`, and shared validation source into a tiny SwiftPM
executable, then Python tests kill and relaunch that executable. No third-party dependency,
microphone, simulator, server, or app account is used.

Run from the repo root with an owned DerivedData lease:

```sh
VOICE_REPRO_DD=$(dd-lease path --project command-voice-repro --purpose tests)
trap 'dd-lease release "$VOICE_REPRO_DD"' EXIT
python3 ios/recovery-repro/test_voice_process_recovery.py --build-dir "$VOICE_REPRO_DD"
python3 ios/recovery-repro/test_voice_process_recovery.py --build-dir "$VOICE_REPRO_DD" --require-recovery
```

Current result:

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
constructs the same default flow as the current recording sheet. The uncertain-create case
re-enters the exact original payload after relaunch to isolate retry-key loss from transcript
loss. It captures the request callback before a response; it does not contact a real server.

The WAV fixture is valid finalized 16 kHz mono audio, but no decoding is invoked. These tests
prove loss of flow discovery, metadata and retry identity across actual process death. They do
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
