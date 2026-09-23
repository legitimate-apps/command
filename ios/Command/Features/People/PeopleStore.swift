//
//  PeopleStore.swift
//  Command
//
//  The delegatee roster — people and AI models work gets assigned to. Shared on
//  AppState so the assignment assignee picker can reuse + inline-add to it.
//

import Foundation
import Observation

/// Friendly lead-time presets ↔ minutes (the advance notice a delegatee needs).
enum LeadTime {
    static let presets: [(label: String, minutes: Int)] = [
        ("No notice", 0), ("2 hours", 120), ("4 hours", 240),
        ("Same day", 480), ("1 day", 1440), ("2 days", 2880), ("1 week", 10080),
    ]

    static func label(_ minutes: Int) -> String {
        if minutes <= 0 { return "No notice" }
        if minutes % 10080 == 0 { let w = minutes / 10080; return w == 1 ? "1 week" : "\(w) weeks" }
        if minutes % 1440 == 0 { let d = minutes / 1440; return d == 1 ? "1 day" : "\(d) days" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

@MainActor
@Observable
final class PeopleStore {
    var delegatees: [Delegatee] = []
    var selfDelegatee: Delegatee?    // the "Me" actor, kept out of the roster but offered in pickers
    var isLoading = false
    var errorMessage: String?

    func load(client: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Load with self included, then split: the delegate-to-others roster excludes "Me"
            // (design), but the self actor is kept so the assignee picker can offer it explicitly.
            let all = try await client.drainAll { limit, cursor in
                try await client.listDelegatees(includeSelf: true, limit: limit, cursor: cursor)
            }
            selfDelegatee = all.first { $0.isSelf }
            delegatees = all.filter { !$0.isSelf }
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Create or update a delegatee, then refresh the roster. Returns the saved
    /// delegatee so callers (e.g. the capture-dock assignee picker) can select the
    /// just-added person; nil on failure.
    @discardableResult
    func upsert(name: String, slug: String?, kind: String, leadTimeMinutes: Int,
                metadata: [String: JSONValue], active: Bool, client: APIClient) async -> Delegatee? {
        do {
            let result = try await client.upsertDelegatee(
                name: name, slug: slug, kind: kind,
                leadTimeMinutes: leadTimeMinutes, metadata: metadata, active: active)
            await load(client: client)
            return result.delegatee
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    func remove(id: Int, client: APIClient) async {
        do {
            _ = try await client.deleteDelegatee(id: id)
            delegatees.removeAll { $0.id == id }
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
