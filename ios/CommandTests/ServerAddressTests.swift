//
//  ServerAddressTests.swift
//  CommandTests
//
//  Where requests go, and what happens when nothing has been configured yet.
//

import XCTest
@testable import Command

final class ServerAddressTests: XCTestCase {

    // MARK: - Request URLs

    func testAServerPublishedUnderAPrefixKeepsItsPrefix() {
        // Onboarding's health probe kept the prefix while real requests dropped it, so setup
        // reported "Server found" and every call afterwards 404'd.
        let url = APIClient.requestURL(base: URL(string: "https://host.example/command")!,
                                       path: "/api/notes", query: [])
        XCTAssertEqual(url.absoluteString, "https://host.example/command/api/notes")
    }

    func testATrailingSlashOnTheBaseDoesNotDoubleUp() {
        let url = APIClient.requestURL(base: URL(string: "https://host.example/command/")!,
                                       path: "/api/notes", query: [])
        XCTAssertEqual(url.absoluteString, "https://host.example/command/api/notes")
    }

    func testABareHostIsUnchanged() {
        let url = APIClient.requestURL(base: URL(string: "http://192.168.1.10:9071")!,
                                       path: "/api/health", query: [])
        XCTAssertEqual(url.absoluteString, "http://192.168.1.10:9071/api/health")
    }

    func testQueryValuesKeepTheirPlusSigns() {
        let url = APIClient.requestURL(base: URL(string: "https://host.example")!,
                                       path: "/api/notes/search", query: [.init(name: "q", value: "C++")])
        XCTAssertEqual(url.absoluteString, "https://host.example/api/notes/search?q=C%2B%2B")
    }

    func testAPathSegmentWithASpaceIsEncodedInsteadOfCrashing() {
        let url = APIClient.requestURL(base: URL(string: "https://host.example")!,
                                       path: "/api/peers/home lab", query: [])
        XCTAssertEqual(url.absoluteString, "https://host.example/api/peers/home%20lab")
    }

    // MARK: - Local addresses

    func testTailnetAddressesCountAsLocal() {
        let tailnet = ServerSetupGuide.normalizedServerURL("http://100.101.102.103:9071")!
        XCTAssertTrue(ServerSetupGuide.isLocalAddress(tailnet))
        // 100.128+ is outside 100.64.0.0/10 — an ordinary public address.
        let outside = ServerSetupGuide.normalizedServerURL("http://100.128.0.1:9071")!
        XCTAssertFalse(ServerSetupGuide.isLocalAddress(outside))
    }

    // MARK: - Shortcuts before onboarding

    func testAnIntentWithNoServerThrowsInsteadOfCrashing() {
        let key = AppState.urlKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertThrowsError(try IntentAPI.makeClient()) { error in
            guard case CommandIntentError.noServer = error else {
                return XCTFail("expected .noServer, got \(error)")
            }
        }
    }

    // MARK: - Invites

    @MainActor
    func testAnInviteLinkCarriesTheServerAndCannotRepointAConfiguredApp() throws {
        let key = AppState.urlKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("https://mine.example", forKey: key)

        let app = AppState()
        let link = try XCTUnwrap(URL(string: app.inviteLink(token: "tok123")))
        XCTAssertEqual(link.host, "invite")
        let server = URLComponents(url: link, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "server" }?.value
        XCTAssertEqual(server, "https://mine.example", "the invitee needs the inviter's address")

        // A crafted link must not swap the server of an app that already has one.
        app.handleIncomingURL(URL(string: "command://invite/tok456?server=https%3A%2F%2Fevil.example")!)
        XCTAssertEqual(app.pendingInviteToken, "tok456")
        XCTAssertEqual(app.serverURLString, "https://mine.example")
    }
}
