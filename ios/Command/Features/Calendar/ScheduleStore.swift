//
//  ScheduleStore.swift
//  Command
//
//  Capture state for the "Schedule" mode — a forward-dated calendar event. Unlike
//  a Log (a past fact on the selected day), a Schedule creates an *assignment* (the
//  planner unit): one-off when Repeats is Never (sporadic), or recurring via an
//  rrule (routine). It lands on the calendar as an occurrence immediately.
//

import Foundation
import Observation

/// The repeat cadence offered in the Schedule selector, mapped to iCal RRULEs the
/// server validates with `dateutil.rrulestr` and expands onto the calendar.
enum RepeatRule: String, CaseIterable, Identifiable {
    case never, daily, weekly, monthly, yearly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .never:   return "Never"
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        }
    }

    /// nil for a one-off; otherwise the RRULE body (no DTSTART — the server pairs it
    /// with `scheduled_start`).
    var rrule: String? {
        switch self {
        case .never:   return nil
        case .daily:   return "FREQ=DAILY"
        case .weekly:  return "FREQ=WEEKLY"
        case .monthly: return "FREQ=MONTHLY"
        case .yearly:  return "FREQ=YEARLY"
        }
    }

    var scheduleKind: String { self == .never ? "sporadic" : "routine" }
}

@MainActor
@Observable
final class ScheduleStore {
    var draft = ""                              // the event title typed in the capture bar
    var scheduledAt = ScheduleStore.nextHour()  // Date + Time, edited by the two pickers
    var repeats: RepeatRule = .never
    var assigneeId: Int?                        // who it's for (nil resolved to "Me" by the view)
    var isSaving = false
    var errorMessage: String?

    /// Point the event at a given calendar day, preserving the chosen time-of-day.
    func useDay(_ day: Date) {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: scheduledAt)
        var d = cal.dateComponents([.year, .month, .day], from: day)
        d.hour = t.hour
        d.minute = t.minute
        if let combined = cal.date(from: d) { scheduledAt = combined }
    }

    /// Create the scheduled assignment. Returns true on success (caller reloads the calendar).
    @discardableResult
    func addToQueue(hidden: Bool = false, client: APIClient) async -> Bool {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        guard !isSaving else { return false }   // a second tap while in flight would double-create
        isSaving = true
        defer { isSaving = false }
        let body = AssignmentCreateBody(
            title: title,
            assigneeId: assigneeId,
            scheduleKind: repeats.scheduleKind,
            rrule: repeats.rrule,
            scheduledStart: Self.iso(scheduledAt),
            timezone: TimeZone.current.identifier,   // anchor recurrence to local wall-clock (DST-safe)
            status: "scheduled",
            hidden: hidden
        )
        do {
            _ = try await client.createAssignment(body)
            draft = ""
            repeats = .never
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Today at the next round hour — a sensible default start.
    static func nextHour() -> Date {
        let cal = Calendar.current
        let base = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        let onHour = cal.date(from: base) ?? Date()
        return cal.date(byAdding: .hour, value: 1, to: onHour) ?? onHour
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
