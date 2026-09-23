//
//  CommandAppEnums.swift
//  Command
//
//  The typed vocabularies the App Intents surface exposes as pickers in the Shortcuts
//  editor and as spoken options to Siri. Each `AppEnum` maps a Shortcuts-facing case to
//  the wire values `core/` already understands, so the intents stay thin.
//

import AppIntents

/// The app's primary sections — the target of "Open Command to …".
enum CommandTab: String, AppEnum {
    case calendar, notes, assistant, tasks, people

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Command Section" }
    static var caseDisplayRepresentations: [CommandTab: DisplayRepresentation] {
        [
            .calendar:  DisplayRepresentation(title: "Calendar", image: .init(systemName: "calendar")),
            .notes:     DisplayRepresentation(title: "Notes", image: .init(systemName: "note.text")),
            .assistant: DisplayRepresentation(title: "Assistant", image: .init(systemName: "sparkles")),
            .tasks:     DisplayRepresentation(title: "Tasks", image: .init(systemName: "checklist")),
            .people:    DisplayRepresentation(title: "People", image: .init(systemName: "person.2")),
        ]
    }

    /// The in-app destination this section routes to.
    var destination: AppDestination {
        switch self {
        case .calendar:  return .calendar
        case .notes:     return .notes
        case .assistant: return .assistant
        case .tasks:     return .tasks
        case .people:    return .people
        }
    }
}

/// Whether a captured item is filed openly or behind Command's invisible-ink veil.
/// Mirrors the app's hide/reveal feature so a Shortcut can capture something private.
enum CaptureVisibility: String, AppEnum {
    case visible, hidden

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Visibility" }
    static var caseDisplayRepresentations: [CaptureVisibility: DisplayRepresentation] {
        [
            .visible: DisplayRepresentation(title: "Visible", image: .init(systemName: "eye")),
            .hidden:  DisplayRepresentation(title: "Hidden", image: .init(systemName: "eye.slash")),
        ]
    }

    var isHidden: Bool { self == .hidden }
}

/// Routine (recurring) vs sporadic (one-off) — the two scheduling shapes an assignment takes.
enum AssignmentCadence: String, AppEnum {
    case sporadic, routine

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Cadence" }
    static var caseDisplayRepresentations: [AssignmentCadence: DisplayRepresentation] {
        [
            .sporadic: DisplayRepresentation(title: "One-off", subtitle: "A single, dated task"),
            .routine:  DisplayRepresentation(title: "Routine", subtitle: "Repeats on a schedule"),
        ]
    }

    var wireValue: String { rawValue }
}
