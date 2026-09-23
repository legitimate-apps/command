//
//  CommandShortcuts.swift
//  Command
//
//  The zero-config Siri phrases + Spotlight/Shortcuts-gallery tiles. Registering an
//  `AppShortcutsProvider` means these work the moment the app is installed — no setup in
//  the Shortcuts app required. Phrases MUST include `\(.applicationName)` ("Command"), and
//  because "command" is a common word we give each intent several natural phrasings so Siri
//  matches how people actually speak. Ordered most-used first (the order Shortcuts surfaces).
//

import AppIntents

struct CommandShortcuts: AppShortcutsProvider {
    /// Amber tiles, to match the app's burnt-amber accent.
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureNoteIntent(),
            phrases: [
                "Capture a note in \(.applicationName)",
                "New note in \(.applicationName)",
                "Note this in \(.applicationName)",
                "Take a note in \(.applicationName)",
                "Jot this down in \(.applicationName)",
            ],
            shortTitle: "Capture Note",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: LogActivityIntent(),
            phrases: [
                "Log an activity in \(.applicationName)",
                "Log this in \(.applicationName)",
                "Record this in \(.applicationName)",
            ],
            shortTitle: "Log Activity",
            systemImageName: "checkmark.seal"
        )
        AppShortcut(
            intent: DelegateAssignmentIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "New assignment in \(.applicationName)",
                "Delegate a task in \(.applicationName)",
                "Add an assignment to \(.applicationName)",
            ],
            shortTitle: "Add Assignment",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: CreateGoalIntent(),
            phrases: [
                "Create a goal in \(.applicationName)",
                "New goal in \(.applicationName)",
                "Set a goal in \(.applicationName)",
            ],
            shortTitle: "Create Goal",
            systemImageName: "target"
        )
        AppShortcut(
            intent: TodaysAgendaIntent(),
            phrases: [
                "What's on my \(.applicationName) agenda",
                "Show my \(.applicationName) agenda",
                "What's scheduled in \(.applicationName)",
                "What's on today in \(.applicationName)",
            ],
            shortTitle: "Get Agenda",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: FindNotesIntent(),
            phrases: [
                "Find notes in \(.applicationName)",
                "Search \(.applicationName)",
                "Search my \(.applicationName) notes",
            ],
            shortTitle: "Find Notes",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: StartCaptureIntent(),
            phrases: [
                "New capture in \(.applicationName)",
                "Quick capture in \(.applicationName)",
                "Start capturing in \(.applicationName)",
            ],
            shortTitle: "New Capture",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenCommandIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show \(.applicationName)",
                "Go to \(.applicationName)",
            ],
            shortTitle: "Open Command",
            systemImageName: "arrow.up.forward.app"
        )
        AppShortcut(
                intent: StartVoiceConversationIntent(),
                phrases: [
                    "Start a voice conversation with \(.applicationName)",
                    "Talk to \(.applicationName)",
                    "Open the voice assistant in \(.applicationName)",
                ],
                shortTitle: "Start Voice Conversation",
                systemImageName: "waveform.circle"
        )
        AppShortcut(
                intent: AskCommandIntent(),
                phrases: [
                    "Ask \(.applicationName)",
                    "Ask my \(.applicationName) assistant",
                    "Talk with \(.applicationName)",
                ],
                shortTitle: "Ask Command",
                systemImageName: "sparkles"
        )
    }
}
