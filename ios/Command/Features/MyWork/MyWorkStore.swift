//
//  MyWorkStore.swift
//  Command
//
//  Delegatee-only state. Every request uses /api/my; this store deliberately has no path to the
//  operator assignment APIs, keeping the client architecture aligned with the server's scope.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MyWorkStore {
    var profile: MyProfile?
    var assignments: [Assignment] = []
    var occurrences: [Occurrence] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: APIClient) async {
        isLoading = assignments.isEmpty && occurrences.isEmpty
        defer { isLoading = false }
        do {
            let profile = try await client.myProfile()
            let assignments = try await client.myAssignments()
            let window = Self.window()
            let occurrences = try await client.myCalendar(start: window.start, end: window.end)
            // Defense in depth: the server owns hidden-item exclusion; never render one even if a
            // future server regression accidentally includes it.
            self.profile = profile
            withAnimation(.snappy) {
                self.assignments = assignments.filter { !($0.hidden ?? false) }
                self.occurrences = occurrences.filter { !($0.hidden ?? false) }
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func setAssignmentStatus(id: Int, status: String, client: APIClient) async {
        guard let index = assignments.firstIndex(where: { $0.id == id }) else { return }
        let original = assignments[index]
        let originalOccurrences = occurrences.filter { $0.assignmentId == id }
        assignments[index] = original.withStatus(status)
        occurrences = occurrences.map { $0.assignmentId == id ? $0.withStatus(status) : $0 }
        do {
            let updated = try await client.setMyAssignmentStatus(id: id, status: status)
            if let current = assignments.firstIndex(where: { $0.id == id }) {
                assignments[current] = updated
            }
            errorMessage = nil
        } catch {
            if let current = assignments.firstIndex(where: { $0.id == id }) {
                assignments[current] = original
            }
            // Occurrence ids are (assignment, instant); a window can legitimately repeat one (a
            // multi-day span sharing a start), and `uniqueKeysWithValues` traps on a duplicate.
            let originals = Dictionary(originalOccurrences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            occurrences = occurrences.map { originals[$0.id] ?? $0 }
            errorMessage = Self.describe(error)
            Haptics.warning()
        }
    }

    func setOccurrenceStatus(_ status: String, occurrence: Occurrence, client: APIClient) async {
        guard let index = occurrences.firstIndex(where: { $0.id == occurrence.id }) else { return }
        let original = occurrences[index]
        occurrences[index] = original.withStatus(status)
        do {
            _ = try await client.setMyOccurrenceStatus(
                id: occurrence.assignmentId, date: occurrence.dateKey, status: status)
            errorMessage = nil
        } catch {
            if let current = occurrences.firstIndex(where: { $0.id == occurrence.id }) {
                occurrences[current] = original
            }
            errorMessage = Self.describe(error)
            Haptics.warning()
        }
    }

    private static func window() -> (start: String, end: String) {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -14, to: cal.startOfDay(for: .now)) ?? .now
        let end = cal.date(byAdding: .day, value: 61, to: cal.startOfDay(for: .now)) ?? .now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return (formatter.string(from: start), formatter.string(from: end))
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// How My Work files occurrences into sections. Pure, so the "nothing falls through the cracks"
/// rule is testable: every occurrence lands in exactly one section — an unfinished one from a
/// PAST day is Overdue (it used to vanish: not today, not upcoming, not done), and a finished one
/// is Done recently whether it was due before or after now (finishing early no longer hides it).
struct MyWorkSections: Equatable {
    var overdue: [Occurrence] = []
    var today: [Occurrence] = []
    var upcoming: [Occurrence] = []
    var doneRecently: [Occurrence] = []

    var isEmpty: Bool { overdue.isEmpty && today.isEmpty && upcoming.isEmpty && doneRecently.isEmpty }

    /// done / skipped / cancelled are all closed — none of them is still owed.
    static func isFinished(_ status: String) -> Bool {
        status == "done" || status == "skipped" || status == "cancelled"
    }

    init(_ occurrences: [Occurrence], now: Date = .now, calendar: Calendar = .current) {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let doneCutoff = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        for item in occurrences {
            guard let date = PlannerFormat.parse(item.occursAt) else { continue }
            if Self.isFinished(item.status) {
                if date >= doneCutoff { doneRecently.append(item) }
            } else if date < startOfToday {
                overdue.append(item)
            } else if date < startOfTomorrow {
                today.append(item)
            } else {
                upcoming.append(item)
            }
        }
        let date = { (o: Occurrence) in PlannerFormat.parse(o.occursAt) ?? .distantPast }
        overdue.sort { date($0) < date($1) }
        today.sort { date($0) < date($1) }
        upcoming.sort { date($0) < date($1) }
        doneRecently.sort { date($0) > date($1) }
    }
}

private extension Assignment {
    func withStatus(_ status: String) -> Assignment {
        Assignment(id: id, accountId: accountId, goalId: goalId, title: title, details: details,
                   assigneeId: assigneeId, scheduleKind: scheduleKind, rrule: rrule,
                   scheduledStart: scheduledStart, scheduledEnd: scheduledEnd, timezone: timezone,
                   leadTimeMinutes: leadTimeMinutes, status: status, priority: priority, hidden: hidden, archivedAt: archivedAt,
                   notes: notes, origin: origin, createdAt: createdAt, updatedAt: updatedAt)
    }
}
