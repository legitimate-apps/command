//
//  BillingTests.swift
//  CommandTests
//
//  Covers the entitlement wire decoding and the Assistant access-gate decision
//  (AppState.resolveGate) deterministically — no RevenueCat, no network, no UI.
//

import XCTest
@testable import Command

final class BillingTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: Wire decoding (server EntitlementStatus, snake_case)

    func testEntitlementDecoding() throws {
        let json = #"""
        {"active":true,"requires_subscription":true,"product_id":"command_pro_monthly",
         "price_display":"$19.99/mo","trial_days":7,"consent_given":true,"status":"active",
         "period_type":"trial","expires_at":"2026-06-25T00:00:00Z","will_renew":true}
        """#
        let e = try decoder.decode(AgentEntitlement.self, from: Data(json.utf8))
        XCTAssertTrue(e.active)
        XCTAssertTrue(e.requiresSubscription)
        XCTAssertEqual(e.productId, "command_pro_monthly")
        XCTAssertEqual(e.priceDisplay, "$19.99/mo")
        XCTAssertEqual(e.trialDays, 7)
        XCTAssertTrue(e.consentGiven)
        XCTAssertEqual(e.status, "active")
        XCTAssertEqual(e.periodType, "trial")
        XCTAssertEqual(e.expiresAt, "2026-06-25T00:00:00Z")
        XCTAssertTrue(e.willRenew)
    }

    func testEntitlementDecodingNulls() throws {
        let json = #"""
        {"active":false,"requires_subscription":false,"product_id":"p","price_display":"$x",
         "trial_days":7,"consent_given":false,"status":"none","period_type":null,
         "expires_at":null,"will_renew":false}
        """#
        let e = try decoder.decode(AgentEntitlement.self, from: Data(json.utf8))
        XCTAssertNil(e.periodType)
        XCTAssertNil(e.expiresAt)
        XCTAssertFalse(e.consentGiven)
    }

    // MARK: Gate decision

    private func ent(active: Bool = false, requires: Bool = false,
                     consent: Bool = true, status: String = "none") -> AgentEntitlement {
        AgentEntitlement(
            active: active, requiresSubscription: requires, productId: "command_pro_monthly",
            priceDisplay: "$19.99/mo", trialDays: 7, consentGiven: consent, status: status,
            periodType: nil, expiresAt: nil, willRenew: false
        )
    }

    @MainActor
    func testGateLoadingWhenUnknown() {
        XCTAssertEqual(AppState.resolveGate(entitlement: nil, isSubscribed: false), .loading)
    }

    @MainActor
    func testGateConsentPrecedesEverything() {
        // No consent → consent screen, even if subscribed and gating is on.
        XCTAssertEqual(AppState.resolveGate(entitlement: ent(consent: false), isSubscribed: false), .consent)
        XCTAssertEqual(
            AppState.resolveGate(entitlement: ent(requires: true, consent: false), isSubscribed: true),
            .consent
        )
    }

    @MainActor
    func testGateReadyWhenNotGating() {
        // Consent given and the server isn't requiring a subscription → straight to chat.
        XCTAssertEqual(AppState.resolveGate(entitlement: ent(consent: true), isSubscribed: false), .ready)
    }

    @MainActor
    func testGatePaywallWhenGatingAndNotEntitled() {
        XCTAssertEqual(
            AppState.resolveGate(entitlement: ent(requires: true, consent: true), isSubscribed: false),
            .paywall
        )
    }

    @MainActor
    func testGateReadyWhenServerEntitled() {
        XCTAssertEqual(
            AppState.resolveGate(entitlement: ent(active: true, requires: true, consent: true, status: "active"),
                                 isSubscribed: false),
            .ready
        )
    }

    @MainActor
    func testGateReadyWhenLocallySubscribed() {
        // RevenueCat flips isSubscribed instantly post-purchase, before the server
        // webhook lands — the gate must open on that optimistic signal too.
        XCTAssertEqual(
            AppState.resolveGate(entitlement: ent(requires: true, consent: true), isSubscribed: true),
            .ready
        )
    }
}
