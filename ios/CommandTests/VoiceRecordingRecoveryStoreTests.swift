import XCTest
@testable import Command

@MainActor
final class VoiceRecordingRecoveryStoreTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func store(server: String = "https://example.com", id: Int = 1, created: String = "first") -> VoiceRecordingRecoveryStore {
        VoiceRecordingRecoveryStore(root: root.appendingPathComponent("recovery"), server: URL(string: server)!,
                                    accountID: id, username: "tester", accountCreatedAt: created)
    }
    private func source() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("source.m4a")
        try Data("opaque audio fixture".utf8).write(to: url)
        return url
    }
    func testStoredCopySurvivesSourceRemovalAndFreshStore() throws {
        let original = try source(), owner = store()
        let record = try owner.keep(original, id: UUID())
        try FileManager.default.removeItem(at: original)
        let restarted = store(), recovered = try XCTUnwrap(restarted.load().recordings.first)
        XCTAssertEqual(record.id, recovered.id)
        XCTAssertEqual(try Data(contentsOf: restarted.audioURL(for: recovered)), Data("opaque audio fixture".utf8))
    }
    func testAccountServerAndRecreatedAccountCannotDiscoverAudio() throws {
        _ = try store().keep(source(), id: UUID())
        XCTAssertTrue(try store(id: 2).load().recordings.isEmpty)
        XCTAssertTrue(try store(server: "https://other.example.com").load().recordings.isEmpty)
        XCTAssertTrue(try store(created: "recreated").load().recordings.isEmpty)
        XCTAssertEqual(try store().load().recordings.count, 1)
    }
    func testDiscardDoesNotResurrectAndRemovesOwnedAudio() throws {
        let owner = store(), record = try owner.keep(source(), id: UUID())
        let audio = try owner.audioURL(for: record)
        try owner.discard(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(try store().load().recordings.isEmpty)
        try owner.discard(record.id)
    }
    func testCorruptManifestIsReportedAndKept() throws {
        let owner = store(), record = try owner.keep(source(), id: UUID())
        let manifest = owner.directory.appendingPathComponent(record.id.uuidString).appendingPathComponent("manifest.json")
        try Data("broken".utf8).write(to: manifest)
        XCTAssertTrue(try owner.load().unreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertNoThrow(try owner.audioURL(for: record))
    }
    func testFailedCopyDoesNotPublishRecoveryAndKeepsSource() throws {
        let owner = store(), original = try source(), id = UUID()
        _ = try owner.keep(original, id: id)
        XCTAssertThrowsError(try owner.keep(original, id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try owner.load().recordings.count, 1)
    }
    func testReviewRestoresLatestEditsAndEngineWithAudio() async throws {
        let owner = store(), flow = VoiceCaptureFlow(recovery: owner)
        flow.adopt(try source())
        _ = await flow.transcribe(immediateUse: false) { _ in ("spoken", "parakeet-v3") }
        flow.transcript = "edited after transcription"
        let record = try XCTUnwrap(store().load().recordings.first)
        let restored = VoiceCaptureFlow(recovery: store(), restoring: record)
        XCTAssertEqual(restored.transcript, "edited after transcription")
        XCTAssertEqual(restored.engineUsed, "parakeet-v3")
        XCTAssertEqual(restored.captureID, flow.captureID)
        XCTAssertNotNil(restored.audioURL)
    }
    func testReviewWriteFailureKeepsExistingAudioAndSurfacesError() throws {
        let owner = store(), flow = VoiceCaptureFlow(recovery: owner)
        flow.adopt(try source())
        let manifest = owner.directory.appendingPathComponent(flow.captureID.uuidString).appendingPathComponent("manifest.json")
        try Data("damaged manifest".utf8).write(to: manifest)
        flow.transcript = "keep these edits in memory"
        XCTAssertNotNil(flow.errorMessage)
        XCTAssertEqual(try Data(contentsOf: manifest), Data("damaged manifest".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(flow.audioURL).path))
    }
    func testUncertainRequestIdentitySurvivesFreshFlowForSamePayload() async throws {
        let owner = store(), flow = VoiceCaptureFlow(recovery: owner)
        flow.adopt(try source()); flow.transcript = "same payload"
        var originalKey = ""
        _ = await flow.saveNote { _, _, key in originalKey = key; return "response lost" }
        let restored = VoiceCaptureFlow(recovery: store(), restoring: try XCTUnwrap(store().load().recordings.first))
        var replayKey = ""
        _ = await restored.saveNote { text, _, key in
            XCTAssertEqual(text, "same payload"); replayKey = key; return "still unavailable"
        }
        XCTAssertFalse(originalKey.isEmpty)
        XCTAssertEqual(originalKey, replayKey)
    }
    func testFailedRequestCheckpointPreventsNetworkSubmission() async throws {
        let owner = store(), flow = VoiceCaptureFlow(recovery: owner)
        flow.adopt(try source()); flow.transcript = "not safe to send"
        let manifest = owner.directory.appendingPathComponent(flow.captureID.uuidString).appendingPathComponent("manifest.json")
        try Data("damaged manifest".utf8).write(to: manifest)
        var sent = false
        let saved = await flow.saveNote { _, _, _ in sent = true; return nil }
        XCTAssertFalse(saved); XCTAssertFalse(sent)
        XCTAssertNotNil(flow.errorMessage)
        XCTAssertNotNil(flow.audioURL)
    }
    func testRecoveredDiskCheckpointsSubmittedReviewAndKeyTogether() async throws {
        let owner = store(), flow = VoiceCaptureFlow(recovery: owner)
        flow.adopt(try source()); flow.transcript = "old review"
        let manifest = owner.directory.appendingPathComponent(flow.captureID.uuidString).appendingPathComponent("manifest.json")
        let old = try Data(contentsOf: manifest)
        try Data("unreadable".utf8).write(to: manifest)
        flow.transcript = "submitted review"
        XCTAssertNotNil(flow.errorMessage)
        try old.write(to: manifest)
        var submittedKey = ""
        _ = await flow.saveNote { _, _, key in submittedKey = key; return "response lost" }
        let restored = VoiceCaptureFlow(recovery: store(), restoring: try XCTUnwrap(store().load().recordings.first))
        XCTAssertEqual(restored.transcript, "submitted review")
        _ = await restored.saveNote { text, _, key in
            XCTAssertEqual(text, "submitted review"); XCTAssertEqual(key, submittedKey); return "response lost"
        }
    }
    func testFailedAdoptionStaysVisibleAndCannotSubmitWithoutCheckpoint() async throws {
        let original = try source()
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("recovery"))
        let flow = VoiceCaptureFlow(recovery: store())
        flow.adopt(original)
        XCTAssertNotNil(flow.errorMessage)
        _ = await flow.transcribe(immediateUse: false) { _ in ("recovered in memory", "sfspeech") }
        XCTAssertNotNil(flow.errorMessage)
        var sent = false
        let saved = await flow.saveNote { _, _, _ in sent = true; return nil }
        XCTAssertFalse(sent); XCTAssertFalse(saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testDamagedRecordingDoesNotHideIntactSibling() throws {
        let owner = store()
        let damaged = try owner.keep(source(), id: UUID())
        let intact = try owner.keep(source(), id: UUID())
        let manifest = owner.directory.appendingPathComponent(damaged.id.uuidString).appendingPathComponent("manifest.json")
        try Data("damaged".utf8).write(to: manifest)
        let recovered = try owner.load()
        XCTAssertEqual(recovered.recordings.map(\.id), [intact.id])
        XCTAssertTrue(recovered.unreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }
    func testSupersededFlowCannotDiscardRestoredRecording() throws {
        let owner = store(), original = VoiceCaptureFlow(recovery: owner)
        original.adopt(try source()); original.transcript = "original"
        let restored = VoiceCaptureFlow(recovery: owner, restoring: try XCTUnwrap(owner.load().recordings.first))
        original.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(restored.audioURL).path))
        XCTAssertEqual(try owner.load().recordings.count, 1)
    }
    func testSupersededFlowCannotOverwriteNewerReview() throws {
        let owner = store(), original = VoiceCaptureFlow(recovery: owner)
        original.adopt(try source()); original.transcript = "original"
        let restored = VoiceCaptureFlow(recovery: owner, restoring: try XCTUnwrap(owner.load().recordings.first))
        restored.transcript = "current owner"
        original.transcript = "late stale edit"
        XCTAssertEqual(try owner.load().recordings.first?.transcript, "current owner")
    }
    func testSupersededFlowCannotStartRequest() async throws {
        let owner = store(), original = VoiceCaptureFlow(recovery: owner)
        original.adopt(try source()); original.transcript = "original"
        let restored = VoiceCaptureFlow(recovery: owner, restoring: try XCTUnwrap(owner.load().recordings.first))
        var sent = false
        let saved = await original.saveNote { _, _, _ in sent = true; return nil }
        XCTAssertFalse(saved); XCTAssertFalse(sent)
        XCTAssertNotNil(restored.audioURL)
    }
    func testLaterEditsAfterUncertainCreateMustNotCreateAnotherNote() async throws {
        let owner = store(), original = VoiceCaptureFlow(recovery: owner)
        original.adopt(try source()); original.transcript = "first submitted text"
        var notes: [Int: String] = [:], keys: [String: Int] = [:]
        var loseResponse = true
        let operations = VoiceCaptureFlow.NoteOperations(create: { request in
            XCTAssertEqual(request.body, "first submitted text")
            XCTAssertEqual(request.locale, "en-US")
            let id = keys[request.key] ?? keys.count + 1
            keys[request.key] = id; notes[id] = notes[id] ?? request.body
            if loseResponse { throw URLError(.networkConnectionLost) }
            return id
        }, update: { id, body in notes[id] = body })
        _ = await original.saveRecoveredNote(locale: "en-US", using: operations)
        original.transcript = "later edited text"
        let restored = VoiceCaptureFlow(recovery: owner, restoring: try XCTUnwrap(owner.load().recordings.first))
        loseResponse = false
        let saved = await restored.saveRecoveredNote(locale: "fr-FR", using: operations)
        XCTAssertTrue(saved)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[1], "later edited text")
        XCTAssertTrue(try owner.load().recordings.isEmpty)
    }
    func testAcknowledgedCreateThenFailedPatchResumesWithoutAnotherCreate() async throws {
        let owner = store(), original = VoiceCaptureFlow(recovery: owner)
        original.adopt(try source()); original.transcript = "original request"
        var creates = 0
        let first = VoiceCaptureFlow.NoteOperations(create: { _ in
            creates += 1; original.transcript = "edited during create"; return 42
        }, update: { _, _ in throw URLError(.notConnectedToInternet) })
        let initial = await original.saveRecoveredNote(locale: nil, using: first)
        XCTAssertFalse(initial)
        let restored = VoiceCaptureFlow(recovery: owner, restoring: try XCTUnwrap(owner.load().recordings.first))
        let second = VoiceCaptureFlow.NoteOperations(create: { _ in creates += 1; return 99 }, update: { id, text in
            XCTAssertEqual(id, 42); XCTAssertEqual(text, "edited during create")
        })
        let saved = await restored.saveRecoveredNote(locale: nil, using: second)
        XCTAssertTrue(saved); XCTAssertEqual(creates, 1)
    }
    func testEditsDuringPatchStayPendingAgainstSameNoteID() async throws {
        let owner = store(), flow = VoiceCaptureFlow(recovery: owner)
        flow.adopt(try source()); flow.transcript = "first"
        let first = VoiceCaptureFlow.NoteOperations(create: { _ in flow.transcript = "second"; return 7 },
            update: { _, _ in flow.transcript = "third" })
        let saved = await flow.saveRecoveredNote(locale: nil, using: first)
        XCTAssertFalse(saved)
        let record = try XCTUnwrap(owner.load().recordings.first)
        XCTAssertEqual(record.savedNoteID, 7); XCTAssertEqual(record.savedText, "second")
        XCTAssertEqual(record.transcript, "third")
    }
    func testLegacySaveCannotBypassPendingReconciliation() async throws {
        let owner = store(), original = VoiceCaptureFlow(recovery: owner)
        original.adopt(try source()); original.transcript = "pending create"
        _ = await original.saveRecoveredNote(locale: nil, using: .init(create: { _ in
            throw URLError(.networkConnectionLost)
        }, update: { _, _ in }))
        let restored = VoiceCaptureFlow(recovery: owner, restoring: try XCTUnwrap(owner.load().recordings.first))
        var sent = false
        let saved = await restored.saveNote { _, _, _ in sent = true; return nil }
        XCTAssertFalse(sent); XCTAssertFalse(saved)
        XCTAssertEqual(try owner.load().recordings.count, 1)
    }
    func testCachedListingCannotEraseNewerAcknowledgedNoteIdentity() async throws {
        let owner = store(), original = VoiceCaptureFlow(recovery: owner)
        original.adopt(try source()); original.transcript = "original"
        let cached = try XCTUnwrap(owner.load().recordings.first)
        _ = await original.saveRecoveredNote(locale: nil, using: .init(create: { _ in
            original.transcript = "newer edits"; return 42
        }, update: { _, _ in throw URLError(.notConnectedToInternet) }))
        let restored = VoiceCaptureFlow(recovery: owner, restoring: cached)
        var created = false, updatedID = 0
        let saved = await restored.saveRecoveredNote(locale: nil, using: .init(create: { _ in
            created = true; return 99
        }, update: { id, text in updatedID = id; XCTAssertEqual(text, "newer edits") }))
        XCTAssertTrue(saved); XCTAssertFalse(created); XCTAssertEqual(updatedID, 42)
    }
    func testBlankInitialSubmissionDoesNotPoisonCorrectedCapture() async throws {
        let owner = store(), flow = VoiceCaptureFlow(recovery: owner)
        flow.adopt(try source()); flow.transcript = "  \n "
        var creates = 0
        let operations = VoiceCaptureFlow.NoteOperations(create: { request in
            creates += 1
            if request.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw URLError(.badURL) }
            return 42
        }, update: { _, _ in })
        let empty = await flow.saveRecoveredNote(locale: nil, using: operations)
        XCTAssertFalse(empty); XCTAssertEqual(creates, 0)
        flow.transcript = "corrected text"
        let saved = await flow.saveRecoveredNote(locale: nil, using: operations)
        XCTAssertTrue(saved); XCTAssertEqual(creates, 1)
    }
    func testManifestCannotReferenceAnOutsideFile() throws {
        let owner = store()
        XCTAssertThrowsError(try owner.audioURL(for: .init(version: 1, id: UUID(), filename: "../../outside.m4a")))
    }
}
