//
//  SecretPasteboardTests.swift
//  CommandTests
//

import UIKit
import XCTest
@testable import Command

final class SecretPasteboardTests: XCTestCase {
    /// A secret copied with an expiry must still paste as plain text, or Copy token looks like it
    /// worked while the paste in Claude Code's terminal comes up empty.
    func testCopiedSecretReadsBackAsPlainText() {
        let secret = "cmd_example-token-\(UUID().uuidString.prefix(8))"
        SecretPasteboard.copy(secret)
        XCTAssertEqual(UIPasteboard.general.string, secret)
        XCTAssertTrue(UIPasteboard.general.hasStrings)
    }

    /// The point of the helper: the secret is gone once its lifetime passes.
    func testCopiedSecretExpires() async throws {
        // The first pasteboard access on a freshly booted simulator can take longer than the
        // lifetime below; pay it before the clock starts.
        _ = UIPasteboard.general.hasStrings
        let secret = "cmd_expiring-\(UUID().uuidString.prefix(8))"
        let lifetime: TimeInterval = 3
        let copiedAt = Date.now
        SecretPasteboard.copy(secret, lifetime: lifetime)
        let readBack = UIPasteboard.general.string
        if Date.now.timeIntervalSince(copiedAt) < lifetime {
            XCTAssertEqual(readBack, secret, "present while inside its lifetime")
        }
        try await Task.sleep(for: .seconds(lifetime + 1.5))
        XCTAssertNotEqual(UIPasteboard.general.string, secret, "gone once its lifetime passes")
    }
}
