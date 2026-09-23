//
//  OptionalNavigator.swift
//  Command
//
//  An OPTIONAL environment accessor for the shell's Navigator. The shared list
//  views (Tasks/Notes/People/Calendar) are used on BOTH the iPhone path (no
//  Navigator) and the iPad/Mac shell (Navigator present). `@Environment(Navigator.self)`
//  traps when absent, so those views read `@Environment(\.navigator)` instead and
//  branch on `nil` — keeping the iPhone path byte-for-byte unchanged.
//

import SwiftUI

private struct NavigatorKey: EnvironmentKey {
    static let defaultValue: Navigator? = nil
}

extension EnvironmentValues {
    var navigator: Navigator? {
        get { self[NavigatorKey.self] }
        set { self[NavigatorKey.self] = newValue }
    }
}
