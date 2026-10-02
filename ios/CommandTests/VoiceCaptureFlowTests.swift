//
//  VoiceCaptureFlowTests.swift
//  CommandTests
//
//  The recording sheet's data-safety rules. The old sheet deleted the recording as soon as
//  transcription returned (a `defer`), dismissed even when the note save failed, and handed a
//  transcript that finished after Cancel to `onUse` — which can send a paid assistant turn.
//

import XCTest
@testable import Command

@MainActor
private final class Gate {
    var held: CheckedContinuation<Void, Never>? {
        didSet { ready?.resume(); ready = nil }
    }
    private var ready: CheckedContinuation<Void, Never>?

    func waitUntilHeld() async {
        if held == nil { await withCheckedContinuation { ready = $0 } }
    }
}

@MainActor
final class VoiceCaptureFlowTests: XCTestCase {
    private let audio = URL(fileURLWithPath: "/tmp/command-note-test.m4a")
    private var removed: [URL] = []

    private func makeFlow() -> VoiceCaptureFlow {
        VoiceCaptureFlow(removeFile: { [unowned self] in self.removed.append($0) })
    }

    func test_failedTranscription_keepsTheRecordingForAnotherAttempt() async {
        let flow = makeFlow()
        flow.adopt(audio)

        let used = await flow.transcribe(immediateUse: false) { _ in throw URLError(.cannotDecodeContentData) }

        XCTAssertNil(used)
        XCTAssertTrue(flow.transcriptionFailed)
        XCTAssertNotNil(flow.errorMessage)
        XCTAssertEqual(flow.audioURL, audio)
        XCTAssertTrue(removed.isEmpty, "the recording must survive a failed transcription")

        _ = await flow.transcribe(immediateUse: false) { _ in ("hello there", "sfspeech") }
        XCTAssertEqual(flow.transcript, "hello there")
        XCTAssertFalse(flow.transcriptionFailed)
        XCTAssertTrue(removed.isEmpty, "still kept — nothing is committed until the note saves")
    }

    func test_failedSave_keepsRecordingAndTranscript_successReleasesIt() async {
        let flow = makeFlow()
        flow.adopt(audio)
        _ = await flow.transcribe(immediateUse: false) { _ in ("buy milk", "parakeet-v3") }

        let failed = await flow.saveNote { _, _, _ in "Server unreachable" }
        XCTAssertFalse(failed)
        XCTAssertEqual(flow.errorMessage, "Server unreachable")
        XCTAssertEqual(flow.transcript, "buy milk")
        XCTAssertTrue(removed.isEmpty)

        var savedEngine: String?
        let saved = await flow.saveNote { _, engine, _ in savedEngine = engine; return nil }
        XCTAssertTrue(saved)
        XCTAssertEqual(savedEngine, "parakeet-v3")
        XCTAssertEqual(removed, [audio], "released only once the note is committed")
        XCTAssertNil(flow.audioURL)
    }

    func testNoteKeySurvivesRetryAndResetsForChangedTranscriptAndNewRecording() async {
        let flow = makeFlow()
        flow.adopt(audio)
        flow.transcript = "Idea"
        var keys: [String] = []
        _ = await flow.saveNote { _, _, key in keys.append(key); return "Lost response" }
        _ = await flow.saveNote { _, _, key in keys.append(key); return "Lost response" }
        XCTAssertEqual(keys[0], keys[1])
        flow.transcript = "Changed"; flow.transcript = "Idea"
        _ = await flow.saveNote { _, _, key in keys.append(key); return "Lost response" }
        XCTAssertNotEqual(keys[1], keys[2])
        _ = await flow.saveNote { _, _, key in keys.append(key); return nil }
        XCTAssertEqual(keys[2], keys[3])
        flow.adopt(URL(fileURLWithPath: "/tmp/another-recording.m4a"))
        _ = await flow.saveNote { _, _, key in keys.append(key); return nil }
        XCTAssertNotEqual(keys[3], keys[4])
    }

