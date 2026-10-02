# Voice capture reliability — 2026-10-02

Owned branch: `astra/voice-reliability-1002`, baseline `47170c2`.
Scope: `VoiceCaptureFlow`, `RecordingSheet`, and `VoiceCaptureFlowTests`.
No release, deployment, push, simulator, or emulator was performed by this helper.

## Finished

A suspended save previously dismissed newer transcript edits and deleted whichever recording
was current when its response arrived. A suspended transcription checked only cancellation,
which a new recording clears. A microphone permission callback could start recording after Cancel.
These were selected because lost capture and unintended assistant submissions violate the app's
fast, reliable capture promise.

- Bind save completion to capture identity and review revision. Older completions retain current
  audio/edits, do not dismiss, and do not replace the current error state.
- Bind transcription completion to capture, review revision, and attempt identity; cancellation,
  replacement, and newer attempts suppress stale text, errors, and immediate-use callbacks.
- Gate permission results and recording starts against cancellation and capture replacement.
  A queued Record again task cannot reset a cancelled sheet. Duplicate Stop/interruption tasks
  and transcription retries are guarded by sheet phase.
- Added deterministic suspended-operation tests. Gates await the continuation being held rather
  than relying on sleeps. Preserve existing failed-save/retry and idempotency controls.

## Observed evidence

Native macOS XCTest compiles the actual production `VoiceCaptureFlow.swift`, `CreateAttempt.swift`,
and `AssistantSurfaceLogic.swift`, with the actual `VoiceCaptureFlowTests.swift`, in a temporary
no-dependency SwiftPM harness. It uses Swift 5.10, matching `ios/project.yml`, macOS 14 minimum,
and one build job. Artifacts are in a leased external DerivedData directory:
`/Volumes/Crucial X8/DerivedData/command-astra-voice-1002-voice-tests-3/VoiceFlowHarness`.

Command: `swift test --package-path <harness> --jobs 1`.

Fixed source: **20 tests, 0 failures**. Log: `/tmp/command-voice-native-fixed-1002.log`.

Discriminating control: replace only the flow source with `git show 47170c2:ios/Command/Transcription/VoiceCaptureFlow.swift`
and omit the four tests calling the newly introduced permission API. **16 tests, 35 assertion
failures across 11 methods; all five preexisting controls pass**. Log:
`/tmp/command-voice-native-baseline-1002.log`. Restored the fixed source and all 20 tests and reran
successfully afterward. `git diff --check` passes. All three voice helper DerivedData leases
(including the two inherited from the interrupted helper) were released after testing.

## Limits and exact next step

OBSERVED: state-machine callbacks, retained audio ownership, idempotency, and cancellation under
native XCTest. ASSUMED / not device-tested by this helper: actual microphone permission sheets,
AVAudioSession timing, rendered sheet behavior, real transcription engines, and server requests.
The integrating session owns the single permitted simulator and the full iOS build/test gate.
Cherry-pick this branch's commit, run that integration gate, then record its actual result in
`state/ASTRA-1002.md`; do not imply that host XCTest proves a device microphone flow.
