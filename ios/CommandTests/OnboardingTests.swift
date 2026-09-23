//
//  OnboardingTests.swift
//  CommandTests
//
//  Command ships with no default server, so the first launch has to teach and then take an
//  address. Two things here are load-bearing enough to pin:
//
//  1. **The upgrade migration.** Builds before 2026-08-05 had a hard-coded default, and an
//     install that never opened the server sheet has no stored URL at all. Removing the default
//     without migrating would, on a routine app update, drop existing users into onboarding and
//     read as "the app logged me out" — the same unforced-logout class the `.unreachable` phase
//     was added to prevent.
//  2. **URL normalisation.** This is the one text field between a new person and a working app.
//     Rejecting a pasted trailing slash or a missing scheme is a wall at the worst moment.
//

import XCTest
@testable import Command

final class OnboardingTests: XCTestCase {

    // MARK: - The upgrade migration

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func sessionCookie(_ domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: "command_session",
                                .value: "live", .secure: "TRUE"])!
    }

    func testAnExistingInstallKeepsTheServerItWasAlreadyUsing() {
        // Evidence of prior use: a persisted session mode (only written after a sign-in) and the
        // session cookie that server set — whose domain is the server.
        let d = freshDefaults("onboarding.upgrade")
        d.set("operatorAccount", forKey: AppState.sessionModeKey)

        AppState.migrateLegacyServerURL(d, cookies: [sessionCookie("command.example.org")])

        XCTAssertEqual(d.string(forKey: AppState.urlKey), "https://command.example.org",
                       "an app update must not re-onboard someone who was already signed in")
    }

    func testNoSessionCookieMeansNoGuess() {
        let d = freshDefaults("onboarding.nocookie")
        d.set("operatorAccount", forKey: AppState.sessionModeKey)
        AppState.migrateLegacyServerURL(d, cookies: [])
        XCTAssertNil(d.string(forKey: AppState.urlKey), "without the cookie there is nothing to recover")
    }

    func testAFreshInstallIsLeftAloneSoItCanOnboard() {
        let d = freshDefaults("onboarding.fresh")
        AppState.migrateLegacyServerURL(d, cookies: [sessionCookie("command.example.org")])
        XCTAssertNil(d.string(forKey: AppState.urlKey),
                     "a new install must choose its own server, not inherit someone else's")
    }

    func testAnExplicitlyChosenServerIsNeverOverwritten() {
        let d = freshDefaults("onboarding.chosen")
        d.set("operatorAccount", forKey: AppState.sessionModeKey)
        d.set("https://mine.example.com", forKey: AppState.urlKey)

        AppState.migrateLegacyServerURL(d, cookies: [sessionCookie("command.example.org")])

        XCTAssertEqual(d.string(forKey: AppState.urlKey), "https://mine.example.com")
    }

    func testTheMigrationIsIdempotent() {
        let d = freshDefaults("onboarding.idempotent")
        d.set("operatorAccount", forKey: AppState.sessionModeKey)
        AppState.migrateLegacyServerURL(d, cookies: [sessionCookie("command.example.org")])
        d.set("https://moved.example.com", forKey: AppState.urlKey)
        AppState.migrateLegacyServerURL(d, cookies: [sessionCookie("command.example.org")])
        XCTAssertEqual(d.string(forKey: AppState.urlKey), "https://moved.example.com")
    }

    func testTheShippedDefaultIsEmptySoNoBuildPhonesHomeToSomeoneElse() {
        XCTAssertTrue(AppState.defaultServerURL.isEmpty,
                      "an open-source build must not point at anyone's server by default")
    }

    // MARK: - URL normalisation

    func testTheSchemeIsAddedWhenItIsLeftOff() {
        XCTAssertEqual(
            ServerSetupGuide.normalizedServerURL("command.example.com")?.absoluteString,
            "https://command.example.com"
        )
    }

    func testCommonPasteDamageIsRepairedRatherThanRejected() {
        for raw in ["  https://command.example.com  ", "https://command.example.com/",
                    "https://command.example.com//"] {
            XCTAssertEqual(
                ServerSetupGuide.normalizedServerURL(raw)?.absoluteString,
                "https://command.example.com",
                "\(raw) should normalise, not fail"
            )
        }
    }

    func testPlainHttpIsAllowedBecauseALanServerHasNoCertificate() {
        let url = ServerSetupGuide.normalizedServerURL("http://192.168.1.10:9071")
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.10:9071")
        XCTAssertTrue(ServerSetupGuide.isInsecure(url!))
        XCTAssertTrue(ServerSetupGuide.isLocalAddress(url!), "no warning belongs on a LAN address")
    }

    func testHttpOnThePublicInternetIsFlaggedAsInsecure() {
        let url = ServerSetupGuide.normalizedServerURL("http://command.example.com")!
        XCTAssertTrue(ServerSetupGuide.isInsecure(url))
        XCTAssertFalse(ServerSetupGuide.isLocalAddress(url), "this one deserves the warning")
    }

    func testPrivateRangesAreRecognised() {
        for host in ["http://10.0.0.5:9071", "http://172.16.4.4:9071", "http://172.31.9.9:9071",
                     "http://localhost:9071", "http://nas.local:9071"] {
            let url = ServerSetupGuide.normalizedServerURL(host)!
            XCTAssertTrue(ServerSetupGuide.isLocalAddress(url), "\(host) is a local address")
        }
        // 172.32 is outside the private block — a real public address that must not be excused.
        let public172 = ServerSetupGuide.normalizedServerURL("http://172.32.0.1:9071")!
        XCTAssertFalse(ServerSetupGuide.isLocalAddress(public172))
    }

    func testNonsenseIsRefused() {
        for raw in ["", "   ", "notaurl", "https://", "http://nodot"] {
            XCTAssertNil(ServerSetupGuide.normalizedServerURL(raw), "\(raw) should not be accepted")
        }
    }

    // MARK: - The guide content itself

    func testEveryHostingRouteThatNeedsInstructionsHasThem() {
        for option in ServerHostingOption.allCases where option != .existing {
            XCTAssertFalse(option.steps.isEmpty, "\(option.rawValue) must explain what to do")
            XCTAssertEqual(option.steps.map(\.index), Array(1...option.steps.count),
                           "steps must be numbered continuously from 1")
        }
        XCTAssertTrue(ServerHostingOption.existing.steps.isEmpty,
                      "'I already have a server' goes straight to the address field")
    }

    func testTheSelfHostRouteIsOneRunnableCommand() {
        let commands = ServerHostingOption.selfHosted.steps.compactMap(\.command)
        XCTAssertEqual(commands.count, 1, "one paste, no git, no build")
        let command = commands[0]
        XCTAssertTrue(command.hasPrefix("docker run -d "))
        XCTAssertTrue(command.contains("ghcr.io/legitimate-apps/command-server"),
                      "the image the release workflow publishes")
        // Without a volume at /data, replacing the container silently starts them from empty.
        XCTAssertTrue(command.contains("-v command-data:/data"))
        XCTAssertTrue(command.contains("-p 9071:8000"), "the port the Connect step tells them to use")
        XCTAssertTrue(command.contains("--restart unless-stopped"), "survives a reboot")
        XCTAssertFalse(command.contains("\n"), "a single line pastes cleanly into any shell")
        XCTAssertTrue(ServerHostingOption.selfHosted.steps.last!.detail.contains(":9071"))
    }

    func testTheHostedRouteStartsFromTheTemplate() {
        // The template carries the /data volume and the domain, so the steps don't have to.
        XCTAssertEqual(ServerHostingOption.railway.steps.first?.link?.url,
                       ServerSetupGuide.railwayTemplateURL)
    }
}
