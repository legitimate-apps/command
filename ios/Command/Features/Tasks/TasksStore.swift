//
//  TasksStore.swift
//  Command
//
//  Goals + assignments — the planner units. Creating an assignment optionally
//  assigns it (server returns the lead-time warning), so capture → plan → delegate
//  is one flow.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TasksStore {
    var assignments: [Assignment] = []
    /// The archived-only view, loaded on demand when the Archived filter is switched on.
    var archivedAssignments: [Assignment] = []
    var goals: [Goal] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let a = client.drainAll { limit, cursor in
                try await client.listAssignments(limit: limit, cursor: cursor)
            }
            async let g = client.drainAll { limit, cursor in
                try await client.listGoals(limit: limit, cursor: cursor)
            }
            let (newAssignments, newGoals) = (try await a, try await g)
            withAnimation(.snappy) {
                assignments = newAssignments
                goals = newGoals
            }
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Create an assignment, then (if an assignee slug is given) assign it — the
    /// assign call defaults the lead time from the delegatee and returns the
    /// human lead-time warning, if any. Returns (assignment, warning).
    func createAssignment(_ body: AssignmentCreateBody, assigneeSlug: String?,
                          client: APIClient) async -> (Assignment?, String?) {
        let created: Assignment
        do {
            created = try await client.createAssignment(body)
        } catch {
            errorMessage = describe(error)
            return (nil, nil)   // nothing was created — safe for the user to retry
        }
        // The assignment now exists server-side. Every path from here MUST surface it in the
        // list: if the follow-up assign() throws and we bail without inserting, the user sees a
        // failure, retries, and creates a *duplicate* (the first row orphaned until a reload).
        var assignment = created
        var warning: String?
        if let slug = assigneeSlug {
            do {
                let result = try await client.assign(assignmentId: created.id, assigneeSlug: slug)
                assignment = result.assignment
                warning = result.leadTimeWarning
                errorMessage = nil
            } catch {
                // Created but not delegated — keep the (unassigned) assignment and tell the user.
                errorMessage = "Assignment created, but delegating it failed — assign it from the assignment."
            }
        } else {
            errorMessage = nil
        }
        assignments.insert(assignment, at: 0)
        await AssistantSchemaDonations.assignmentCreated(assignment)
        return (assignment, warning)
    }

    func setStatus(id: Int, status: String, client: APIClient) async {
        do {
            let updated = try await client.setAssignmentStatus(id: id, status: status)
            if let i = assignments.firstIndex(where: { $0.id == id }) { assignments[i] = updated }
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Delete an assignment. Its occurrences are pruned from `calendar` too — the calendar holds
    /// its own copy of them, which otherwise kept showing the deleted work until the next reload.
    /// Returns true on success (callers then drop any detail page still showing it).
    @discardableResult
    func delete(id: Int, calendar: CalendarStore? = nil, client: APIClient) async -> Bool {
        do {
            _ = try await client.deleteAssignment(id: id)
            assignments.removeAll { $0.id == id }
            archivedAssignments.removeAll { $0.id == id }
            calendar?.removeOccurrences(ofAssignment: id)
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// Fold a server copy of an assignment (from a detail-page edit) into the lists, so a title or
    /// notes change shows in Tasks without waiting for a refresh.
    func apply(_ updated: Assignment) {
        if let i = assignments.firstIndex(where: { $0.id == updated.id }) { assignments[i] = updated }
        if let i = archivedAssignments.firstIndex(where: { $0.id == updated.id }) { archivedAssignments[i] = updated }
    }

    func apply(_ updated: Goal) {
        if let i = goals.firstIndex(where: { $0.id == updated.id }) { goals[i] = updated }
    }

    func loadArchived(client: APIClient) async {
        do {
            archivedAssignments = try await client.drainAll { limit, cursor in
                try await client.listAssignments(archived: true, limit: limit, cursor: cursor)
            }
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Archive or restore an assignment, moving it between the live and archived lists. The
    /// calendar drops an archived assignment's occurrences at once (the server stops expanding
    /// them); a restore reloads the calendar so they come back. Returns true on success.
    @discardableResult
    func setArchived(id: Int, archived: Bool, calendar: CalendarStore? = nil, client: APIClient) async -> Bool {
        do {
            let updated = try await client.archiveAssignment(id: id, archived: archived)
            if archived {
                assignments.removeAll { $0.id == id }
                archivedAssignments.insert(updated, at: 0)
                calendar?.removeOccurrences(ofAssignment: id)
            } else {
                archivedAssignments.removeAll { $0.id == id }
                assignments.insert(updated, at: 0)
            }
            errorMessage = nil
            if !archived, let calendar { await calendar.load(client: client) }
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// Redact (hide) or unredact (reveal) an assignment, syncing the row's veil live.
    @discardableResult
    func setHidden(id: Int, hidden: Bool, client: APIClient) async -> Bool {
        do {
            let updated = try await client.setAssignmentHidden(id: id, hidden: hidden)
            if let i = assignments.firstIndex(where: { $0.id == id }) { assignments[i] = updated }
            errorMessage = nil; return true
        } catch {
            errorMessage = describe(error); return false
        }
    }

    @discardableResult
    func createGoal(title: String, description: String? = nil, targetDate: String? = nil,
                    client: APIClient) async -> Bool {
        do {
            let goal = try await client.createGoal(title: title, description: description, targetDate: targetDate)
            goals.insert(goal, at: 0)
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
