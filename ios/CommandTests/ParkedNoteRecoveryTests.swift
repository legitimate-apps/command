import XCTest
@testable import Command

private final class RecoveryWireProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var gets: [RecoveryWireProtocol] = []
    nonisolated(unsafe) static var posts: [RecoveryWireProtocol] = []
    nonisolated(unsafe) static var onGet: (() -> Void)?
    nonisolated(unsafe) static var onPost: (() -> Void)?
    nonisolated(unsafe) static var holdPost = false
    nonisolated(unsafe) static var returnedHidden = false
    static let noteJSON = Data("""
    {"id":42,"account_id":1,"body":"Server copy","title":"Server copy","title_status":"user",
    "source":"typed","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}
    """.utf8)
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        gets = []; posts = []; onGet = nil; onPost = nil; holdPost = false; returnedHidden = false
    }
    static func releaseGets(includesNote: Bool) {
        lock.lock(); let pending = gets; gets = []; lock.unlock()
        let body = Data("{\"items\":[".utf8) + (includesNote ? noteJSON : Data()) + Data("],\"next_cursor\":null}".utf8)
        pending.forEach { $0.respond(body) }
    }
    static func releasePosts() {
        lock.lock(); let pending = posts; posts = []; lock.unlock()
        pending.forEach { $0.respond(noteJSON) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        if request.httpMethod == "GET" {
            Self.gets.append(self); let callback = Self.onGet; Self.lock.unlock(); callback?(); return
        }
        if request.httpMethod == "POST", Self.holdPost {
            Self.posts.append(self); let callback = Self.onPost; Self.lock.unlock(); callback?(); return
        }
        Self.lock.unlock()
        if request.httpMethod == "PATCH" {
            respond(Data(String(decoding: Self.noteJSON, as: UTF8.self).replacingOccurrences(of: "Server copy", with: "Updated").utf8))
        } else { respond(Self.noteJSON) }
    }
    func respond(_ data: Data) {
        let data = Self.returnedHidden
            ? Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"source\":", with: "\"hidden\":true,\"source\":").utf8) : data
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ParkedNoteRecoveryTests: XCTestCase {
    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryWireProtocol.self]
        return APIClient(baseURL: URL(string: "https://recovery-test.invalid")!, configuration: configuration)
    }
    private func note() throws -> Note {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Note.self, from: RecoveryWireProtocol.noteJSON)
    }
    func testHidingAnOfflineEditPersistsItsVeilForRecovery() async throws {
        RecoveryWireProtocol.reset(); RecoveryWireProtocol.returnedHidden = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(id: 1, username: "tester", displayName: nil, createdAt: "2026-01-01T00:00:00Z")
        func disk() -> NoteRecoveryStore {
            NoteRecoveryStore(root: root, server: URL(string: "https://example.com")!, account: account)
        }
        let store = NotesStore(recovery: disk())
        let owner = UUID()
        let saver = store.resumeEditor(saver: NoteSaver(noteId: 42, text: "Saved"), owner: owner)
        saver.text = "Offline private changes"
        let hidden = await store.setHidden(id: 42, hidden: true, client: client())
        XCTAssertTrue(hidden)
        store.releaseEditor(saver: saver, owner: owner, park: true)
        let restored = try XCTUnwrap(NotesStore(recovery: disk()).unsavedEdits.first?.saver)
        XCTAssertTrue(restored.hidden, "review without a server row must not expose a newly hidden note")
    }

    func testReopeningResumesParkedTextAndIdentityAndReparksSameSaver() {
        let store = NotesStore(), original = NoteSaver(noteId: 42, text: "Server copy")
        original.text = "Server copy with offline edits"
        store.park(saver: original)
        let owner = UUID()
        let resumed = store.resumeEditor(saver: NoteSaver(noteId: 42, text: "Server copy"), owner: owner)
        XCTAssertTrue(resumed === original)
        XCTAssertEqual(resumed.text, "Server copy with offline edits")
        XCTAssertEqual(resumed.id, original.id)
        XCTAssertTrue(store.unsavedEdits.isEmpty, "active editor owns the unsaved session")
        resumed.text += " and more"
        store.releaseEditor(saver: resumed, owner: owner, park: true)
        XCTAssertEqual(store.unsavedEdits.count, 1)
        XCTAssertTrue(store.unsavedEdits.first?.saver === original)
        XCTAssertEqual(store.unsavedEdits.first?.text, "Server copy with offline edits and more")
    }
    func testReplacementOwnerKeepsOutgoingSessionAndCannotBeReparkedByOldEditor() {
        let store = NotesStore(), saver = NoteSaver(noteId: 42, text: "Saved")
        let oldOwner = UUID(), newOwner = UUID()
        _ = store.resumeEditor(saver: saver, owner: oldOwner)
        saver.text = "Unsaved latest"
        let resumed = store.resumeEditor(saver: NoteSaver(noteId: 42, text: "Stale"), owner: newOwner)
        store.releaseEditor(saver: saver, owner: oldOwner, park: true)
        XCTAssertTrue(resumed === saver)
        XCTAssertTrue(store.unsavedEdits.isEmpty)
        store.releaseEditor(saver: resumed, owner: newOwner, park: true)
        XCTAssertTrue(store.unsavedEdits.first?.saver === saver)
    }
    func testTwoActiveEditorsKeepRecoveryOwnerWhenOneClosesSuccessfully() {
        let store = NotesStore(), saver = NoteSaver(noteId: 42, text: "Saved")
        let first = UUID(), second = UUID()
        _ = store.resumeEditor(saver: saver, owner: first)
        _ = store.resumeEditor(saver: NoteSaver(noteId: 42, text: "Saved"), owner: second)
        store.releaseEditor(saver: saver, owner: second, park: false)
        saver.text = "First window's later offline edit"
        store.releaseEditor(saver: saver, owner: first, park: true)
        XCTAssertEqual(store.unsavedEdits.first?.text, "First window's later offline edit")
    }
    func testNeverCreatedSessionCanBeReviewedWithoutChangingCreateKey() {
        let store = NotesStore(), composer = NoteComposer(), saver = NoteSaver(noteId: nil, text: "")
        saver.text = "Unsent compose"
        store.park(saver: saver)
        composer.resume(saver)
        XCTAssertTrue(composer.session === saver)
        let resumed = store.resumeEditor(saver: saver, owner: UUID())
        XCTAssertTrue(resumed === saver)
        XCTAssertTrue(store.unsavedEdits.isEmpty)
    }
    func testDiscardCannotRemoveEditsWhileRetryIsInFlight() async {
        RecoveryWireProtocol.reset(); RecoveryWireProtocol.holdPost = true
        let store = NotesStore(), client = client(), saver = NoteSaver(noteId: nil, text: "")
        saver.text = "Unsent"; store.park(saver: saver)
        let started = expectation(description: "retry create held")
        RecoveryWireProtocol.onPost = { started.fulfill() }
        let retry = Task { await store.retryUnsavedEdits(client: client) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.isRetrying)
        store.discardUnsavedEdits()
        XCTAssertEqual(store.unsavedEdits.count, 1)
        RecoveryWireProtocol.releasePosts(); await retry.value
        XCTAssertTrue(store.unsavedEdits.isEmpty)
    }
    func testCreateAndReplacementSurviveLoadSnapshotThatStartedEarlier() async throws {
        for operation in ["create", "update"] {
            RecoveryWireProtocol.reset()
            let store = NotesStore(), client = client()
            if operation == "update" { store.notes = [try note()] }
            let started = expectation(description: "stale snapshot held")
            RecoveryWireProtocol.onGet = { started.fulfill() }
            let load = Task { await store.load(client: client) }
            await fulfillment(of: [started], timeout: 2)
            if operation == "create" { _ = await store.create(title: "Server copy", body: "Server copy", client: client) }
            else { _ = await store.update(id: 42, body: "Updated", client: client) }
            RecoveryWireProtocol.releaseGets(includesNote: operation == "update"); await load.value
            XCTAssertEqual(store.notes.map(\.id), [42], operation)
            if operation == "update" { XCTAssertEqual(store.notes.first?.body, "Updated") }
        }
    }
    func testArchiveDuringLoadDoesNotResurrectSnapshotRow() async throws {
        RecoveryWireProtocol.reset()
        let store = NotesStore(), client = client(); store.notes = [try note()]
        let started = expectation(description: "pre-archive snapshot held")
        RecoveryWireProtocol.onGet = { started.fulfill() }
        let load = Task { await store.load(client: client) }
        await fulfillment(of: [started], timeout: 2)
        await store.archive(id: 42, client: client)
        RecoveryWireProtocol.releaseGets(includesNote: true); await load.value
        XCTAssertTrue(store.notes.isEmpty)
    }
}
