# Voice capture ownership and process-death recovery

Status: **partially implemented in opt-in production primitives; app integration pending**. The first reproductions are
committed in `ios/recovery-repro/`. This note records the work needed to turn the existing
within-process voice safety into durable recovery, without changing the capture product flow.

## Observed problem and evidence

`AudioRecorder.start()` writes M4A into temporary storage. `VoiceCaptureFlow` holds the audio
URL, transcript, engine, revision, and create attempt only in memory. Its default initializer
(the one used by `RecordingSheet`) has no restore path. Killing a process after recording stops,
during transcription, during edited review, or while awaiting a create response leaves a new
process unable to discover the capture or reuse the pending request key.

The initial native subprocess reproducer compiled actual production source and reached those boundaries.
Its historical baseline below predates the opt-in durable store. The current eight cases pass
through production discovery/restoration, including later-edit reconciliation; RecordingSheet
still uses its nonpersistent default. The reproducer
uses SIGKILL, checks the exit signal, and launches a different process. Three existing-behavior
controls pass; four recovery assertions are expected failures. Strict mode fails those four
assertions. The raw fixture file survives the kill, which separates lost discovery/metadata
from deletion. Observer JSON is test evidence only; the app never reads it for restoration.

This is **not** an AVAudioRecorder or app-bootstrap test. The fixture is finalized PCM WAV;
actual recording is M4A. Whether an unfinished M4A remains decodable after process death is
unproven and requires a device/simulator recording test before claiming recovery during recording.
The harness also does not exercise account scope or rendered recovery UI.

Source review identifies two additional ownership problems to resolve with persistence:

- `RecordingSheet.onDisappear` calls both recorder and flow cancellation. Ordinary navigation,
  window closure, and a swipe from successful review currently mean deletion.
- Immediate-use transcription deletes source audio before its `Void` callback runs. In
  `AgentChatView.acceptTranscription`, a full assistant queue can reject `AgentStore.send`, and
  its Boolean result is ignored. Manual Use writes an in-memory view draft. Neither action is
  evidence of durable acceptance. This handoff gap is source-observed, not reproduced on device.

## Owner, scope, and storage

A shared capture coordinator owns durable records independently of sheet/window lifetimes.
Each capture has a stable UUID and the same scope convention as note recovery: normalized
server URL, account ID, username, and account creation identity. A second window for the same
scope reuses the coordinator. One microphone lease is exclusive across windows; different
stopped captures may remain separately reviewable.

Store each capture beneath protected Application Support storage, excluded from backup, with
restrictive directory/file permissions. Raw audio stays local. A versioned manifest contains:

- Stable capture ID, scope identity, intended destination, creation time, lifecycle phase.
- Relative audio filename constrained to that capture directory; interrupted/finalized status.
- Latest transcript, revision, engine, locale, and any hidden-content requirement.
- Pending original note request (all submitted fields), its idempotency key, and acknowledged
  note ID or durable recipient receipt where applicable.

No transcript/audio content belongs in diagnostics. App lock and hidden-content rules apply to
recovery previews, manifests, audio, and temporary transcription copies. Signing out hides and
retains the original account's unfinished captures; a different account cannot enumerate or
submit them. Account deletion removes that scope. Transport work stays bound to its session.

## Lifecycle and retention

| Boundary | Durable action | Restore behavior |
|---|---|---|
| Before recorder starts | Create manifest and owned audio path | Never automatically activate microphone |
| Recording stops/interruption | Finalize audio; record interruption and stopped phase | Validate audio; offer transcription/review |
| Transcription starts | Retain stopped audio and checkpoint phase | Offer retry; never auto-send a turn |
| Result or review edit | Atomically persist transcript/revision/engine | Restore latest committed text |
| Note request begins | Persist exact original payload and key before network call | Reconcile/replay original request |
| Note acknowledged | Persist note ID/receipt, then settle pending edits | Resume PATCH if needed; avoid another create |
| Recipient accepts handoff | Persist recipient's durable receipt for exact revision | Do not redeliver accepted revision |
| Explicit discard / completed capture | Persist terminal state before unlinking files | Finish cleanup; never resurrect/replay |