    func test_cancelDuringTranscription_neverHandsTheResultOn() async {
        let flow = makeFlow()
        flow.adopt(audio)
        let gate = Gate()

        let pending = Task {
            await flow.transcribe(immediateUse: true) { _ in
                await withCheckedContinuation { gate.held = $0 }
                return ("send this to the assistant", "sfspeech")
            }
        }
        await gate.waitUntilHeld()

        flow.cancel()              // the user hit Cancel while "Transcribing…"
        gate.held?.resume()
        let used = await pending.value

        XCTAssertNil(used, "a cancelled transcription must not reach onUse (a paid turn)")
        XCTAssertTrue(flow.isCancelled)
        XCTAssertEqual(removed, [audio])
    }

    func test_saveCompletionAfterTranscriptEdit_keepsEditedReviewAndAudio() async {
        let flow = makeFlow()
        flow.adopt(audio)
        flow.transcript = "Original words"
        let gate = Gate()
        let pending = Task {
            await flow.saveNote { text, _, _ in
                XCTAssertEqual(text, "Original words")
                await withCheckedContinuation { gate.held = $0 }
                return nil
            }
        }
        await gate.waitUntilHeld()
        XCTAssertNotNil(gate.held)
        flow.transcript = "Original words plus a new thought"
        gate.held?.resume()

        let dismiss = await pending.value
        XCTAssertFalse(dismiss, "saving older words must not dismiss newer edits")
        XCTAssertEqual(flow.transcript, "Original words plus a new thought")
        XCTAssertEqual(flow.audioURL, audio)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertFalse(flow.saving)
    }

    func test_saveCompletionAfterNewRecording_doesNotReleaseNewAudio() async {
        let flow = makeFlow()
        flow.adopt(audio)
        flow.transcript = "First recording"
        let gate = Gate()
        let pending = Task {
            await flow.saveNote { _, _, _ in
                await withCheckedContinuation { gate.held = $0 }
                return nil
            }
        }
        await gate.waitUntilHeld()
        XCTAssertNotNil(gate.held)
        flow.reset()
        let nextAudio = URL(fileURLWithPath: "/tmp/new-command-recording.m4a")
        flow.adopt(nextAudio)
        flow.transcript = "Second recording"
        gate.held?.resume()

        let dismiss = await pending.value
        XCTAssertFalse(dismiss)
        XCTAssertEqual(flow.audioURL, nextAudio)
        XCTAssertEqual(flow.transcript, "Second recording")
        XCTAssertEqual(removed, [audio])
    }

    func test_saveFailureAfterNewRecording_doesNotShowOldError() async {
        let flow = makeFlow()
        flow.adopt(audio)
        flow.transcript = "First recording"
        let gate = Gate()
        let pending = Task {
            await flow.saveNote { _, _, _ in
                await withCheckedContinuation { gate.held = $0 }
                return "Old request failed"
            }
        }
        await gate.waitUntilHeld()
        XCTAssertNotNil(gate.held)
        flow.reset()
        flow.adopt(URL(fileURLWithPath: "/tmp/new-command-recording.m4a"))
        gate.held?.resume()

        let dismiss = await pending.value
        XCTAssertFalse(dismiss)
        XCTAssertNil(flow.errorMessage)
    }

    func test_transcriptionAfterCancelAndReset_neverHandsOnOldWords() async {
        let flow = makeFlow()
        flow.adopt(audio)
        let gate = Gate()
        let pending = Task {
            await flow.transcribe(immediateUse: true) { _ in
                await withCheckedContinuation { gate.held = $0 }
                return ("Old assistant request", "sfspeech")
            }
        }
        await gate.waitUntilHeld()
        XCTAssertNotNil(gate.held)
        flow.cancel()
        flow.reset()
        let nextAudio = URL(fileURLWithPath: "/tmp/new-command-recording.m4a")
        flow.adopt(nextAudio)
        flow.transcript = "Current review"
        gate.held?.resume()

        let used = await pending.value
        XCTAssertNil(used)
        XCTAssertEqual(flow.transcript, "Current review")
        XCTAssertEqual(flow.audioURL, nextAudio)
        XCTAssertEqual(removed, [audio])
    }

