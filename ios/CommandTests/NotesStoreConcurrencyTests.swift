import XCTest
@testable import Command

/// Responses stay held without blocking the loader queue, allowing overlapping POSTs and GETs.
private final class NoteRequestProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var posts: [NoteRequestProtocol] = []
    nonisolated(unsafe) static var onPost: (() -> Void)?
    nonisolated(unsafe) static var hold = true
    nonisolated(unsafe) static var failNextPatch = false
    static let noteJSON = Data("""
    {"id":42,"account_id":1,"body":"Idea","title":"Idea","title_status":"user",
    "source":"typed","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}
    """.utf8)
    static func reset() {
        lock.lock(); defer { lock.unlock() }; posts = []; onPost = nil; hold = true; failNextPatch = false
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return posts.count }
    static func releaseAll() {
        lock.lock(); hold = false; let pending = posts; lock.unlock()
        pending.forEach { $0.respond(Self.noteJSON) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "POST" {
            Self.lock.lock()
            Self.posts.append(self); let callback = Self.onPost; let held = Self.hold
            Self.lock.unlock(); callback?()
            if !held { respond(Self.noteJSON) }
        } else if request.httpMethod == "GET" {
            respond(Data("{\"items\":[".utf8) + Self.noteJSON + Data("],\"next_cursor\":null}".utf8))
        } else {
            Self.lock.lock(); let fail = Self.failNextPatch; Self.failNextPatch = false; Self.lock.unlock()
            respond(Self.noteJSON, status: fail ? 500 : 200)
        }
    }
    func respond(_ body: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                              httpVersion: nil, headerFields: ["Content-Type":"application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class NotesStoreConcurrencyTests: XCTestCase {
    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NoteRequestProtocol.self]
        return APIClient(baseURL: URL(string: "http://stub.invalid")!, configuration: config)
    }
    private func started() -> XCTestExpectation {
        let e = expectation(description: "first POST suspended")
        NoteRequestProtocol.onPost = { e.fulfill() }; return e
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    func testDraftDoubleTapStartsOnlyOneCreate() async {
        NoteRequestProtocol.reset()
        let store = NotesStore(), client = client(), e = started(); store.draft = "Idea"
        let first = Task { await store.saveDraft(client: client) }
        await fulfillment(of: [e], timeout: 2); NoteRequestProtocol.onPost = nil
        let second = Task { await store.saveDraft(client: client) }
        await settle(); XCTAssertEqual(NoteRequestProtocol.count, 1)
        NoteRequestProtocol.releaseAll(); _ = await first.value; _ = await second.value
    }
    func testDraftTypedDuringSendIsNotErasedByResponse() async {
        NoteRequestProtocol.reset()
        let store = NotesStore(), client = client(), e = started(); store.draft = "Idea"
        let send = Task { await store.saveDraft(client: client) }
        await fulfillment(of: [e], timeout: 2); store.draft = "Next idea"
        NoteRequestProtocol.releaseAll(); _ = await send.value
        XCTAssertEqual(store.draft, "Next idea")
    }
    func testRetryDoubleTapStartsOnlyOneCreateForParkedComposer() async {
        NoteRequestProtocol.reset()
        let store = NotesStore(), client = client(), e = started(); store.park(noteId: nil, text: "Idea")
        let first = Task { await store.retryUnsavedEdits(client: client) }
        await fulfillment(of: [e], timeout: 2); NoteRequestProtocol.onPost = nil
        let second = Task { await store.retryUnsavedEdits(client: client) }
        await settle(); XCTAssertEqual(NoteRequestProtocol.count, 1)
        NoteRequestProtocol.releaseAll(); await first.value; await second.value
        XCTAssertTrue(store.unsavedEdits.isEmpty)
    }
    func testParkedSessionRetainsKeyAndCreatedIDWhenFollowupUpdateFails() async {
        NoteRequestProtocol.reset()
        let store = NotesStore(), client = client(), e = started()
        let saver = NoteSaver(noteId: nil, text: "")
        saver.text = "Idea"
        store.park(saver: saver)
        let retry = Task { await store.retryUnsavedEdits(client: client) }
        await fulfillment(of: [e], timeout: 2)
        XCTAssertEqual(NoteRequestProtocol.posts.first?.request.value(forHTTPHeaderField: "Idempotency-Key"), saver.id.uuidString)
        saver.text = "Idea continued"
        NoteRequestProtocol.failNextPatch = true
        NoteRequestProtocol.releaseAll()
        await retry.value
        XCTAssertEqual(saver.noteId, 42)
        XCTAssertTrue(saver.hasUnsavedChanges)
        XCTAssertEqual(store.unsavedEdits.first?.text, "Idea continued")
        NoteRequestProtocol.onPost = nil
        await store.retryUnsavedEdits(client: client)
        XCTAssertEqual(NoteRequestProtocol.count, 1, "retry must PATCH the already-created note")
        XCTAssertTrue(store.unsavedEdits.isEmpty)
    }

    func testEditParkedDuringRetryIsNotDropped() async {
        NoteRequestProtocol.reset()
        let store = NotesStore(), client = client(), e = started()
        store.park(noteId: nil, text: "Idea")
        let retry = Task { await store.retryUnsavedEdits(client: client) }
        await fulfillment(of: [e], timeout: 2)
        store.park(noteId: nil, text: "Another idea")
        NoteRequestProtocol.releaseAll()
        await retry.value
        XCTAssertEqual(store.unsavedEdits.map(\.text), ["Another idea"])
    }

    func testSelectedNoteSurvivesTemporaryAbsenceFromList() throws {
        let selection = NoteSelection()
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let note = try decoder.decode(Note.self, from: NoteRequestProtocol.noteJSON)
        selection.receive(note)
        selection.receive(nil)
        XCTAssertEqual(selection.note?.id, 42)
        XCTAssertEqual(selection.note?.body, "Idea")
        let anotherSelection = NoteSelection()
        XCTAssertNil(anotherSelection.note, "a different selection must not inherit the cached note")
    }

    func testAllCreatePathsMergeWithSameIDReturnedByConcurrentLoad() async {
        for path in ["composer", "draft", "voice", "duplicate"] {
            NoteRequestProtocol.reset()
            let store = NotesStore(), client = client(), e = started()
            let create = Task {
                switch path {
                case "composer": _ = await store.create(title: "Idea", body: "Idea", client: client)
                case "draft": store.draft = "Idea"; _ = await store.saveDraft(client: client)
                case "voice": _ = await store.saveVoiceNote("Idea", engine: "test", locale: nil, client: client)
                default: _ = await store.duplicate(title: "Idea", body: "Idea", client: client)
                }
            }
            await fulfillment(of: [e], timeout: 2); await store.load(client: client)
            XCTAssertEqual(store.notes.map(\.id), [42])
            NoteRequestProtocol.releaseAll(); await create.value
            XCTAssertEqual(store.notes.map(\.id), [42], path)
        }
    }
}
