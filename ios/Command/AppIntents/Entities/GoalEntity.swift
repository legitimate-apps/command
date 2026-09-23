//
//  GoalEntity.swift
//  Command
//
//  A goal — the intent behind a cluster of assignments. Exposed so a Shortcut can pick
//  a goal to file a new assignment under, or read a goal's status.
//

import AppIntents
import Foundation

struct GoalEntity: AppEntity, Identifiable {
    let id: Int

    @Property(title: "Title")
    var title: String

    @Property(title: "Status")
    var status: String

    @Property(title: "Target date")
    var targetDate: Date?

    init(_ goal: Goal) {
        self.id = goal.id
        self.title = goal.title
        self.status = goal.status
        self.targetDate = goal.targetDate.flatMap(IntentFormat.date(from:))
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Goal")
    }

    static var defaultQuery = GoalEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(status.replacingOccurrences(of: "_", with: " ").capitalized)",
            image: .init(systemName: "target")
        )
    }
}

struct GoalEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [GoalEntity] {
        let ids = Set(identifiers)
        return try await IntentAPI.run { client in
            let page = try await client.listGoals(limit: 200)
            return page.items.filter { ids.contains($0.id) }.map(GoalEntity.init)
        }
    }

    func suggestedEntities() async throws -> [GoalEntity] {
        try await IntentAPI.run { client in
            // Open + in-progress goals are the ones you'd file work under; skip done/dropped.
            let page = try await client.listGoals(limit: 200)
            return page.items.filter { $0.status == "open" || $0.status == "in_progress" }.map(GoalEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [GoalEntity] {
        let needle = string.lowercased()
        return try await IntentAPI.run { client in
            let page = try await client.listGoals(limit: 200)
            return page.items.filter { $0.title.lowercased().contains(needle) }.map(GoalEntity.init)
        }
    }
}
