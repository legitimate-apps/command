//
//  LogStore.swift
//  Command
//
//  Shared observable for the activity log — the facts ("X did Y"). One instance
//  on AppState so the Calendar capture bar, the calendar markers, and the Log
//  list stay in sync. Holds the actor roster *including* the hidden "Me", plus the
//  audit summary buckets.
//

import Foundation
import Observation

@MainActor
@Observable
final class LogStore {
    var activities: [Activity] = []
    var actors: [Delegatee] = []          // includes the "Me" actor (is_self)
    var summary: [ActivitySummaryRow] = []
    var draft = ""                        // quick-log text in the capture bar
    var composeActorId: Int?              // who the next quick-log is attributed to (nil = Me)
    var occurredAt = Date()               // when the fact happened — synced to the selected calendar day
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    /// The "Me" actor, once the roster is loaded.
    var me: Delegatee? { actors.first { $0.isSelf } }

    /// Actors offered in pickers: "Me" first, then the roster alphabetically.
    var pickActors: [Delegatee] {
        actors.filter(\.isSelf) + actors.filter { !$0.isSelf }.sorted { $0.name < $1.name }
    }

    /// Display name for the capture bar's actor chip.
    var composeActorName: String {
        if let id = composeActorId, let a = actors.first(where: { $0.id == id }) { return a.name }
        return me?.name ?? "Me"
    }

    /// Distinct categories seen so far — drives the edit-sheet autocomplete.
    var knownCategories: [String] {
        var seen = Set<String>()
        return activities.compactMap(\.category).filter { !$0.isEmpty && seen.insert($0).inserted }.sorted()
    }

    func load(client: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            if actors.isEmpty { await loadActors(client: client) }
            async let acts = client.drainAll { limit, cursor in
                try await client.listActivities(limit: limit, cursor: cursor)
            }
            async let sum = client.activitySummary()
            activities = try await acts
            summary = try await sum
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    func loadActors(client: APIClient) async {
        if let items = try? await client.drainAll(pageSize: 200, { limit, cursor in
            try await client.listDelegatees(includeSelf: true, limit: limit, cursor: cursor)
        }) {
            actors = items
        }
    }

    /// Point the next quick-log at a given calendar day, preserving the chosen time-of-day.
    /// Mirrors the selected calendar day exactly (the capture bar follows the big calendar).
    func useDay(_ day: Date) {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: occurredAt)
        var d = cal.dateComponents([.year, .month, .day], from: day)
        d.hour = t.hour
        d.minute = t.minute
        occurredAt = cal.date(from: d) ?? day
    }

    /// Log the capture-bar draft as a fact (attributed to the chosen actor, on `occurredAt`).
    @discardableResult
    func logDraft(hidden: Bool = false, client: APIClient) async -> Bool {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let activity = try await client.createActivity(
                ActivityCreateBody(title: title, actorId: composeActorId,
                                   occurredAt: Self.iso(occurredAt), hidden: hidden))
            activities.insert(activity, at: 0)
            draft = ""
            errorMessage = nil
            await refreshSummary(client: client)
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    func update(id: Int, _ body: ActivityUpdateBody, client: APIClient) async {
        do {
            let updated = try await client.updateActivity(id: id, body)
            if let i = activities.firstIndex(where: { $0.id == id }) { activities[i] = updated }
            await refreshSummary(client: client)
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    func delete(id: Int, client: APIClient) async {
        do {
            _ = try await client.deleteActivity(id: id)
            activities.removeAll { $0.id == id }
            await refreshSummary(client: client)
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Redact (hide) or unredact (reveal) a logged fact, syncing the row's veil live.
    @discardableResult
    func setHidden(id: Int, hidden: Bool, client: APIClient) async -> Bool {
        do {
            let updated = try await client.setActivityHidden(id: id, hidden: hidden)
            if let i = activities.firstIndex(where: { $0.id == id }) { activities[i] = updated }
            errorMessage = nil; return true
        } catch {
            errorMessage = describe(error); return false
        }
    }

    private func refreshSummary(client: APIClient) async {
        if let s = try? await client.activitySummary() { summary = s }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
