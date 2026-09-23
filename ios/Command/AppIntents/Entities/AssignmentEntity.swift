//
//  AssignmentEntity.swift
//  Command
//
//  An assignment — a delegated, scheduled unit of work. Produced by the "delegate"
//  intent and by "find assignments", consumable downstream (open it, read its status).
//  Hidden (invisible-ink) assignments are kept out of suggestions and search, matching
//  the note privacy contract.
//

import AppIntents
import Foundation

struct AssignmentEntity: AppEntity, Identifiable {
    let id: Int

    @Property(title: "Title")
    var title: String

    @Property(title: "Status")
    var status: String

    @Property(title: "Scheduled for")
    var scheduledStart: Date?

    let hidden: Bool

    init(_ assignment: Assignment) {
        // Plain `let`s first, then the @Property-wrapped fields (their setters touch `self`).
        self.id = assignment.id
        self.hidden = assignment.hidden ?? false
        self.title = assignment.title
        self.status = assignment.status
        self.scheduledStart = assignment.scheduledStart.flatMap(IntentFormat.date(from:))
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Assignment")
    }

    static var defaultQuery = AssignmentEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        if hidden {
            return DisplayRepresentation(title: "Hidden assignment", image: .init(systemName: "eye.slash"))
        }
        var subtitle = status.replacingOccurrences(of: "_", with: " ").capitalized
        if let start = scheduledStart {
            subtitle += " · \(IntentFormat.dayLabel(start))"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "checklist")
        )
    }
}

struct AssignmentEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [AssignmentEntity] {
        return try await IntentAPI.run { client in
            var results: [AssignmentEntity] = []
            for id in identifiers {
                if let a = try? await client.assignment(id: id) {
                    results.append(AssignmentEntity(a))
                }
            }
            return results
        }
    }

    func suggestedEntities() async throws -> [AssignmentEntity] {
        try await IntentAPI.run { client in
            let page = try await client.listAssignments(limit: 100)
            return page.items.filter { !($0.hidden ?? false) }.map(AssignmentEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [AssignmentEntity] {
        let needle = string.lowercased()
        return try await IntentAPI.run { client in
            let page = try await client.listAssignments(limit: 100)
            return page.items
                .filter { !($0.hidden ?? false) && $0.title.lowercased().contains(needle) }
                .map(AssignmentEntity.init)
        }
    }
}
