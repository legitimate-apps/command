//
//  CaptureIntents.swift
//  Command
//
//  The fast-capture intents — Command's whole reason for being, now reachable from
//  Siri, the Lock/Home Screen, the Action button, and a Shortcut. These run WITHOUT
//  opening the app (`openAppWhenRun == false`): the text is already in hand, so we
//  write straight to the server and hand back a branded receipt. When the app happens
//  to be running, the new item also slides into the live list via `ShortcutNavigation`.
//

import AppIntents
import Foundation

/// Capture a note. The flagship Shortcut: "Capture <text> in Command".
struct CaptureNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Note"
    static var description = IntentDescription(
        "Save a quick note to Command — dictate it aloud or pass text from another Shortcut.",
        categoryName: "Capture",
        searchKeywords: ["note", "capture", "jot", "memo", "write"]
    )
    static var openAppWhenRun = false

    @Parameter(title: "Note", requestValueDialog: "What would you like to note?")
    var text: String

    @Parameter(title: "Visibility", default: .visible)
    var visibility: CaptureVisibility

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$text) in Command") {
            \.$visibility
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw CommandIntentError.emptyInput("some note text") }

        let note = try await IntentAPI.run { client in
            try await client.createNote(body: body, source: "typed", hidden: visibility.isHidden)
        }
        let entity = NoteEntity(note)
        await ShortcutNavigation.shared.noteCreated(note)

        // The returned entity carries its own rich display (title + preview + icon) into the
        // Shortcuts/Siri result; the dialog is what Siri speaks.
        let dialog: IntentDialog = visibility.isHidden
            ? "Filed a hidden note in Command."
            : IntentDialog("Got it — noted “\(entity.title)” in Command.")
        return .result(value: entity, dialog: dialog)
    }
}

/// Log a fact — "X happened" — into the activity log. The backward-looking capture.
struct LogActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Activity"
    static var description = IntentDescription(
        "Record something that happened — a done task, a call, a workout — in Command's log.",
        categoryName: "Capture",
        searchKeywords: ["log", "activity", "track", "did", "record", "journal"]
    )
    static var openAppWhenRun = false

    @Parameter(title: "What happened", requestValueDialog: "What should I log?")
    var title: String

    @Parameter(title: "Category", description: "An optional bucket, e.g. Health or Work.")
    var category: String?

    @Parameter(title: "When", description: "Defaults to now.")
    var when: Date?

    @Parameter(title: "Duration (minutes)", description: "Optional — how long it took.")
    var durationMinutes: Int?

    @Parameter(title: "Visibility", default: .visible)
    var visibility: CaptureVisibility

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$title) in Command") {
            \.$when
            \.$category
            \.$durationMinutes
            \.$visibility
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<ActivityEntity> & ProvidesDialog {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommandIntentError.emptyInput("something to log") }

        let occurredAt = when ?? Date()
        let cleanCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activity = try await IntentAPI.run { client in
            try await client.createActivity(ActivityCreateBody(
                title: text,
                category: (cleanCategory?.isEmpty == false) ? cleanCategory : nil,
                occurredAt: IntentFormat.iso.string(from: occurredAt),
                durationMinutes: durationMinutes,
                hidden: visibility.isHidden
            ))
        }
        await ShortcutNavigation.shared.activityCreated(activity)
        let entity = ActivityEntity(activity)
        return .result(value: entity, dialog: "Logged it in Command.")
    }
}
