import XCTest
@testable import Command

@MainActor
final class NoteRecoveryPersistenceTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func recovery(server: String = "https://example.com", id: Int = 1,
                          created: String = "2026-01-01T00:00:00Z") -> NoteRecoveryStore {
        NoteRecoveryStore(root: root, server: URL(string: server)!,
                          account: Account(id: id, username: "tester", displayName: nil, createdAt: created))
    }
    private func editing(_ store: NotesStore, noteId: Int? = 42, hidden: Bool = false) -> (NoteSaver, UUID) {
        let owner = UUID()
        let saver = store.resumeEditor(saver: NoteSaver(noteId: noteId, text: noteId == nil ? "" : "Saved", hidden: hidden), owner: owner)
        return (saver, owner)
    }

    func testEveryKeystrokeSurvivesRelaunchWithoutDisappearOrFailedSave() throws {
        let disk = recovery(), store = NotesStore(recovery: recovery())
        let (saver, _) = editing(store)
        saver.text = "Saved and an unsent sentence"
        let relaunched = NotesStore(recovery: disk)
        XCTAssertEqual(relaunched.unsavedEdits.first?.text, saver.text)
        XCTAssertEqual(relaunched.unsavedEdits.first?.saver.id, saver.id)
        XCTAssertEqual(relaunched.unsavedEdits.first?.noteId, 42)
        XCTAssertEqual(try disk.loadEdits().edits.count, 1)
    }

    func testParkedAndActiveEditorsRecoverTogetherAndDiscardIsDurable() throws {
        let disk = recovery(), store = NotesStore(recovery: disk)
        let (first, owner) = editing(store, noteId: nil)
        first.text = "New offline note"
        store.releaseEditor(saver: first, owner: owner, park: true)
        let (second, _) = editing(store)
        second.text = "Existing offline edit"
        let relaunched = NotesStore(recovery: recovery())
        XCTAssertEqual(Set(relaunched.unsavedEdits.map(\.text)), [first.text, second.text])
        relaunched.discardUnsavedEdits()
        XCTAssertTrue(try disk.loadEdits().edits.isEmpty)
        XCTAssertTrue(NotesStore(recovery: recovery()).unsavedEdits.isEmpty)
    }

    func testCloseAndExplicitDiscardRemoveOnlyTheirOwnFile() throws {
        let disk = recovery(), store = NotesStore(recovery: disk)
        let (saver, owner) = editing(store)
        saver.text = "Discarded"
        let (other, _) = editing(store, noteId: 43)
        other.text = "Still pending"
        store.releaseEditor(saver: saver, owner: owner, park: false)
        saver.text = "Late callback cannot restore a discarded draft"
        XCTAssertEqual(try disk.loadEdits().edits.map(\.text), [other.text])
    }

    func testSuccessfulSaveRemovesRecoveryButLaterTypingPersistsAgain() async throws {
        let disk = recovery(), store = NotesStore(recovery: disk)
        let (saver, _) = editing(store)
        saver.text = "First edit"
        let ops = NoteSaver.Ops(create: { _, _, _ in 1 }, update: { _, _, _ in })
        let saved = await saver.flush(using: ops)
        XCTAssertTrue(saved)
        XCTAssertTrue(try disk.loadEdits().edits.isEmpty)
        saver.text = "Second edit"
        XCTAssertEqual(try disk.loadEdits().edits.first?.text, "Second edit")
    }

    func testUncertainCreateRecoversOriginalPayloadAndKeyThenPatchesLatestText() async throws {
        let disk = recovery(), store = NotesStore(recovery: disk)
        let (saver, _) = editing(store, noteId: nil)
        saver.text = "Original create"
        let lost = NoteSaver.Ops(create: { _, _, _ in throw URLError(.networkConnectionLost) }, update: { _, _, _ in })
        let saved = await saver.save(using: lost)
        XCTAssertFalse(saved)
        saver.text = "Original create plus offline edits"
        let relaunched = NotesStore(recovery: recovery())
        let resumed = try XCTUnwrap(relaunched.unsavedEdits.first?.saver)
        var calls: [String] = []
        let ops = NoteSaver.Ops(create: { _, body, key in
            XCTAssertEqual(key, saver.id)
            calls.append("create: " + body)
            return 73
        }, update: { id, _, body in
            XCTAssertEqual(id, 73)
            calls.append("update: " + body)
        })
        let ok = await resumed.flush(using: ops)
        XCTAssertTrue(ok)
        XCTAssertEqual(calls, ["create: Original create", "update: Original create plus offline edits"])
        XCTAssertTrue(try disk.loadEdits().edits.isEmpty)
    }

    func testPartialSaveRecoversCreatedIDAndDoesNotCreateAgain() async throws {
        let store = NotesStore(recovery: recovery())
        let (saver, _) = editing(store, noteId: nil)
        saver.text = "Original"
        let ops = NoteSaver.Ops(create: { _, _, _ in
            saver.text = "Newer text during create"
            return 73
        }, update: { _, _, _ in throw URLError(.notConnectedToInternet) })
        let ok = await saver.flush(using: ops)
        XCTAssertFalse(ok)
        let relaunched = NotesStore(recovery: recovery())
        let resumed = try XCTUnwrap(relaunched.unsavedEdits.first?.saver)
        XCTAssertEqual(resumed.noteId, 73)
        XCTAssertEqual(resumed.lastSavedText, "Original")
        let retry = NoteSaver.Ops(create: { _, _, _ in XCTFail("must not recreate"); return 99 }, update: { id, _, body in
            XCTAssertEqual(id, 73); XCTAssertEqual(body, "Newer text during create")
        })
        let saved = await resumed.flush(using: retry)
        XCTAssertTrue(saved)
    }

    func testDraftRecoversAndClearingItRemovesTheRecoveryCopy() throws {
        let disk = recovery(), store = NotesStore(recovery: disk)
        store.draft = "A quick thought"
        let relaunched = NotesStore(recovery: recovery())
        XCTAssertEqual(relaunched.draft, store.draft)
        relaunched.draft = ""
        XCTAssertNil(try disk.loadDraft())
    }

    func testAccountServerAndRecreatedAccountAreIsolated() {
        let original = NotesStore(recovery: recovery())
        original.draft = "Private capture"
        let (saver, _) = editing(original); saver.text = "Private edit"
        for disk in [recovery(id: 2), recovery(server: "https://other.example.com"),
                     recovery(server: "https://example.com/another"), recovery(created: "2026-02-01T00:00:00Z")] {
            let other = NotesStore(recovery: disk)
            XCTAssertEqual(other.draft, "")
            XCTAssertTrue(other.unsavedEdits.isEmpty)
        }
        original.deactivate()
        XCTAssertEqual(NotesStore(recovery: recovery()).draft, "Private capture")
    }

    func testOldSessionCompletionCannotEraseReauthenticatedEditorsRecovery() async throws {
        let disk = recovery(), original = NotesStore(recovery: disk)
        let (oldSaver, _) = editing(original)
        oldSaver.text = "Before sign-out"
        original.deactivate()
        let replacement = NotesStore(recovery: recovery())
        let resumed = try XCTUnwrap(replacement.unsavedEdits.first?.saver)
        resumed.text = "New edits after reauthentication"
        oldSaver.markSaved("Before sign-out")
        original.draft = "A stale quick capture"
        XCTAssertEqual(try disk.loadEdits().edits.first?.text, resumed.text)
        XCTAssertNil(try disk.loadDraft())
    }

    func testAccountDeletionRemovesRecoveryAndLateChangesCannotRecreateIt() throws {
        let disk = recovery(), store = NotesStore(recovery: disk)
        store.draft = "Private capture"
        let (saver, _) = editing(store); saver.text = "Private edit"
        store.deactivate(deleteRecovery: true)
        saver.text = "Late editor change"; store.draft = "Late capture change"
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.directory.path))
    }

    func testHiddenEditKeepsItsVeilAcrossRelaunch() throws {
        let store = NotesStore(recovery: recovery())
        let (saver, _) = editing(store, hidden: true); saver.text = "Private edit"
        let resumed = try XCTUnwrap(NotesStore(recovery: recovery()).unsavedEdits.first?.saver)
        XCTAssertTrue(resumed.hidden)
    }

    func testCorruptEditDoesNotHideOtherRecoveryFilesOrGetDeleted() throws {
        let disk = recovery(), store = NotesStore(recovery: disk)
        let (saver, _) = editing(store); saver.text = "Intact"
        let corrupt = disk.directory.appendingPathComponent("edit-damaged.json")
        try Data("bad json".utf8).write(to: corrupt)
        let relaunched = NotesStore(recovery: recovery())
        XCTAssertEqual(relaunched.unsavedEdits.first?.text, "Intact")
        XCTAssertNotNil(relaunched.recoveryError)
        relaunched.discardUnsavedEdits()
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }

    func testDiskFailureIsVisibleAndDoesNotPretendRecoverySucceeded() throws {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: root)
        let store = NotesStore(recovery: recovery())
        let (saver, _) = editing(store); saver.text = "Keep this in memory"
        XCTAssertEqual(saver.text, "Keep this in memory")
        XCTAssertNotNil(store.recoveryError)
    }

    func testRepeatedAccountActivationKeepsActiveEditorAndRecoveryOwnership() throws {
        let client = APIClient(baseURL: URL(string: "https://example.com")!)
        let app = AppState(client: client, noteRecoveryRoot: root)
        let account = Account(id: 1, username: "tester", displayName: nil, createdAt: "2026-01-01T00:00:00Z")
        app.activateNotes(for: account)
        let original = app.notes
        let (saver, _) = editing(original)
        saver.text = "Before another window"
        app.activateNotes(for: account)
        XCTAssertTrue(app.notes === original, "same-account bootstrap must not retire open editors")
        saver.text = "Typed after another window opens"
        XCTAssertEqual(try recovery().loadEdits().edits.first?.text, saver.text)
        app.activateNotes(for: Account(id: 2, username: "second", displayName: nil, createdAt: account.createdAt))
        XCTAssertFalse(app.notes === original)
        XCTAssertTrue(app.notes.unsavedEdits.isEmpty)
    }

    func testSessionTeardownRetiresStoreAndDropsParkedEditsFromNextAccount() async {
        let client = APIClient(baseURL: URL(string: "https://example.invalid")!)
        let app = AppState(client: client, noteRecoveryRoot: root)
        let previous = app.notes
        let saver = NoteSaver(noteId: nil, text: ""); saver.text = "Previous account"
        previous.park(saver: saver)
        await app.forgetDeletedAccount()
        XCTAssertFalse(app.notes === previous)
        XCTAssertTrue(app.notes.unsavedEdits.isEmpty)
        let created = await previous.create(title: nil, body: "Must not send", client: client)
        XCTAssertNil(created)
        XCTAssertNil(previous.errorMessage, "retired store must not even try the transport")
    }
}
