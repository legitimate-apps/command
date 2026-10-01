import XCTest
@testable import Command

@MainActor
final class NoteEditorCloseTests: XCTestCase {
    private enum SaveFailure: Error { case offline }

    private func assertReleased(_ saver: NoteSaver, from store: NotesStore) {
        store.discardUnsavedEdits()
        let fallback = NoteSaver(noteId: saver.noteId, text: "Server copy")
        let owner = UUID()
        let reopened = store.resumeEditor(saver: fallback, owner: owner)
        XCTAssertTrue(reopened === fallback, "The disappeared editor's owner must be gone")
        store.releaseEditor(saver: reopened, owner: owner, park: false)
    }

    private func closeWhileDisappearing(succeeds: Bool, afterBlockedClose: Bool = false) async {
        let store = NotesStore()
        let lifetime = NoteEditorLifetime()
        let original = NoteSaver(noteId: 42, text: "Server copy")
        let saver = store.resumeEditor(saver: original, owner: lifetime.owner)
        saver.text = "Retained unsaved edit"
        if afterBlockedClose {
            XCTAssertTrue(lifetime.beginFinish())
            let failedOps = NoteSaver.Ops(create: { _, _, _ in throw SaveFailure.offline },
                                         update: { _, _, _ in throw SaveFailure.offline })
            let saved = await saver.flush(using: failedOps)
            XCTAssertFalse(lifetime.completeClose(saved: saved, saver: saver, store: store))
            XCTAssertTrue(lifetime.closeBlocked, "Visible failed Close offers Retry")
            XCTAssertTrue(store.unsavedEdits.isEmpty)
        }
        let started = expectation(description: "Close flush is in flight")
        var pending: CheckedContinuation<Void, Error>?
        let ops = NoteSaver.Ops(create: { _, _, _ in throw SaveFailure.offline }, update: { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        })
        // This is the view's shared Close/blocked-Retry sequence, using its actual saver and store.
        XCTAssertTrue(lifetime.beginFinish())
        let close = Task { @MainActor in
            let saved = await saver.flush(using: ops)
            return lifetime.completeClose(saved: saved, saver: saver, store: store)
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(lifetime.beginDisappear(), "Close already owns the disappearance flush")
        if succeeds { pending?.resume() } else { pending?.resume(throwing: SaveFailure.offline) }
        let shouldDismiss = await close.value
        XCTAssertFalse(shouldDismiss, "A completion after disappearance must not dismiss a replacement")
        if succeeds {
            XCTAssertTrue(store.unsavedEdits.isEmpty)
            XCTAssertEqual(saver.lastSavedText, "Retained unsaved edit")
        } else {
            XCTAssertEqual(store.unsavedEdits.count, 1)
            XCTAssertTrue(store.unsavedEdits.first?.saver === saver)
            XCTAssertEqual(store.unsavedEdits.first?.text, "Retained unsaved edit")
            XCTAssertTrue(saver.isFailed)
        }
        assertReleased(saver, from: store)
    }

    func testCloseFailureAfterDisappearanceParksTextAndReleasesOwner() async {
        await closeWhileDisappearing(succeeds: false)
    }

    func testCloseSuccessAfterDisappearanceReleasesOwnerWithoutDismissingReplacement() async {
        await closeWhileDisappearing(succeeds: true)
    }

    func testBlockedCloseRetryFailureAfterDisappearanceParksTextAndReleasesOwner() async {
        await closeWhileDisappearing(succeeds: false, afterBlockedClose: true)
    }

    func testVisibleFailedCloseKeepsEditorOwnedForRetry() {
        let store = NotesStore(), lifetime = NoteEditorLifetime()
        let original = NoteSaver(noteId: 42, text: "Server copy")
        let saver = store.resumeEditor(saver: original, owner: lifetime.owner)
        saver.text = "Unsaved edit"
        XCTAssertTrue(lifetime.beginFinish())
        XCTAssertFalse(lifetime.completeClose(saved: false, saver: saver, store: store))
        XCTAssertFalse(lifetime.finished)
        XCTAssertTrue(lifetime.closeBlocked)
        XCTAssertTrue(store.unsavedEdits.isEmpty)
        let fallback = NoteSaver(noteId: 42, text: "Server copy"), reopenedOwner = UUID()
        XCTAssertTrue(store.resumeEditor(saver: fallback, owner: reopenedOwner) === saver)
        store.releaseEditor(saver: saver, owner: reopenedOwner, park: false)
        store.releaseEditor(saver: saver, owner: lifetime.owner, park: false)
    }
}
