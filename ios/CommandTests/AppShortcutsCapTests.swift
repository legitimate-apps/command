//
//  AppShortcutsCapTests.swift
//  Command
//
//  Apple caps an app at TEN App Shortcuts, and Apple Frameworks Engineering has confirmed
//  there is no supported way past it. We now sit exactly on that ceiling, so the next person
//  to add one has no headroom — and the failure is not a friendly compile error, it is
//  shortcuts silently not registering on device.
//
//  This test is the tripwire: it fails in CI the moment the count moves, so the decision to
//  drop an existing shortcut is made deliberately rather than discovered by a user whose
//  phrase stopped working.
//

import AppIntents
import XCTest
@testable import Command

final class AppShortcutsCapTests: XCTestCase {
    /// Apple's hard limit. Not a style preference — the platform enforces it.
    static let appleMaximum = 10

    func testShortcutCountIsWithinApplesLimit() {
        let count = CommandShortcuts.appShortcuts.count
        XCTAssertLessThanOrEqual(
            count, Self.appleMaximum,
            "Apple allows at most \(Self.appleMaximum) App Shortcuts; this app declares \(count). "
            + "Adding another means removing one first."
        )
    }

    func testWeKnowExactlyHowManyWeHave() {
        // Pinned so a change is visible in review rather than silently consuming the last slot.
        XCTAssertEqual(CommandShortcuts.appShortcuts.count, 10)
    }
}
