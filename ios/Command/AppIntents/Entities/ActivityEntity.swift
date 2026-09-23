//
//  ActivityEntity.swift
//  Command
//
//  A logged fact — "X did Y at time T" — the backward-looking counterpart to an
//  assignment. Produced by "Log Activity" and by searching the log, so a Shortcut can
//  read what was done. Hidden (invisible-ink) facts are kept out of suggestions/search.
//

import AppIntents
import Foundation

struct ActivityEntity: AppEntity, Identifiable {
    let id: Int

    @Property(title: "Title")
    var title: String

    @Property(title: "Category")
    var category: String?

    @Property(title: "When")
    var occurred: Date?

    let hidden: Bool

    init(_ activity: Activity) {
        self.id = activity.id
        self.hidden = activity.hidden ?? false
        self.title = activity.title
        self.category = activity.category
        self.occurred = IntentFormat.date(from: activity.occurredAt)
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Activity")
    }

    static var defaultQuery = ActivityEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        if hidden {
            return DisplayRepresentation(title: "Hidden activity", image: .init(systemName: "eye.slash"))
        }
        var subtitle = occurred.map(IntentFormat.dayLabel) ?? ""
        if let category, !category.isEmpty { subtitle = subtitle.isEmpty ? category : "\(category) · \(subtitle)" }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)",
            image: .init(systemName: "checkmark.seal")
        )
    }
}

struct ActivityEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [ActivityEntity] {
        try await IntentAPI.run { client in
            var results: [ActivityEntity] = []
            for id in identifiers {
                if let a = try? await client.activity(id: id) { results.append(ActivityEntity(a)) }
            }
            return results
        }
    }

    func suggestedEntities() async throws -> [ActivityEntity] {
        try await IntentAPI.run { client in
            let page = try await client.listActivities(limit: 25)
            return page.items.filter { !($0.hidden ?? false) }.map(ActivityEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [ActivityEntity] {
        try await IntentAPI.run { client in
            let page = try await client.listActivities(query: string, limit: 25)
            return page.items.filter { !($0.hidden ?? false) }.map(ActivityEntity.init)
        }
    }
}