A record found in `recording` after a crash becomes an interrupted capture. Do not promise that
it contains the final spoken words. Validate decoding and explain truncation. Keep damaged audio
and manifest evidence with a recoverable error instead of deleting it or fabricating success.

Stopping asynchronous work and discarding content are separate operations. Disappearance,
account changes, window closure, and suspension retain unfinished records. Explicit **Discard
recording** authorizes deletion. Record again must explicitly replace the current capture or
park it before starting another; an incidental lifecycle callback cannot make that choice.

Atomic manifest writes must preserve the previous readable record on failure. Do not advance a
network submission or destructive handoff when its prerequisite checkpoint failed. Surface the
failure. Audio must be durably owned before transcription; copying/moving a temporary recording
must handle the crash window without deleting the only readable copy. Recording directly into
its owned directory avoids a later adoption gap, but requires verification of recorder behavior.

No age-based expiry of unfinished captures. Disk pressure is a visible error and explicit user
choice. Cleanup may delete known terminal leftovers; unknown/unreadable records are retained
for reconciliation. A failed unlink does not make a completed capture pending again.

## Note retry identity and downstream acceptance

After an uncertain POST, replay its **original key and complete payload**. Keep newer transcript
edits separately, recover the note ID, and PATCH those edits to that same note. Editing after an
uncertain request must not silently generate another create. Include source, body, engine,
locale, and all other submitted fields in the persisted request contract. Save the returned
identity before clearing pending state; use existing server idempotency to close that crash window.

Replace `Void` transcript handoff with an acknowledgment naming the durable recipient, scope,
capture ID, and accepted revision. A refused/full queue keeps the source recoverable. An
in-memory draft, scheduled Task, or callback invocation is insufficient acknowledgment. Source
cleanup requires durable acceptance, and stale acknowledgments cannot delete a newer revision.

An assistant turn may spend money or execute tools. Do **not** automatically replay an uncertain
assistant submission after relaunch without server-supported idempotency/reconciliation. Restore
it for explicit review. A local persisted draft can accept ownership without sending a turn;
that is a separate boundary from successful remote submission.

## Verification gates and implementation order

1. Keep the committed process reproductions as a baseline. When introducing the coordinator,
   adapt the probe to the real production account-scoped restore entry point; never restore from
   observer output or duplicate recovery logic inside tests. Remove expected-failure markers only
   when the corresponding guarantees pass. Strict mode must then pass all acceptance cases.
2. Add durable-store tests before implementation: account/server/recreated-account isolation,
   ownership transfers, atomic-write failure, corrupt/missing audio, and terminal cleanup replay.
3. Implement owned recording storage and manifest transitions, then wire the shared coordinator
   into account activation and sheet lifecycle. Verify real app terminate/relaunch, including
   two-window ownership and account changes. Do not claim app integration from the native probe.
4. Test process death during actual M4A recording, after stop before transcription, during
   transcription, during edited review, and after a failed disk checkpoint. Assert retained
   recoverable material and no automatic microphone/assistant activity.
5. Exercise an actual local REST create with a lost response, crash, relaunch, and later edits.
   Assert one note, the original create key, complete final body, and eventual cleanup.
6. Test create acknowledgment before cleanup, explicit discard before unlink, refused assistant
   queue, accepted durable draft transfer, and uncertain assistant send. Assert no duplicated,
   cross-account, or unintended submissions. Run iOS tests, Catalyst build, and UI verification.

The first bounded 2026-10-02 follow-on delivered the baseline and this contract. The later
operator-authorized reset window added account-scoped audio, review and complete note-request
checkpoints, ownership fencing, note-ID/PATCH reconciliation and terminal cleanup. These
primitives pass native and process-death checks. Production persistence remains opt-in and
is not wired into the app: unfinished recording durability,
destructive lifecycle callbacks, and unacknowledged handoff must be solved and verified together.
