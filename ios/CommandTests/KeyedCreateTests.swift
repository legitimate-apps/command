import XCTest
@testable import Command

private final class CreateWireProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var errors: [URLError.Code] = []
    nonisolated(unsafe) static var statuses: [Int] = []
    static func reset(errors: [URLError.Code] = [], statuses: [Int] = []) {
        lock.lock(); defer { lock.unlock() }
        requests = []; Self.errors = errors; Self.statuses = statuses
    }
    static var creates: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.httpMethod == "POST" }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        // URLSession exposes POST data as a stream to URLProtocol on the simulator.
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close(); recorded.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(recorded)
        let error = request.httpMethod == "GET" || Self.errors.isEmpty ? nil : Self.errors.removeFirst()
        let status = request.httpMethod == "GET" ? 200 : (Self.statuses.isEmpty ? 201 : Self.statuses.removeFirst())
        Self.lock.unlock()
        if let error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let body = request.httpMethod == "GET" ? "[]" : """
        {"id":42,"account_id":1,"body":"Idea","title":"Idea","title_status":"user",
        "source":"typed","schedule_kind":"sporadic","status":"scheduled","priority":0,
        "occurred_at":"2026-10-01T00:00:00Z","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                            httpVersion: nil, headerFields: ["Content-Type":"application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class KeyedCreateTests: XCTestCase {
    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CreateWireProtocol.self]
        return APIClient(baseURL: URL(string: "https://create-test.invalid")!, configuration: config)
    }
    private var keys: [String?] { CreateWireProtocol.creates.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } }

    func testEveryEntityCreateHasFreshKeyPerAction() async throws {
        CreateWireProtocol.reset()
        let client = client()
        for _ in 0..<2 {
            _ = try await client.createNote(body: "Idea")
            _ = try await client.createActivity(ActivityCreateBody(title: "Idea"))
            _ = try await client.createAssignment(AssignmentCreateBody(title: "Idea"))
        }
        XCTAssertEqual(keys.count, 6)
        XCTAssertTrue(keys.allSatisfy { $0 != nil })
        XCTAssertEqual(Set(keys.compactMap { $0 }).count, 6)
    }

    func testTransportRetriesReplaySameRequestAndKey() async throws {
        for path in ["note", "activity", "assignment"] {
            CreateWireProtocol.reset(errors: [.networkConnectionLost, .timedOut])
            let client = client()
            switch path {
            case "note": _ = try await client.createNote(body: "Idea")
            case "activity": _ = try await client.createActivity(ActivityCreateBody(title: "Idea"))
            default: _ = try await client.createAssignment(AssignmentCreateBody(title: "Idea"))
            }
            let requests = CreateWireProtocol.creates
            XCTAssertEqual(requests.count, 3, path)
            XCTAssertNotNil(keys.first!)
            XCTAssertEqual(Set(keys.compactMap { $0 }).count, 1, path)
            XCTAssertEqual(Set(requests.compactMap(\.httpBody)).count, 1, path)
        }
    }

    func testTransportRetryIsBoundedAndPermanentErrorsAreNotRetried() async {
        for (errors, statuses, expected) in [
            ([URLError.Code.timedOut, .timedOut, .timedOut, .timedOut], [], 3),
            ([.cancelled], [], 1), ([.cannotDecodeContentData], [], 1),
            ([], [400], 1), ([], [401], 1), ([], [409], 1), ([], [500], 1)
        ] {
            CreateWireProtocol.reset(errors: errors, statuses: statuses)
            do { _ = try await client().createNote(body: "Idea"); XCTFail("request must fail") }
            catch { XCTAssertEqual(CreateWireProtocol.creates.count, expected) }
        }
    }

    func testEachCaptureDraftReusesFailedKeyResetsOnSuccessAndTextChange() async {
        for mode in ["note", "log", "schedule"] {
            CreateWireProtocol.reset(statuses: [500, 201, 500, 500, 201])
            let notes = NotesStore(), log = LogStore(), schedule = ScheduleStore(), client = client()
            func text(_ text: String) { notes.draft = text; log.draft = text; schedule.draft = text }
            func submit() async -> Bool {
                switch mode {
                case "note": return await notes.saveDraft(client: client)
                case "log": return await log.logDraft(client: client)
                default: return await schedule.addToQueue(client: client)
                }
            }
            text("Idea")
            let first = await submit(); XCTAssertFalse(first)
            let retry = await submit(); XCTAssertTrue(retry)
            text("Idea") // another intended submission of identical text after success
            let next = await submit(); XCTAssertFalse(next)
            text("Changed"); text("Idea") // changing back must still make a fresh intent
            let changed = await submit(); XCTAssertFalse(changed)
            let changedRetry = await submit(); XCTAssertTrue(changedRetry)
            let keys = keys
            XCTAssertEqual(keys.count, 5, mode)
            XCTAssertTrue(keys.allSatisfy { $0 != nil }, mode)
            guard keys.count == 5 else { continue }
            XCTAssertEqual(keys[0], keys[1], mode)
            XCTAssertNotEqual(keys[1], keys[2], mode)
            XCTAssertNotEqual(keys[2], keys[3], mode)
            XCTAssertEqual(keys[3], keys[4], mode)
        }
    }

    func testUnkeyedUpdateDoesNotAutoRetryTransportFailure() async {
        CreateWireProtocol.reset(errors: [.networkConnectionLost])
        do { _ = try await client().updateNote(id: 42, title: "Idea", body: "Idea"); XCTFail("must fail") }
        catch { XCTAssertEqual(CreateWireProtocol.requests.count, 1) }
    }

    func testVoiceFlowRetriesCommittedResponseWithSameKey() async {
        CreateWireProtocol.reset(statuses: [500, 201])
        let flow = VoiceCaptureFlow(removeFile: { _ in }), store = NotesStore(), client = client()
        flow.transcript = "Idea"
        let first = await flow.saveNote { text, engine, key in
            await store.saveVoiceNote(text, engine: engine, locale: nil, idempotencyKey: key, client: client)
                ? nil : "Lost response"
        }
        XCTAssertFalse(first)
        let retry = await flow.saveNote { text, engine, key in
            await store.saveVoiceNote(text, engine: engine, locale: nil, idempotencyKey: key, client: client)
                ? nil : "Lost response"
        }
        XCTAssertTrue(retry)
        XCTAssertNotNil(keys.first!)
        XCTAssertEqual(keys.first!, keys.last!)
        XCTAssertEqual(store.notes.map(\.id), [42])
    }

    func testDuplicateActionsHaveDifferentKeys() async {
        CreateWireProtocol.reset()
        let store = NotesStore(), client = client()
        _ = await store.duplicate(title: "Copy", body: "Idea", client: client)
        _ = await store.duplicate(title: "Copy", body: "Idea", client: client)
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotNil(keys.first!)
        XCTAssertNotEqual(keys.first!, keys.last!)
    }
}

final class CreateAttemptTests: XCTestCase {
    func testPayloadChangesAndExplicitResetStartNewIntent() throws {
        var attempt = CreateAttempt()
        let first = try attempt.key(for: ActivityCreateBody(title: "Idea", actorId: 1))
        XCTAssertEqual(first, try attempt.key(for: ActivityCreateBody(title: "Idea", actorId: 1)))
        let changed = try attempt.key(for: ActivityCreateBody(title: "Idea", actorId: 2))
        XCTAssertNotEqual(first, changed)
        attempt.succeeded(key: first)
        XCTAssertEqual(changed, try attempt.key(for: ActivityCreateBody(title: "Idea", actorId: 2)), "old success cannot clear a newer intent")
        attempt.reset()
        XCTAssertNotEqual(changed, try attempt.key(for: ActivityCreateBody(title: "Idea", actorId: 2)))
    }
}
