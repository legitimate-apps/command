//
//  OpenIntents.swift
//  Command
//
//  Intents that bring the app to the foreground and steer it. Unlike the capture/review
//  intents, these DO open the app (`openAppWhenRun == true`) and route through
//  `ShortcutNavigation`, which the running shell drains into the same `handle(_:)` path
//  the menu-bar and ⌘-key commands use — so a Shortcut lands exactly where a keyboard
//  shortcut would.
//

import AppIntents
import Foundation

/// Open Command to a chosen section (Calendar, Notes, Assistant, Tasks, People).
struct OpenCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Command"
    static var description = IntentDescription(
        "Open Command to a section.",
        categoryName: "Open",
        searchKeywords: ["open", "show", "go to", "launch"]
    )
    static var openAppWhenRun = true

    @Parameter(title: "Section", default: .calendar)
    var tab: CommandTab

    static var parameterSummary: some ParameterSummary {
        Summary("Open Command to \(\.$tab)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutNavigation.shared.route(.go(tab.destination))
        return .result()
    }
}

/// Open Command straight into fast-capture — the calendar with the capture bar focused.
struct StartCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "New Capture in Command"
    static var description = IntentDescription(
        "Open Command ready to capture — the calendar with the capture field focused.",
        categoryName: "Open",
        searchKeywords: ["capture", "new", "quick", "jot", "add"]
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutNavigation.shared.route(.capture)
        return .result()
    }
}
