//
//  ReviewIntents.swift
//  Command
//
//  Read-only intents — pull answers out of Command without opening it. These power
//  "Hey Siri, what's on my Command calendar today?" and let a Shortcut fetch notes to
//  feed the next action. Hidden (invisible-ink) items are never returned here.
//

import AppIntents
import Foundation

/// Search notes (or list the most recent) and hand them back for display or chaining.
struct FindNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Notes"
    static var description = IntentDescription(
        "Search your Command notes — or get the most recent — to read or feed into another action.",
        categoryName: "Review",
        searchKeywords: ["find", "search", "notes", "recent", "lookup"],
        resultValueName: "Notes"
    )
    static var openAppWhenRun = false

    @Parameter(title: "Search for", description: "Leave empty to get your most recent notes.")
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Find notes matching \(\.$query) in Command")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> & ProvidesDialog {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entities = try await IntentAPI.run { client -> [NoteEntity] in
            let page = try await client.searchNotes(
                query: (needle?.isEmpty == false) ? needle : nil,
                limit: 25
            )
            return page.items.filter { !($0.hidden ?? false) }.map(NoteEntity.init)
        }

        let dialog: IntentDialog = entities.isEmpty
            ? "No matching notes in Command."
            : IntentDialog("Found \(entities.count) note\(entities.count == 1 ? "" : "s") in Command.")

        // Return the note entities directly: the system renders them as a browsable, tappable
        // list — the idiomatic result for a search, and richer than a static card here (a
        // collection value can't also carry a snippet view, and the native list wins for search).
        return .result(value: entities, dialog: dialog)
    }
}

/// Read a day's agenda — the timed occurrences from Command's calendar.
struct TodaysAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Agenda"
    static var description = IntentDescription(
        "See what's scheduled in Command for today — or any day you pick.",
        categoryName: "Review",
        searchKeywords: ["agenda", "today", "calendar", "schedule", "what's on"]
    )
    static var openAppWhenRun = false

    @Parameter(title: "Day", description: "Defaults to today.")
    var day: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the Command agenda for \(\.$day)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[AssignmentEntity]> & ProvidesDialog {
        let target = day ?? Date()
        let bounds = IntentFormat.dayBounds(for: target)
        let occurrences = try await IntentAPI.run { client in
            try await client.calendar(start: bounds.start, end: bounds.end)
        }

        // Chronological, visible occurrences → the distinct assignments behind them, in agenda
        // order (a recurring event collapses to a single entity). The system renders these as a
        // browsable, tappable list — the idiomatic result for a "what's on today" query, and the
        // one the user can act on downstream (mark done, get details).
        let visible = occurrences
            .filter { !($0.hidden ?? false) }
            .sorted { $0.occursAt < $1.occursAt }
        var seen = Set<Int>()
        let orderedIds = visible.map(\.assignmentId).filter { seen.insert($0).inserted }
        let entities = try await AssignmentEntityQuery().entities(for: orderedIds)

        let isToday = Calendar.current.isDateInToday(target)
        let dayWord = isToday ? "today" : IntentFormat.dayLabel(target)
        let count = visible.count
        let dialog: IntentDialog = count == 0
            ? IntentDialog("Nothing scheduled in Command for \(dayWord).")
            : IntentDialog("You have \(count) thing\(count == 1 ? "" : "s") scheduled \(isToday ? "today" : "on \(dayWord)").")

        return .result(value: entities, dialog: dialog)
    }
}
