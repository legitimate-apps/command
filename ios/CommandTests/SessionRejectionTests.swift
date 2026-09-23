//
//  SessionRejectionTests.swift
//  Command
//
//  "Why am I logged out on my Mac again?" — reported 2026-08-01.
//
//  The server-side half was a session that never slid its expiry. This is the client half, and
//  it was the more damaging of the two: `bootstrap()` probed the session with
//  `try? await client.me()`, which cannot distinguish "the server says this session is invalid"
//  from "we couldn't reach the server at all". Every transient failure — no network on wake, a
//  redeploy mid-launch, a Cloudflare edge hiccup — fell through to `clearPersistedSessionMode()`
//  and the sign-in screen, on a session that was perfectly valid.
//
//  `APIClient.isSessionExpiry` had encoded exactly the right rule for mid-use 401s. Bootstrap
//  was the one path that bypassed it.
//

import XCTest
@testable import Command

@MainActor
final class SessionRejectionTests: XCTestCase {

    func testOnlyAnExplicitAuthFailedEnvelopeCountsAsRejection() {
        XCTAssertTrue(AppState.serverRejectedTheSession(
            APIError.http(status: 401, code: "auth_failed", message: "Session expired.")))
    }

    func testATransportFailureIsNotARejection() {
        // No network on wake, DNS failure, timeout. The single most common cause of the
        // spurious logout, and the one `try?` silently equated with a dead session.
        XCTAssertFalse(AppState.serverRejectedTheSession(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AppState.serverRejectedTheSession(URLError(.timedOut)))
        XCTAssertFalse(AppState.serverRejectedTheSession(URLError(.cannotFindHost)))
    }

    func testAServerOutageIsNotARejection() {
        // A redeploy is exactly this, and this project redeploys often.
        XCTAssertFalse(AppState.serverRejectedTheSession(
            APIError.http(status: 502, code: nil, message: "Bad Gateway")))
        XCTAssertFalse(AppState.serverRejectedTheSession(
            APIError.http(status: 503, code: nil, message: nil)))
    }

    func testAnEdgeChallengeIsNotARejection() {
        // Cloudflare's Browser Integrity Check answers 403 (error 1010), and an edge 401 can
        // arrive with no envelope at all. Neither means the session is dead — treating them as
        // such signs the operator out of a working session, which is the worst false positive
        // available here.
        XCTAssertFalse(AppState.serverRejectedTheSession(
            APIError.http(status: 403, code: nil, message: "error code: 1010")))
        XCTAssertFalse(AppState.serverRejectedTheSession(
            APIError.http(status: 401, code: nil, message: nil)))
        XCTAssertFalse(AppState.serverRejectedTheSession(
            APIError.http(status: 401, code: "rate_limited", message: nil)))
    }

    func testANonHTTPResponseIsNotARejection() {
        XCTAssertFalse(AppState.serverRejectedTheSession(APIError.notHTTP))
    }

    func testUnreachableIsADistinctPhaseFromSignedOut() {
        // If these ever collapse, the bug is back: `.signedOut` is what shows the password
        // prompt, and reaching it requires the server to have actually said so.
        XCTAssertNotEqual(AppState.Phase.unreachable, AppState.Phase.signedOut)
    }

    func testSignOutDropsTheSessionCookieSoShortcutsCantKeepUsingIt() async throws {
        // Sign-out cleared everything DERIVED from the session but left the credential itself
        // in `HTTPCookieStorage.shared` — the same process-wide jar `IntentAPI.makeClient()`
        // builds from. The server-side revoke is best-effort (`try? await client.logout()`) and
        // signing out offline is ordinary, so the session could still be live: Siri and
        // Shortcuts would go on capturing into the account the user just left.
        let app = AppState()
        let url = app.client.baseURL
        let host = try XCTUnwrap(url.host)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: host, .path: "/", .name: "command_session",
            .value: "a-live-session", .secure: "TRUE",
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        XCTAssertTrue(
            HTTPCookieStorage.shared.cookies(for: url)?.contains { $0.name == "command_session" } ?? false,
            "precondition: the jar holds a session for this server")

        await app.forgetDeletedAccount()

        XCTAssertFalse(
            HTTPCookieStorage.shared.cookies(for: url)?.contains { $0.name == "command_session" } ?? false,
            "the credential must not outlive the sign-out")
    }
}