    func test_transcriptionAfterResetWithReusedURL_cannotCommitOldCapture() async {
        let flow = makeFlow()
        flow.adopt(audio)
        let gate = Gate()
        let pending = Task {
            await flow.transcribe(immediateUse: true) { _ in
                await withCheckedContinuation { gate.held = $0 }
                return ("Old recording at the same path", "sfspeech")
            }
        }
        await gate.waitUntilHeld()
        flow.reset()
        flow.adopt(audio)
        gate.held?.resume()
        let used = await pending.value

        XCTAssertNil(used)
        XCTAssertEqual(flow.transcript, "")
        XCTAssertEqual(flow.audioURL, audio)
        XCTAssertEqual(removed, [audio], "only the discarded old capture may be removed")
    }

    func test_transcriptionFailureAfterReset_doesNotCorruptCurrentReview() async {
        let flow = makeFlow()
        flow.adopt(audio)
        let gate = Gate()
        let pending = Task {
            await flow.transcribe(immediateUse: false) { _ in
                await withCheckedContinuation { gate.held = $0 }
                throw URLError(.cannotDecodeContentData)
            }
        }
        await gate.waitUntilHeld()
        XCTAssertNotNil(gate.held)
        flow.reset()
        flow.adopt(URL(fileURLWithPath: "/tmp/new-command-recording.m4a"))
        _ = await flow.transcribe(immediateUse: false) { _ in ("Current review", "parakeet-v3") }
        gate.held?.resume()
        _ = await pending.value

        XCTAssertNil(flow.errorMessage)
        XCTAssertFalse(flow.transcriptionFailed)
        XCTAssertEqual(flow.transcript, "Current review")
        XCTAssertEqual(flow.engineUsed, "parakeet-v3")
    }

    func test_cancelDuringSave_doesNotRequestDismissalOrAcceptAnotherSave() async {
        let flow = makeFlow()
        flow.adopt(audio)
        flow.transcript = "Words"
        let gate = Gate()
        let pending = Task {
            await flow.saveNote { _, _, _ in
                await withCheckedContinuation { gate.held = $0 }
                return nil
            }
        }
        await gate.waitUntilHeld()
        XCTAssertNotNil(gate.held)
        flow.cancel()
        gate.held?.resume()
        let dismiss = await pending.value
        XCTAssertFalse(dismiss)
        var saveCalled = false
        _ = await flow.saveNote { _, _, _ in saveCalled = true; return nil }
        XCTAssertFalse(saveCalled)
    }

    func test_supersededTranscriptionForSameAudio_doesNotReplaceNewResult() async {
        let flow = makeFlow()
        flow.adopt(audio)
        // Keep the review revision unchanged when the newer attempt completes. This verifies
        // attempt identity, independently of protection against changed transcript text.
        flow.transcript = "Latest attempt"
        let gate = Gate()
        let pending = Task {
            await flow.transcribe(immediateUse: true) { _ in
                await withCheckedContinuation { gate.held = $0 }
                return ("Older attempt", "sfspeech")
            }
        }
        await gate.waitUntilHeld()
        _ = await flow.transcribe(immediateUse: false) { _ in ("Latest attempt", "parakeet-v3") }
        gate.held?.resume()
        let used = await pending.value

        XCTAssertNil(used)
        XCTAssertEqual(flow.transcript, "Latest attempt")
        XCTAssertEqual(flow.engineUsed, "parakeet-v3")
        XCTAssertEqual(flow.audioURL, audio)
        XCTAssertTrue(removed.isEmpty)
    }

