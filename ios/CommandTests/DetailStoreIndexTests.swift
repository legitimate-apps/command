//
//  DetailStoreIndexTests.swift
//  Command
//
//  An index captured before an `await` must never be reused after it.
//
//  `toggle` and `rename` each did `let i = items.firstIndex(of:)` and then, after awaiting the
//  network, wrote `items[i] = …`. The list can change during that await — a concurrent `load()`,
//  another toggle, an `add`, a `delete` — after which `i` addresses a different row or none at
//  all. Two distinct failures followed: the wrong row silently took another row's data, and on
//  the success path (which had no bounds check at all, unlike the rollback) a shrunken array made
//  it an out-of-bounds assignment, i.e. a crash.
//
//  Reproducing that needs the mutation to land *while the store is suspended*, which scheduling
//  luck can't be trusted to arrange: `toggle` is `@MainActor`, so a plain `Task { }` plus a
//  same-tick mutation lets the mutation run FIRST and the bug never occurs. So these drive a
//  gated `URLProtocol` — the response is held until the test says go, which pins the mutation
//  inside the suspension window every run. It also lets these exercise the SUCCESS path, which
//  is the one that crashes; an offline client can only ever reach the rollback.
//

import XCTest
@testable import Command

/// A stub transport that parks each request until the test releases it.
///
/// `startLoading` runs on a URLSession worker thread, never the main thread, so blocking it is
/// safe — and it is what holds the store suspended at its `await` while the test mutates `items`.
private final class GatedStubProtocol: URLProtocol {
    /// Signalled once a request reaches the loader: the store is now parked at its `await`.
    nonisolated(unsafe) static var started = DispatchSemaphore(value: 0)
    /// Signalled by the test once it has finished mutating, allowing the response to land.
    nonisolated(unsafe) static var release = DispatchSemaphore(value: 0)
    nonisolated(unsafe) static var body = Data()

    static func reset(body: Data) {
        started = DispatchSemaphore(value: 0)
        release = DispatchSemaphore(value: 0)
        self.body = body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.started.signal()
        Self.release.wait()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class DetailStoreIndexTests: XCTestCase {

    private func stubbedClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GatedStubProtocol.self]
        return APIClient(baseURL: URL(string: "http://stub.invalid")!, configuration: config)
    }

    private func item(_ id: Int, _ text: String, done: Bool = false) -> TaskItem {
        TaskItem(id: id, parentType: "assignment", parentId: 1, text: text, done: done,
                 source: "user", position: id, createdAt: "2026-08-03T00:00:00Z",
                 updatedAt: "2026-08-03T00:00:00Z")
    }

    /// The server's reply, in the wire shape (`convertFromSnakeCase`) the client decodes.
    private func itemJSON(_ id: Int, _ text: String, done: Bool, position: Int) -> Data {
        Data("""
        {"id": \(id), "parent_type": "assignment", "parent_id": 1, "text": "\(text)", \
        "done": \(done), "source": "user", "position": \(position), \
        "created_at": "2026-08-03T00:00:00Z", "updated_at": "2026-08-03T00:00:00Z"}
        """.utf8)
    }

    /// Yield the main actor until the store is parked at its network `await`.
    ///
    /// The wait itself has to happen off the main thread: `toggle` is `@MainActor`, so blocking
    /// the main thread here would stop it ever reaching the request and deadlock the test.
    private func awaitRequestInFlight() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                GatedStubProtocol.started.wait()
                cont.resume()
            }
        }
    }

    func testToggleWritesToTheRowItStartedOnEvenAfterAReorder() async {
        GatedStubProtocol.reset(body: itemJSON(1, "alpha", done: true, position: 1))
        let store = DetailStore(parentType: "assignment", parentId: 1, title: "T", notes: "")
        let a = item(1, "alpha"), b = item(2, "bravo"), c = item(3, "charlie")
        store.items = [a, b, c]

        let inFlight = Task { await store.toggle(a, client: stubbedClient()) }
        await awaitRequestInFlight()
        store.items = [c, b, a]          // a concurrent load() returning a re-sorted list
        GatedStubProtocol.release.signal()
        await inFlight.value

        // With the stale index the server's `alpha` landed in slot 0, obliterating `charlie`
        // and leaving `alpha` duplicated.
        XCTAssertEqual(store.items.map(\.id), [3, 2, 1], "row order must survive the round trip")
        XCTAssertTrue(store.items.contains { $0.id == 3 }, "charlie must not be overwritten")
        XCTAssertEqual(store.items.first { $0.id == 1 }?.done, true, "alpha must still get its update")
    }

    func testToggleDoesNotResurrectOrCrashOnARowDeletedMidRequest() async {
        // The success path had no bounds check at all, so this was `items[0] = …` on an empty
        // array — a crash, not a glitch. Re-finding by id makes it a no-op, which is also the
        // correct outcome: a row the user deleted must not come back.
        GatedStubProtocol.reset(body: itemJSON(3, "charlie", done: true, position: 3))
        let store = DetailStore(parentType: "assignment", parentId: 1, title: "T", notes: "")
        let a = item(1, "alpha"), b = item(2, "bravo"), c = item(3, "charlie")
        store.items = [a, b, c]

        let inFlight = Task { await store.toggle(c, client: stubbedClient()) }
        await awaitRequestInFlight()
        store.items = []                 // a delete-all / empty reload landing mid-request
        GatedStubProtocol.release.signal()
        await inFlight.value

        XCTAssertEqual(store.items, [], "a row deleted mid-request must not be resurrected")
    }

    func testRenameAlsoTargetsTheRowByIdentity() async {
        GatedStubProtocol.reset(body: itemJSON(1, "renamed", done: false, position: 1))
        let store = DetailStore(parentType: "assignment", parentId: 1, title: "T", notes: "")
        let a = item(1, "alpha"), b = item(2, "bravo")
        store.items = [a, b]

        let inFlight = Task { await store.rename(a, to: "renamed", client: stubbedClient()) }
        await awaitRequestInFlight()
        store.items = [b, a]
        GatedStubProtocol.release.signal()
        await inFlight.value

        XCTAssertEqual(store.items.map(\.id), [2, 1], "bravo must not be clobbered by a write at slot 0")
        XCTAssertEqual(store.items.first { $0.id == 2 }?.text, "bravo")
        XCTAssertEqual(store.items.first { $0.id == 1 }?.text, "renamed", "alpha must still get its rename")
    }
}
