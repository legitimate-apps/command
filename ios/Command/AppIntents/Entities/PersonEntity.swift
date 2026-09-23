//
//  PersonEntity.swift
//  Command
//
//  A delegatee — a person or AI model on the roster that work gets assigned to.
//  Exposed so a Shortcut can pick an assignee ("Delegate 'call the vet' to Dana").
//  The hidden "Me" actor is never offered here (you don't delegate to yourself).
//

import AppIntents
import Foundation

struct PersonEntity: AppEntity, Identifiable {
    let id: Int

    @Property(title: "Name")
    var name: String

    /// The stable slug the assign API keys on (semantic id, not a raw UUID).
    let slug: String

    /// "human" | "ai_model".
    let kind: String

    @Property(title: "Advance notice (minutes)")
    var leadTimeMinutes: Int

    init(_ delegatee: Delegatee) {
        // Plain stored `let`s first, then the @Property-wrapped fields (their setters
        // touch `self`, so every non-wrapped property must already be initialized).
        self.id = delegatee.id
        self.slug = delegatee.slug
        self.kind = delegatee.kind
        self.name = delegatee.name
        self.leadTimeMinutes = delegatee.leadTimeMinutes
    }

    var isAI: Bool { kind == "ai_model" }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Delegatee")
    }

    static var defaultQuery = PersonEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isAI ? "AI model" : "Person · \(LeadTime.label(leadTimeMinutes)) notice",
            image: .init(systemName: isAI ? "cpu" : "person.crop.circle")
        )
    }
}

struct PersonEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [PersonEntity] {
        let ids = Set(identifiers)
        return try await IntentAPI.run { client in
            let page = try await client.listDelegatees(limit: 200)
            return page.items.filter { ids.contains($0.id) && !$0.isSelf }.map(PersonEntity.init)
        }
    }

    func suggestedEntities() async throws -> [PersonEntity] {
        try await IntentAPI.run { client in
            let page = try await client.listDelegatees(activeOnly: true, limit: 200)
            return page.items.filter { !$0.isSelf }.map(PersonEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [PersonEntity] {
        try await IntentAPI.run { client in
            let matches = try await client.searchDelegatees(string, limit: 20)
            return matches.filter { !$0.isSelf }.map(PersonEntity.init)
        }
    }
}