    func test_cancelledTranscriptionTask_keepsAudioAndDoesNotHandOnWords() async {
        let flow = makeFlow()
        flow.adopt(audio)
        let gate = Gate()
        let pending = Task {
            await flow.transcribe(immediateUse: true) { _ in
                await withCheckedContinuation { gate.held = $0 }
                return ("Cancelled request", "sfspeech")
            }
        }
        await gate.waitUntilHeld()
        pending.cancel()
        gate.held?.resume()
        let used = await pending.value

        XCTAssertNil(used)
        XCTAssertEqual(flow.transcript, "")
        XCTAssertEqual(flow.audioURL, audio)
        XCTAssertTrue(removed.isEmpty)
    }

    func test_permissionPromptAfterCancellation_doesNotAuthorizeRecording() async {
        let flow = makeFlow()
        let gate = Gate()
        let pending = Task {
            await flow.requestPermission {
                await withCheckedContinuation { gate.held = $0 }
                return true
            }
        }
        await gate.waitUntilHeld()
        flow.cancel()
        gate.held?.resume()
        let granted = await pending.value
        XCTAssertNil(granted)
        XCTAssertTrue(flow.isCancelled)
    }

    func test_permissionPromptAfterNewCapture_doesNotChangeNewCapture() async {
        let flow = makeFlow()
        let gate = Gate()
        let pending = Task {
            await flow.requestPermission {
                await withCheckedContinuation { gate.held = $0 }
                return false
            }
        }
        await gate.waitUntilHeld()
        flow.reset()
        gate.held?.resume()
        let granted = await pending.value
        XCTAssertNil(granted, "an old permission result must not change a new sheet phase")
    }

    func test_currentPermissionDecision_isReturnedToTheSheet() async {
        let flow = makeFlow()
        let denied = await flow.requestPermission { false }
        XCTAssertEqual(denied, false)
        let granted = await flow.requestPermission { true }
        XCTAssertEqual(granted, true)
    }

    func test_transcriptionCompletionAfterReviewEdit_preservesTypedWords() async {
        let flow = makeFlow()
        flow.adopt(audio)
        let gate = Gate()
        let pending = Task {
            await flow.transcribe(immediateUse: true) { _ in
                await withCheckedContinuation { gate.held = $0 }
                return ("Recognized words", "sfspeech")
            }
        }
        await gate.waitUntilHeld()
        flow.transcript = "My corrected words"
        gate.held?.resume()
        let used = await pending.value

        XCTAssertNil(used)
        XCTAssertEqual(flow.transcript, "My corrected words")
        XCTAssertEqual(flow.audioURL, audio)
        XCTAssertTrue(removed.isEmpty)
    }

    func test_saveCompletionAfterEditAndRevert_preservesNewReview() async {
        let flow = makeFlow()
        flow.adopt(audio)
        flow.transcript = "Original words"
        let gate = Gate()
        let pending = Task {
            await flow.saveNote { _, _, _ in
                await withCheckedContinuation { gate.held = $0 }
                return nil
            }
        }
        await gate.waitUntilHeld()
        flow.transcript = "Changed words"
        flow.transcript = "Original words"
        gate.held?.resume()
        let dismiss = await pending.value

        XCTAssertFalse(dismiss)
        XCTAssertEqual(flow.audioURL, audio)
        XCTAssertTrue(removed.isEmpty)
    }

    func test_cancelledPermissionTask_doesNotAuthorizeRecording() async {
        let flow = makeFlow()
        let gate = Gate()
        let pending = Task {
            await flow.requestPermission {
                await withCheckedContinuation { gate.held = $0 }
                return true
            }
        }
        await gate.waitUntilHeld()
        pending.cancel()
        gate.held?.resume()
        let granted = await pending.value
        XCTAssertNil(granted)
    }

    func test_immediateUse_returnsCleanedTextAndReleasesAudio() async {
        let flow = makeFlow()
        flow.adopt(audio)
        let used = await flow.transcribe(immediateUse: true) { _ in ("  what is next?\n", "sfspeech") }
        XCTAssertEqual(used, "what is next?")
        XCTAssertEqual(removed, [audio])
    }
}
