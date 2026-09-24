//
//  SecretPasteboard.swift
//  Command
//
//  Copying a credential: the MCP access token, a delegatee invite code, the private calendar
//  feed link. The general pasteboard keeps whatever lands on it until something replaces it,
//  and any app pasted into later can read it, so a secret gets an expiry instead — long enough
//  to switch to wherever it's going, short enough that it isn't still there tomorrow.
//
//  Deliberately NOT `.localOnly`: the usual path is revealing the token on the phone and
//  pasting it into Claude Code on a computer, which is Universal Clipboard.
//

import UIKit
import UniformTypeIdentifiers

enum SecretPasteboard {
    /// How long a copied secret stays on this device's pasteboard.
    static let lifetime: TimeInterval = 10 * 60

    static func copy(_ secret: String, lifetime: TimeInterval = lifetime) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: [.expirationDate: Date.now.addingTimeInterval(lifetime)]
        )
    }
}
