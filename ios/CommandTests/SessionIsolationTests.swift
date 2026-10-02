import XCTest
@testable import Command

private final class SessionWireProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var held: SessionWireProtocol?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var onRequest: (() -> Void)?
    static func reset() { lock.withLock { held = nil; requests = []; onRequest = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let callback = Self.lock.withLock {
            Self.held = self; Self.requests.append(request); return Self.onRequest
        }
        callback?()
    }
    override func stopLoading() {}
    static func fail() {
        let pending = lock.withLock { held }
        pending?.client?.urlProtocol(pending!, didFailWithError: URLError(.networkConnectionLost))
    }
    static func respond(status: Int, cookie: String? = nil) {
        guard let pending = lock.withLock({ held }) else { return }
        var headers = ["Content-Type": "application/json"]
        if let cookie { headers["Set-Cookie"] = "command_session=\(cookie); Path=/; HttpOnly" }
        let body = status == 401 ? "{\"error\":{\"code\":\"auth_failed\",\"message\":\"Expired\"}}" : """
        {"id":42,"account_id":1,"body":"Idea","title":"Idea","title_status":"user",
        "source":"typed","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}
        """
        pending.client?.urlProtocol(pending, didReceive: HTTPURLResponse(url: pending.request.url!, statusCode: status,
                                httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        pending.client?.urlProtocol(pending, didLoad: Data(body.utf8))
        pending.client?.urlProtocolDidFinishLoading(pending)
    }
}

@MainActor
final class SessionIsolationTests: XCTestCase {
    private func setup() throws -> (APIClient, HTTPCookieStorage) {
        SessionWireProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionWireProtocol.self]
        let jar = try XCTUnwrap(config.httpCookieStorage)
        let client = APIClient(baseURL: URL(string: "https://session-test.invalid")!, configuration: config)
        setCookie("account-a", jar: jar)
        return (client, jar)
    }
    private func setCookie(_ value: String, jar: HTTPCookieStorage) {
        jar.setCookie(HTTPCookie(properties: [.domain: "session-test.invalid", .path: "/",
                                            .name: "command_session", .value: value])!)
    }
    private func held() -> XCTestExpectation {
        let started = expectation(description: "request suspended")
        SessionWireProtocol.onRequest = { started.fulfill() }
        return started
    }
    private func result(_ client: APIClient) async -> Error? {
        do { _ = try await client.createNote(body: "Private account A capture"); return nil }
        catch { return error }
    }

    func testKeyedRetryNeverSwitchesToNewAccountsCookie() async throws {
        let (client, jar) = try setup(), started = held()
        let operation = Task { await result(client) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(SessionWireProtocol.requests.first?.value(forHTTPHeaderField: "Cookie"), "command_session=account-a")
        SessionWireProtocol.fail()
        client.clearSessionCookies()
        setCookie("account-b", jar: jar)
        let error = await operation.value
        XCTAssertEqual((error as? URLError)?.code, .cancelled)
        XCTAssertEqual(SessionWireProtocol.requests.count, 1, "no request may be retried under account B")
    }

    func testLateResponseCannotReplaceNewAccountsCookieOrReturnOldData() async throws {
        let (client, jar) = try setup(), started = held()
        let operation = Task { await result(client) }
        await fulfillment(of: [started], timeout: 2)
        client.clearSessionCookies(); setCookie("account-b", jar: jar)
        SessionWireProtocol.respond(status: 201, cookie: "account-a-renewed")
        let error = await operation.value
        XCTAssertEqual((error as? URLError)?.code, .cancelled)
        XCTAssertEqual(jar.cookies?.first(where: { $0.name == "command_session" })?.value, "account-b")
    }

    func testCookieChangeFromAnotherClientAlsoInvalidatesOldResponse() async throws {
        let (client, jar) = try setup(), started = held()
        let operation = Task { await result(client) }
        await fulfillment(of: [started], timeout: 2)
        // Separate APIClient instances (for example App Intents) share the cookie jar.
        setCookie("account-b", jar: jar)
        SessionWireProtocol.respond(status: 201, cookie: "account-a-renewed")
        let error = await operation.value
        XCTAssertEqual((error as? URLError)?.code, .cancelled)
        XCTAssertEqual(jar.cookies?.first(where: { $0.name == "command_session" })?.value, "account-b")
    }

    func testLateUnauthorizedCannotExpireNewSession() async throws {
        let (client, jar) = try setup(), started = held()
        let unauthorized = expectation(description: "stale rejection ignored"); unauthorized.isInverted = true
        client.onUnauthorized = { _ in unauthorized.fulfill() }
        let operation = Task { await result(client) }
        await fulfillment(of: [started], timeout: 2)
        client.clearSessionCookies(); setCookie("account-b", jar: jar)
        SessionWireProtocol.respond(status: 401)
        _ = await operation.value
        await fulfillment(of: [unauthorized], timeout: 0.1)
    }

    func testCurrentSessionStillAcceptsSuccessAndCookieRenewal() async throws {
        let (client, jar) = try setup(), started = held()
        let operation = Task { await result(client) }
        await fulfillment(of: [started], timeout: 2)
        SessionWireProtocol.respond(status: 201, cookie: "account-a-renewed")
        let error = await operation.value
        XCTAssertNil(error)
        XCTAssertEqual(jar.cookies?.first(where: { $0.name == "command_session" })?.value, "account-a-renewed")
    }

    func testCurrentRejectionCarriesIdentityThatExpiresBeforeQueuedUIHandler() async throws {
        let (client, jar) = try setup(), started = held()
        let rejected = expectation(description: "current rejection")
        let identityBox = IdentityBox()
        client.onUnauthorized = { identity in identityBox.set(identity); rejected.fulfill() }
        let operation = Task { await result(client) }
        await fulfillment(of: [started], timeout: 2)
        SessionWireProtocol.respond(status: 401)
        _ = await operation.value
        await fulfillment(of: [rejected], timeout: 2)
        let identity = try XCTUnwrap(identityBox.get())
        XCTAssertTrue(client.isCurrentSession(identity))
        client.clearSessionCookies(); setCookie("account-b", jar: jar)
        XCTAssertFalse(client.isCurrentSession(identity), "the queued main-actor handler must ignore the old rejection")
    }
}

private final class IdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: APIClient.SessionIdentity?
    func set(_ identity: APIClient.SessionIdentity) { lock.withLock { value = identity } }
    func get() -> APIClient.SessionIdentity? { lock.withLock { value } }
}
