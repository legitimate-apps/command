//
//  NoteSaverTests.swift
//  CommandTests
//
//  The note editor's save rules. The old editor (a) dropped text typed while a brand-new note's
//  create was in flight — a `creating` guard returned early and nothing re-saved — and (b) treated
//  a failed save as done, closing the editor over the unsaved text.
//

import XCTest
@testable import Command

@MainActor
final class NoteSaverTests: XCTestCase {

    /// A scripted backend: records calls, can hold a create open, can fail the next call.
    @MainActor
    private final class FakeBackend {
        var creates: [String] = []
        var createKeys: [UUID] = []
        var updates: [(id: Int, body: String)] = []
        var failNext = false
        var holdCreate = false
        var heldCreates: [CheckedContinuation<Void, Never>] = []

        func releaseCreates() {
            let held = heldCreates
            heldCreates = []
            held.forEach { $0.resume() }
        }

        var ops: NoteSaver.Ops {
            NoteSaver.Ops(
                create: { [unowned self] _, body, key in
                    creates.append(body)
                    createKeys.append(key)
                    if holdCreate { await withCheckedContinuation { heldCreates.append($0) } }
                    if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
                    return 42
                },
                update: { [unowned self] id, _, body in
                    if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
                    updates.append((id, body))
                })
        }
    }

