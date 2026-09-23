//
//  PlannerFormat.swift
//  Command
//
//  Display helpers for assignments: schedule summaries (RRULE + dates), status
//  colors/labels, and the client-side lead-time warning used live in the create
//  flow (mirrors the server's assign-time warning).
//

import SwiftUI

enum PlannerFormat {
    static let statuses = ["todo", "scheduled", "in_progress", "done", "blocked", "cancelled", "skipped"]

    static func statusLabel(_ status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "done", "scheduled": return Palette.sage
        case "in_progress": return Palette.accent
        case "blocked": return .red
        case "skipped": return .red.opacity(0.55)   // "didn't do it" — softer than blocked
        case "cancelled": return Palette.inkSecondary
        default: return Palette.inkSecondary // todo
        }
    }

    /// A one-off assignment whose scheduled time has passed and isn't done/cancelled. Recurring
    /// (routine) items are excluded — their DTSTART is in the past by nature, so "overdue" is
    /// meaningless for them.
    static func isOverdue(_ a: Assignment, now: Date = Date()) -> Bool {
        guard a.scheduleKind != "routine",
              a.status != "done", a.status != "cancelled",
              let start = a.scheduledStart, let date = parse(start) else { return false }
        return date < now
    }

    static func scheduleSummary(_ a: Assignment) -> String {
        if a.scheduleKind == "routine", let rule = a.rrule { return rruleSummary(rule) }
        if let start = a.scheduledStart, let date = parse(start) { return dateFormatter.string(from: date) }
        return "Unscheduled"
    }

    /// Says, in words, when an assignment's reminder actually fires — mirroring the server's rule
    /// `remind_at = occurs_at - lead_time` (`core/reminders.py`).
    ///
    /// The detail page used to show a bare "Lead time 0", which explained nothing: a self-assigned
    /// item read 0 and looked broken, and there was no way to see when — or whether — a reminder
    /// would land. `sourceName` is non-nil when the offset is inherited from that delegatee's notice
    /// window rather than set on the assignment itself.
    static func reminderSummary(scheduleKind: String, scheduledStart: String?, status: String,
                                effectiveLead: Int, sourceName: String? = nil) -> String {
        if status == "done" || status == "cancelled" {
            return "This is \(statusLabel(status).lowercased()) — no reminder will fire."
        }
        let source = sourceName.map { " (from \($0))" } ?? ""
        if scheduleKind == "routine" {
            return effectiveLead == 0
                ? "Reminds at each occurrence\(source)."
                : "Reminds \(LeadTime.label(effectiveLead).lowercased()) before each occurrence\(source)."
        }
        guard let start = scheduledStart, let at = parse(start) else {
            return "Not scheduled, so no reminder will fire. Give it a date first."
        }
        let fires = stamp.string(from: at.addingTimeInterval(-Double(effectiveLead) * 60))
        return effectiveLead == 0
            ? "Reminds at \(fires)\(source)."
            : "Reminds \(fires)\(source) — \(LeadTime.label(effectiveLead).lowercased()) before it's due."
    }

    /// Live lead-time warning for the create flow. Returns nil when fine.
    static func leadWarning(scheduledStart: String?, leadMinutes: Int, name: String) -> String? {
        guard leadMinutes > 0, let start = scheduledStart, let date = parse(start) else { return nil }
        let minutesUntil = date.timeIntervalSinceNow / 60
        guard minutesUntil < Double(leadMinutes) else { return nil }
        return "\(name) usually needs \(LeadTime.label(leadMinutes)) notice — this is sooner."
    }

    static func parse(_ iso: String) -> Date? {
        isoFractional.date(from: iso) ?? isoPlain.date(from: iso)
    }

    /// Parses a *day* value — a goal's `target_date`, which the MCP and agent tools document as an
    /// "ISO date" and write date-only ("2026-10-21"). `parse` is ISO8601DateFormatter-based and
    /// returns nil for date-only input, which silently hid the Target row for every goal an agent
    /// created. Accepts both shapes; a day is a wall-clock date, so it anchors to the local zone.
    static func parseDay(_ value: String) -> Date? {
        dayOnly.date(from: value) ?? parse(value)
    }

    /// Display label for a day value. Falls back to the raw string rather than rendering nothing —
    /// showing an odd-looking date beats silently dropping the user's data.
    static func dayLabel(_ value: String) -> String {
        parseDay(value).map { dayDisplay.string(from: $0) } ?? value
    }

    /// Serializes a picked date to the date-only form the server + agent tools expect.
    static func dayString(_ date: Date) -> String { dayOnly.string(from: date) }

    private static func rruleSummary(_ rule: String) -> String {
        var freq = ""
        var days: [String] = []
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=")
            guard kv.count == 2 else { continue }
            if kv[0] == "FREQ" { freq = String(kv[1]).capitalized }
            if kv[0] == "BYDAY" { days = kv[1].split(separator: ",").map { dayName(String($0)) } }
        }
        var summary = freq.isEmpty ? "Repeats" : freq
        if !days.isEmpty { summary += " · " + days.joined(separator: ", ") }
        return summary
    }

    private static func dayName(_ code: String) -> String {
        ["MO": "Mon", "TU": "Tue", "WE": "Wed", "TH": "Thu", "FR": "Fri", "SA": "Sat", "SU": "Sun"][code] ?? code
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · h:mm a"
        return f
    }()
    /// Fixed-format parser/serializer for date-only values. POSIX locale so it can't be broken by
    /// the device's calendar or region settings.
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let dayDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
}
