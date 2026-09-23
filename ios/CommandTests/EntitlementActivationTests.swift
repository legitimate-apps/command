//
//  EntitlementActivationTests.swift
//  CommandTests
//
//  The server learns about a purchase from RevenueCat's webhook — a server-to-server call whose
//  timing the app does not control. The paywall used to refresh the entitlement once, the instant
//  `purchase()` returned, which races that webhook and usually loses.
//
//  Losing is not cosmetic. `resolveGate` deliberately trusts StoreKit's `isSubscribed` so the
//  paywall doesn't linger over a completed purchase, so the chat opens — and then the server runs
//  its own `is_active` check on the first turn and answers `subscription_required`. A user who
//  has just paid is told "Subscribe to Command Pro to use the assistant."
//

import XCTest
@testable import Command

@MainActor
final class EntitlementActivationTests: XCTestCase {

    func testStopsAsSoonAsTheServerMirrorLands() async {
        var checks = 0
        var sleeps: [Int] = []
        let attempts = await AppState.pollUntilActive(
            attempts: 6,
            sleep: { sleeps.append($0) },
            check: { checks += 1; return checks == 3 }   // webhook lands before the third probe
        )
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(checks, 3, "must stop probing the moment it is active")
        XCTAssertEqual(sleeps, [400, 800], "and must not sleep after the successful check")
    }

    func testTheCommonCaseCostsOneProbeAndNoDelay() async {
        // The mirror is usually already there by the time the sheet closes. That path must not
        // pay any backoff at all.
        var sleeps: [Int] = []
        let attempts = await AppState.pollUntilActive(
            attempts: 6, sleep: { sleeps.append($0) }, check: { true }
        )
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sleeps, [], "a purchase whose mirror already landed must return immediately")
    }

    func testAWebhookThatNeverArrivesIsBoundedNotASpin() async {
        var checks = 0
        var sleeps: [Int] = []
        let attempts = await AppState.pollUntilActive(
            attempts: 6, sleep: { sleeps.append($0) }, check: { checks += 1; return false }
        )
        XCTAssertEqual(attempts, 6)
        XCTAssertEqual(checks, 6, "bounded — the server stays the authority and surfaces its own error")
        XCTAssertEqual(sleeps, [400, 800, 1600, 3200, 3200, 3200])
        XCTAssertEqual(sleeps.reduce(0, +), 12_400, "~12s worst case, not an unbounded wait")
    }

    func testBackoffIsMonotonicAndClamped() {
        let schedule = (0..<8).map { AppState.activationBackoffMs(attempt: $0) }
        XCTAssertEqual(schedule, [400, 800, 1600, 3200, 3200, 3200, 3200, 3200])
        XCTAssertEqual(zip(schedule, schedule.dropFirst()).filter { $0 > $1 }.count, 0,
                       "backoff must never decrease")
    }

    func testZeroAttemptsProbesNothing() async {
        var checks = 0
        let attempts = await AppState.pollUntilActive(
            attempts: 0, sleep: { _ in }, check: { checks += 1; return true }
        )
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(checks, 0)
    }
}