    private func spin(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func test_textTypedWhileCreateIsInFlight_isSavedToTheCreatedNote() async {
        let backend = FakeBackend()
        backend.holdCreate = true
        let saver = NoteSaver(noteId: nil, text: "")
        saver.text = "Groceries"

        let first = Task { await saver.save(using: backend.ops) }
        await spin { !backend.heldCreates.isEmpty }
        XCTAssertEqual(backend.creates, ["Groceries"])

        // More typing lands while the create is still on the wire.
        saver.text = "Groceries\nmilk, eggs"
        let second = Task { await saver.save(using: backend.ops) }
        for _ in 0..<20 { await Task.yield() }

        // Release every held create (an unserialized saver would have started a second one).
        backend.holdCreate = false
        backend.releaseCreates()
        let ok1 = await first.value
        let ok2 = await second.value

        XCTAssertTrue(ok1 && ok2)
        XCTAssertEqual(backend.creates.count, 1, "exactly one create — no double-create")
        XCTAssertEqual(backend.updates.map(\.id), [42], "the follow-up save updates the created note")
        XCTAssertEqual(backend.updates.last?.body, "Groceries\nmilk, eggs")
        XCTAssertEqual(saver.noteId, 42)
        XCTAssertFalse(saver.hasUnsavedChanges)
    }

    func test_failedSave_keepsTheTextUnsaved_andRetrySucceeds() async {
        let backend = FakeBackend()
        let saver = NoteSaver(noteId: 7, text: "Old")
        saver.text = "Old, edited"
        backend.failNext = true

        let flushed = await saver.flush(using: backend.ops)

        XCTAssertFalse(flushed, "a failed save must not report the note as safe to close")
        XCTAssertTrue(saver.isFailed)
        XCTAssertTrue(saver.hasUnsavedChanges, "the edit is still pending, not silently dropped")
        XCTAssertEqual(saver.text, "Old, edited")

        let retried = await saver.flush(using: backend.ops)
        XCTAssertTrue(retried)
        XCTAssertEqual(saver.state, .saved)
        XCTAssertEqual(backend.updates.map(\.body), ["Old, edited"])
    }

    func test_failedCreate_leavesNoIdAndRetriesAsCreate() async {
        let backend = FakeBackend()
        backend.failNext = true
        let saver = NoteSaver(noteId: nil, text: "")
        saver.text = "Idea"

        let first = await saver.save(using: backend.ops)
        XCTAssertFalse(first)
        XCTAssertNil(saver.noteId)
        let second = await saver.save(using: backend.ops)
        XCTAssertTrue(second)
        XCTAssertEqual(saver.noteId, 42)
        XCTAssertEqual(backend.creates, ["Idea", "Idea"])
        XCTAssertTrue(backend.updates.isEmpty)
    }

    func testCreateRetryReusesExactPayloadAndKeyThenPatchesNewerText() async {
        let backend = FakeBackend()
        backend.holdCreate = true
        backend.failNext = true
        let saver = NoteSaver(noteId: nil, text: "")
        saver.text = "Idea"
        let first = Task { await saver.save(using: backend.ops) }
        await spin { !backend.heldCreates.isEmpty }
        saver.text = "Idea, continued"
        backend.holdCreate = false
        backend.releaseCreates()
        let firstOK = await first.value
        XCTAssertFalse(firstOK)
        let retryOK = await saver.flush(using: backend.ops)
        XCTAssertTrue(retryOK)
        XCTAssertEqual(backend.creates, ["Idea", "Idea"], "retry the POST that may already have committed")
        XCTAssertEqual(backend.createKeys.count, 2)
        XCTAssertEqual(backend.createKeys.first, backend.createKeys.last)
        XCTAssertEqual(backend.updates.map(\.body), ["Idea, continued"])
        XCTAssertFalse(saver.hasUnsavedChanges)
    }

    func testRepeatedComposeIntentDuringCreateKeepsSessionAndUpdatesSameNote() async throws {
        let composer = NoteComposer(), backend = FakeBackend()
        backend.holdCreate = true
        composer.begin()
        let original = try XCTUnwrap(composer.session)
        original.text = "Idea"
        let first = Task { await original.save(using: backend.ops) }
        await spin { !backend.heldCreates.isEmpty }
        composer.begin() // new intent / recreated shell's presentation request
        let presentedAgain = try XCTUnwrap(composer.session)
        XCTAssertTrue(presentedAgain === original)
        presentedAgain.text = "Idea, continued"
        let finish = Task { await presentedAgain.flush(using: backend.ops) }
        backend.holdCreate = false
        backend.releaseCreates()
        _ = await first.value; _ = await finish.value
        XCTAssertEqual(backend.creates, ["Idea"])
        XCTAssertEqual(backend.updates.map(\.id), [42])
        XCTAssertEqual(backend.updates.last?.body, "Idea, continued")
        composer.session = nil // an actual dismissal ends the compose session
        composer.begin()
        XCTAssertNotEqual(composer.session?.id, original.id)
        XCTAssertEqual(composer.session?.text, "")
    }

    func testCancelledAutosaveStopsAfterInflightCreateAndLeavesNewerTextForNextPause() async {
        let backend = FakeBackend()
        backend.holdCreate = true
        let saver = NoteSaver(noteId: nil, text: "")
        saver.text = "Prefix"
        let debounce = Task { await saver.autosave(using: backend.ops) }
        await spin { !backend.heldCreates.isEmpty }
        saver.text = "Prefix continued"
        debounce.cancel()
        backend.holdCreate = false
        backend.releaseCreates()
        _ = await debounce.value
        XCTAssertEqual(saver.noteId, 42, "the committed request must finish despite cancellation")
        XCTAssertTrue(backend.updates.isEmpty, "new typing belongs to a newer debounce")
        XCTAssertTrue(saver.hasUnsavedChanges)
        _ = await saver.autosave(using: backend.ops)
        XCTAssertEqual(backend.updates.map(\.body), ["Prefix continued"])
    }

    func testCancelledAutosaveWaitingBehindCreateDoesNotStartPatch() async {
        let backend = FakeBackend(); backend.holdCreate = true
        let saver = NoteSaver(noteId: nil, text: ""); saver.text = "Prefix"
        let first = Task { await saver.save(using: backend.ops) }
        await spin { !backend.heldCreates.isEmpty }
        saver.text = "Prefix continued"
        let queued = Task { await saver.autosave(using: backend.ops) }
        for _ in 0..<20 { await Task.yield() }
        queued.cancel()
        backend.holdCreate = false; backend.releaseCreates()
        _ = await first.value; _ = await queued.value
        XCTAssertTrue(backend.updates.isEmpty)
        XCTAssertTrue(saver.hasUnsavedChanges)
        _ = await saver.flush(using: backend.ops)
        XCTAssertEqual(backend.updates.map(\.body), ["Prefix continued"])
    }

    func testExplicitFlushCompletesLatestTextEvenWhenCallerWasCancelled() async {
        let backend = FakeBackend()
        backend.holdCreate = true
        let saver = NoteSaver(noteId: nil, text: "")
        saver.text = "Prefix"
        let close = Task { await saver.flush(using: backend.ops) }
        await spin { !backend.heldCreates.isEmpty }
        saver.text = "Prefix continued"
        close.cancel()
        backend.holdCreate = false
        backend.releaseCreates()
        _ = await close.value
        XCTAssertFalse(saver.hasUnsavedChanges)
        XCTAssertEqual(backend.updates.map(\.body), ["Prefix continued"])
    }

    func test_blankField_isNeverSavedOverContent() async {
        let backend = FakeBackend()
        let saver = NoteSaver(noteId: 7, text: "Keep me")
        saver.text = "   \n "
        XCTAssertFalse(saver.hasUnsavedChanges)
        let flushed = await saver.flush(using: backend.ops)
        XCTAssertTrue(flushed)
        XCTAssertTrue(backend.updates.isEmpty)
    }
}

@MainActor
final class UnsavedNoteEditsTests: XCTestCase {
    private func parked(id: Int? = nil, text: String) -> NoteSaver {
        let saver = NoteSaver(noteId: id, text: ""); saver.text = text; return saver
    }

    func test_parkingANewerEditOfTheSameNoteReplacesTheOlder() {
        let store = NotesStore()
        store.park(saver: parked(id: 3, text: "v1"))
        store.park(saver: parked(text: "draft"))
        store.park(saver: parked(id: 3, text: "v2"))
        XCTAssertEqual(store.unsavedEdits.map(\.text), ["draft", "v2"])
        store.discardUnsavedEdits()
        XCTAssertTrue(store.unsavedEdits.isEmpty)
    }
}
