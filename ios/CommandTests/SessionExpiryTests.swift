//
//  SessionExpiryTests.swift
//  Command
//
//  What counts as "your session is dead, sign in again". Getting this wrong is expensive
//  in both directions: too eager and a passing edge/proxy 401 signs the operator out of a
//  valid session; too lax and every request fails with a generic error behind a shell that
//  still claims to be signed in.
//

import XCTest
@testable import Command

final class SessionExpiryTests: XCTestCase {
    func testServerAuthFailedOnAnOrdinaryRequestIsSessionExpiry() {
        XCTAssertTrue(APIClient.isSessionExpiry(status: 401, code: "auth_failed", path: "/api/notes"))
    }

    func testUnlabelled401IsNotSessionExpiry() {
        // Cloudflare/WAF/captive-portal 401s carry no `auth_failed` envelope. Signing the
        // operator out on one of these is the false positive this guard exists for.
        XCTAssertFalse(APIClient.isSessionExpiry(status: 401, code: nil, path: "/api/notes"))
        XCTAssertFalse(APIClient.isSessionExpiry(status: 401, code: "rate_limited", path: "/api/notes"))
    }

    func testCredentialEndpointsNeverTearDownASession() {
        // A wrong password on the auth screen is a local error, not the death of a session.
        for path in ["/api/auth/login", "/api/auth/register", "/api/auth/invite"] {
            XCTAssertFalse(
                APIClient.isSessionExpiry(status: 401, code: "auth_failed", path: path),
                "\(path) must not trigger a session teardown"
            )
        }
    }

    func testOtherStatusesAreNotSessionExpiry() {
        for status in [200, 400, 403, 404, 429, 500, 502, 503] {
            XCTAssertFalse(
                APIClient.isSessionExpiry(status: status, code: "auth_failed", path: "/api/notes"),
                "HTTP \(status) must not trigger a session teardown"
            )
        }
    }
}
