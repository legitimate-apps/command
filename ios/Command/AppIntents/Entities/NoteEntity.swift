//
//  NoteEntity.swift
//  Command
//
//  A note, exposed to Shortcuts so it can be produced by one action (capture, find)
//  and consumed by the next (open, get-details). Chainable: `@Property` fields let a
//  Shortcut pull the title, body, or created date out of a note it's holding.
//
//  Privacy: notes filed behind the invisible-ink veil are NEVER surfaced to Siri
//  suggestions, Spotlight, or a "find notes" search — they're only resolvable by an
//  explicit id the user themselves wired into a Shortcut, and even then the display
//  is masked. This mirrors the redaction contract in the app UI.
//

import AppIntents
import Foundation

struct NoteEntity: AppEntity, Identifiable {
    let id: Int

    @Property(title: "Title")
    var title: String

    @Property(title: "Body")
    var body: String

    @Property(title: "Created")
    var created: Date?

    @Property(title: "Hidden")
    var hidden: Bool

    init(id: Int, title: String, body: String, created: Date?, hidden: Bool) {
        self.id = id
        self.title = title
        self.body = body
        self.created = created
        self.hidden = hidden
    }

    init(_ note: Note) {
        self.init(
            id: note.id,
            title: note.displayTitle,
            body: note.body,
            created: IntentFormat.date(from: note.createdAt),
            hidden: note.hidden ?? false
        )
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Note")
    }

    static var defaultQuery = NoteEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        if hidden {
            return DisplayRepresentation(
                title: "Hidden note",
                subtitle: "Hidden",
                image: .init(systemName: "eye.slash")
            )
        }
        let preview = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: preview.isEmpty ? nil : "\(preview)",
            image: .init(systemName: "note.text")
        )
    }
}

struct NoteEntityQuery: EntityQuery, EntityStringQuery {
    /// Resolve specific notes a Shortcut is holding (by id). Missing notes are dropped.
    func entities(for identifiers: [Int]) async throws -> [NoteEntity] {
        try await IntentAPI.run { client in
            var results: [NoteEntity] = []
            for id in identifiers {
                if let note = try? await client.getNote(id: id) {
                    results.append(NoteEntity(note))
                }
            }
            return results
        }
    }

    /// Recent, non-hidden notes offered as suggestions in the Shortcuts editor.
    func suggestedEntities() async throws -> [NoteEntity] {
        try await IntentAPI.run { client in
            let page = try await client.searchNotes(limit: 12)
            return page.items.filter { !($0.hidden ?? false) }.map(NoteEntity.init)
        }
    }

    /// Free-text search — powers "Find Notes" chaining and the editor's search field.
    func entities(matching string: String) async throws -> [NoteEntity] {
        try await IntentAPI.run { client in
            let page = try await client.searchNotes(query: string, limit: 25)
            return page.items.filter { !($0.hidden ?? false) }.map(NoteEntity.init)
        }
    }
}
