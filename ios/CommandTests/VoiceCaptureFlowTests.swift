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
private final class Gate { var held: CheckedContinuation<Void, Never>? }

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

        let failed = await flow.saveNote { _, _ in "Server unreachable" }
        XCTAssertFalse(failed)
        XCTAssertEqual(flow.errorMessage, "Server unreachable")
        XCTAssertEqual(flow.transcript, "buy milk")
        XCTAssertTrue(removed.isEmpty)

        var savedEngine: String?
        let saved = await flow.saveNote { _, engine in savedEngine = engine; return nil }
        XCTAssertTrue(saved)
        XCTAssertEqual(savedEngine, "parakeet-v3")
        XCTAssertEqual(removed, [audio], "released only once the note is committed")
        XCTAssertNil(flow.audioURL)
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
        for _ in 0..<200 where gate.held == nil { await Task.yield() }

        flow.cancel()              // the user hit Cancel while "Transcribing…"
        gate.held?.resume()
        let used = await pending.value

        XCTAssertNil(used, "a cancelled transcription must not reach onUse (a paid turn)")
        XCTAssertTrue(flow.isCancelled)
        XCTAssertEqual(removed, [audio])
    }

    func test_immediateUse_returnsCleanedTextAndReleasesAudio() async {
        let flow = makeFlow()
        flow.adopt(audio)
        let used = await flow.transcribe(immediateUse: true) { _ in ("  what is next?\n", "sfspeech") }
        XCTAssertEqual(used, "what is next?")
        XCTAssertEqual(removed, [audio])
    }
}
