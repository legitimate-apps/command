//
//  Haptics.swift
//  Command
//
//  A small shared haptic vocabulary. Feedback is cheap delight that confirms meaningful
//  actions without adding visual noise. No-op on Mac Catalyst where UIKit haptics are
//  unavailable and the trackpad/keyboard have their own tactile context.
//

import SwiftUI

enum Haptics {
    /// Light impact — toggles, completing an item, small state changes.
    static func light() {
        #if !targetEnvironment(macCatalyst)
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
        #endif
    }

    /// Success — send/save, the thing the user wanted to happen did.
    static func success() {
        #if !targetEnvironment(macCatalyst)
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
        #endif
    }

    /// Warning — an error, a failed attempt, or something needs attention.
    static func warning() {
        #if !targetEnvironment(macCatalyst)
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.warning)
        #endif
    }

    /// Rigid/heavy impact — delete, remove, or other consequential destructive action.
    static func delete() {
        #if !targetEnvironment(macCatalyst)
        let g = UIImpactFeedbackGenerator(style: .rigid)
        g.prepare()
        g.impactOccurred(intensity: 0.8)
        #endif
    }
}
