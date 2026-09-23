//
//  CalendarStore.swift
//  Command
//
//  Month-grid state: which month is visible, which day is selected, and the
//  occurrences (routine RRULEs expanded + sporadic) the server returns for the
//  whole visible 6-week window.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class CalendarStore {
    var visibleMonth: Date
    var selectedDay: Date
    var occurrences: [Occurrence] = []
    var activities: [Activity] = []
    var isLoading = false
    var errorMessage: String?

    private let cal = Calendar.current
    // Bumped on each load; a slower earlier load whose token is stale discards its result
    // so rapid month-stepping can't paint an earlier month's events onto the current one.
    private var loadGeneration = 0

    init() {
        let now = Date()
        visibleMonth = CalendarStore.firstOfMonth(now, cal: Calendar.current)
        selectedDay = Calendar.current.startOfDay(for: now)
    }

    /// The 42 days (6 weeks) shown in the grid for the visible month.
    var gridDays: [Date] {
        let firstOfMonth = CalendarStore.firstOfMonth(visibleMonth, cal: cal)
        let weekday = cal.component(.weekday, from: firstOfMonth)
        let leading = (weekday - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -leading, to: firstOfMonth)!
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    var monthTitle: String {
        Self.monthFormatter.string(from: visibleMonth)
    }

    func isInVisibleMonth(_ day: Date) -> Bool {
        cal.isDate(day, equalTo: visibleMonth, toGranularity: .month)
    }

    func isToday(_ day: Date) -> Bool { cal.isDateInToday(day) }
    func isSelected(_ day: Date) -> Bool { cal.isDate(day, inSameDayAs: selectedDay) }

    func occurrences(on day: Date) -> [Occurrence] {
        // Sort by the PARSED instant, not the raw ISO string: agent/MCP-created occurrences can
        // carry a non-UTC offset (…T09:00:00-04:00) that string-sorts before a later …+00:00 time
        // though it's chronologically after it. Parse once per item and order by Date.
        occurrences
            .compactMap { occ in PlannerFormat.parse(occ.occursAt).map { (occ, $0) } }
            .filter { cal.isDate($0.1, inSameDayAs: day) }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }

    func count(on day: Date) -> Int { occurrences(on: day).count }

    /// Spontaneous logged facts on a day. Completion activities are omitted — they're
    /// already represented by their occurrence's done state, so we don't double-show them.
    func activities(on day: Date) -> [Activity] {
        activities
            .filter { !$0.isCompletion }
            .compactMap { act in PlannerFormat.parse(act.occurredAt).map { (act, $0) } }
            .filter { cal.isDate($0.1, inSameDayAs: day) }
            .sorted { $0.1 > $1.1 }   // newest first, by parsed instant (not raw string)
            .map { $0.0 }
    }

    func loggedCount(on day: Date) -> Int { activities(on: day).count }

    func load(client: APIClient) async {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        defer { if gen == loadGeneration { isLoading = false } }
        guard let start = gridDays.first, let lastDay = gridDays.last,
              let end = cal.date(byAdding: .day, value: 1, to: lastDay) else { return }
        let startISO = Self.iso(start), endISO = Self.iso(end)
        do {
            async let occ = client.calendar(start: startISO, end: endISO)   // expanded server-side, not paged
            async let acts = client.drainAll { limit, cursor in
                try await client.listActivities(start: startISO, end: endISO, limit: limit, cursor: cursor)
            }
            let o = try await occ
            let a = try await acts
            guard gen == loadGeneration else { return }   // a newer load superseded this one
            withAnimation(.snappy) {
                occurrences = o
                activities = a
            }
            errorMessage = nil
        } catch {
            guard gen == loadGeneration else { return }
            // Don't blank the grid on a transient failure — a momentary network blip would make
            // every event look deleted. Keep what we have and surface the error for a retry.
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func step(months: Int, client: APIClient) async {
        if let next = cal.date(byAdding: .month, value: months, to: visibleMonth) {
            visibleMonth = CalendarStore.firstOfMonth(next, cal: cal)
            // Move the selection into the newly visible month (the 1st) so the highlighted cell and
            // the day-agenda don't keep pointing at a day that's no longer on the grid.
            selectedDay = visibleMonth
            await load(client: client)
        }
    }

    /// Drag-to-reschedule (spec 2026-07-19-later-bucket). A routine occurrence moves via a
    /// per-occurrence override — just this one, series untouched; a sporadic assignment IS its
    /// occurrence, so its scheduled_start updates. Multi-day spans don't drag (each row is one
    /// day of one event — edit the assignment instead).
    func move(_ occ: Occurrence, to newInstant: Date, client: APIClient) async {
        if (occ.dayCount ?? 1) > 1 {
            errorMessage = "Multi-day events can't be dragged. Edit the assignment's dates instead."
            return
        }
        let iso = Self.isoWithLocalOffset(newInstant)
        do {
            if occ.scheduleKind == "routine" {
                try await client.rescheduleOccurrence(assignmentId: occ.assignmentId,
                                                      occurrenceDate: occ.dateKey, occursAt: iso)
            } else {
                // Move the end by the same delta: a one-off dragged to another day used to keep its
                // old scheduled_end, ending before it began (or spanning the days in between).
                let current = try await client.assignment(id: occ.assignmentId)
                let end = Self.shiftedEnd(start: current.scheduledStart, end: current.scheduledEnd, to: newInstant)
                try await client.updateAssignmentSchedule(id: occ.assignmentId, scheduledStart: iso,
                                                          scheduledEnd: end.map(Self.isoWithLocalOffset))
            }
            errorMessage = nil
            await load(client: client)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A one-off's end once its start moves to `newStart`: shifted by the same delta, so the event
    /// keeps its duration. nil when it has no end (nothing to move) or the stored instants don't parse.
    nonisolated static func shiftedEnd(start: String?, end: String?, to newStart: Date) -> Date? {
        guard let s = start.flatMap(PlannerFormat.parse), let e = end.flatMap(PlannerFormat.parse) else { return nil }
        return e.addingTimeInterval(newStart.timeIntervalSince(s))
    }

    /// Reset a dragged routine occurrence back to its series time.
    func resetOverride(_ occ: Occurrence, client: APIClient) async {
        do {
            try await client.resetOccurrence(assignmentId: occ.assignmentId, occurrenceDate: occ.dateKey)
            errorMessage = nil
            await load(client: client)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Set one occurrence's status without changing its assignment/series. `occurrenceDate` is the
    /// server's expansion key — `occ.dateKey`, the ORIGINAL series date the server sent, which a
    /// rescheduled occurrence keeps even though its `occursAt` moved to another day. Replace the
    /// in-memory occurrence as soon as the write succeeds, then reconcile in the background-sized
    /// calendar window; `load` deliberately retains the current rows while fetching, avoiding a
    /// blank/flickering agenda.
    func setOccurrenceStatus(_ status: String, for occ: Occurrence, client: APIClient) async {
        let date = occ.dateKey
        do {
            try await client.setOccurrenceStatus(assignmentId: occ.assignmentId,
                                                 occurrenceDate: date, status: status)
            if let index = occurrences.firstIndex(where: { $0.id == occ.id }) {
                occurrences[index] = occ.withStatus(status)
            }
            await load(client: client)   // refresh the status overlay + any logged completion
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Drop every occurrence of an assignment that was deleted or archived elsewhere, so the grid
    /// and day agenda stop showing it without waiting for a reload.
    func removeOccurrences(ofAssignment id: Int) {
        occurrences.removeAll { $0.assignmentId == id }
    }

    func goToToday(client: APIClient) async {
        let now = Date()
        visibleMonth = CalendarStore.firstOfMonth(now, cal: cal)
        selectedDay = cal.startOfDay(for: now)
        await load(client: client)
    }

    private static func firstOfMonth(_ date: Date, cal: Calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }
    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
    /// ISO instant carrying the device's UTC offset (…T14:30:00-04:00) — a dragged time means
    /// "this local wall-clock time"; stamping UTC would shift it by the offset on display.
    static func isoWithLocalOffset(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}
