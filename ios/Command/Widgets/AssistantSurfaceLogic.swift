//
//  AssistantSurfaceLogic.swift
//  Command
//
//  Pure policy and snapshot logic shared by the app, unit tests, and widget extension.
//  It deliberately has no SwiftUI, WidgetKit, microphone, or network dependency.
//

import Foundation

// `AssistantSurfaceAvailability` used to live here — hand-rolled `osMajor >= 26 / >= 27`
// checks with unit tests asserting `26 >= 26`. Nothing ever called them. The app gates these
// features with real `#available(iOS 26.0, *)` / `@available` in ten places, which the compiler
// and the OS actually enforce; a parallel runtime copy could only drift out of agreement with
// them while its passing tests implied the gating was verified. Removed 2026-08-03. If a
// surface ever needs a *runtime* answer (e.g. explanatory copy on an older OS), use
// `#available`'s else-branch rather than reintroducing a second source of truth.

enum VoicePermissionState: Equatable {
    case authorized
    case undetermined
    case denied
}

enum VoiceLaunchDecision: Equatable {
    case beginListening
    case explainBeforeRequesting
    case openSettings
}

enum VoiceLaunchPolicy {
    /// Hardware and Lock Screen entry points must not surprise someone with a system permission
    /// alert. An undetermined permission first lands on an explanation with an explicit button.
    static func decision(for permission: VoicePermissionState) -> VoiceLaunchDecision {
        switch permission {
        case .authorized: return .beginListening
        case .undetermined: return .explainBeforeRequesting
        case .denied: return .openSettings
        }
    }
}

enum VoiceInputValidationError: Error, Equatable {
    case empty
}

enum VoiceInputValidator {
    static func cleaned(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw VoiceInputValidationError.empty }
        return value
    }
}

struct AgendaOccurrenceInput: Equatable, Sendable {
    let assignmentId: Int
    let title: String
    let occursAt: String
    let status: String
    let scheduleKind: String
    let hidden: Bool
}

struct AgendaAssignmentInput: Equatable, Sendable {
    let id: Int
    let title: String
    let scheduledStart: String?
    let status: String
    let scheduleKind: String
    let hidden: Bool
    let archived: Bool
}

struct WidgetAgendaItem: Codable, Equatable, Identifiable, Sendable {
    let assignmentId: Int
    let title: String
    let start: Date
    let status: String

    var id: String { "\(assignmentId)@\(start.timeIntervalSince1970)" }
    var isDone: Bool { status == "done" || status == "cancelled" }
}

/// What the widget draws at one instant — derived, never stored.
struct WidgetAgenda: Equatable, Sendable {
    let today: [WidgetAgendaItem]
    let nextUp: WidgetAgendaItem?
    let overdueCount: Int
    let summary: String
}

/// The app's mirror of the planner for the widget: the raw upcoming occurrences for several days
/// plus the due dates of open one-offs — NOT a pre-computed "today".
///
/// The widget used to receive today / next-up / overdue baked at write time, so they froze: after
/// midnight it kept showing yesterday, a started item stayed "next up", and nothing became
/// overdue until the app happened to write again. Storing the window lets the widget recompute
/// all three for whatever instant it renders (`agenda(at:)`), on timeline entries placed at the
/// moments the answer changes (`timelineDates(after:)`).
struct WidgetAgendaSnapshot: Codable, Equatable, Sendable {
    /// How many days of occurrences, starting today, the app mirrors.
    static let windowDays = 7

    let generatedAt: Date
    /// Visible occurrences from the start of `generatedAt`'s day for `windowDays`, sorted.
    let items: [WidgetAgendaItem]
    /// `scheduled_start` of every open, visible, one-off assignment — overdue once it passes.
    let openSporadicStarts: [Date]

    static func empty(at date: Date = Date()) -> WidgetAgendaSnapshot {
        WidgetAgendaSnapshot(generatedAt: date, items: [], openSporadicStarts: [])
    }

    /// The agenda as of `now`: today's items, the next not-done item still ahead, the count of
    /// one-offs whose start has passed.
    func agenda(at now: Date, calendar: Calendar = .current) -> WidgetAgenda {
        let today = items.filter { calendar.isDate($0.start, inSameDayAs: now) }
        let summary: String
        switch today.count {
        case 0: summary = "Nothing scheduled today"
        case 1: summary = "1 item today"
        default: summary = "\(today.count) items today"
        }
        return WidgetAgenda(
            today: today,
            nextUp: today.first { !$0.isDone && $0.start >= now },
            overdueCount: openSporadicStarts.filter { $0 < now }.count,
            summary: summary
        )
    }

    /// The instants after `now` (within `horizon`) at which `agenda(at:)` changes: just after each
    /// item starts (next-up moves on), each one-off's start (overdue ticks up), and each midnight
    /// (a new "today"). The widget's timeline puts an entry at each.
    func timelineDates(after now: Date, horizon: TimeInterval = 24 * 60 * 60,
                       calendar: Calendar = .current) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var dates = Set<Date>()
        // One second past the start: at the start instant itself the item is still "next up".
        for item in items where !item.isDone { dates.insert(item.start.addingTimeInterval(1)) }
        for start in openSporadicStarts { dates.insert(start) }
        var midnight = calendar.startOfDay(for: now)
        while let next = calendar.date(byAdding: .day, value: 1, to: midnight), next <= end {
            dates.insert(next)
            midnight = next
        }
        return dates.filter { $0 > now && $0 <= end }.sorted()
    }

    /// Back-compat views of the agenda at write time (tests + the fingerprint read these).
    var today: [WidgetAgendaItem] { agenda(at: generatedAt).today }
    var nextUp: WidgetAgendaItem? { agenda(at: generatedAt).nextUp }
    var overdueCount: Int { agenda(at: generatedAt).overdueCount }
    var summary: String { agenda(at: generatedAt).summary }

    /// Identity of the data the widget renders from.
    ///
    /// `generatedAt` is deliberately excluded. It moves on every write, so a plain equality
    /// check would call every snapshot "new" — and the caller uses this to decide whether to
    /// spend a WidgetKit timeline reload, which is a metered resource (tens per day, not
    /// thousands). See `WidgetAgendaStore.save`.
    var contentFingerprint: String {
        let rows = items.map {
            "\($0.assignmentId)|\($0.start.timeIntervalSince1970)|\($0.status)|\($0.title)"
        }
        let due = openSporadicStarts.map { String($0.timeIntervalSince1970) }.joined(separator: ",")
        return ([due] + rows).joined(separator: "\n")
    }
}

enum WidgetAgendaBuilder {
    /// The span of occurrences the app mirrors: the start of `now`'s day for `windowDays` days.
    /// Independent of whatever month the in-app calendar happens to be showing.
    static func window(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: WidgetAgendaSnapshot.windowDays, to: start)
            ?? start.addingTimeInterval(TimeInterval(WidgetAgendaSnapshot.windowDays * 86_400))
        return (start, end)
    }

    static func make(
        occurrences: [AgendaOccurrenceInput],
        assignments: [AgendaAssignmentInput],
        now: Date,
        calendar: Calendar = .current
    ) -> WidgetAgendaSnapshot {
        let span = window(now: now, calendar: calendar)
        var seen = Set<String>()
        let items = occurrences.compactMap { input -> WidgetAgendaItem? in
            guard !input.hidden, let start = parse(input.occursAt),
                  start >= span.start, start < span.end else { return nil }
            return WidgetAgendaItem(
                assignmentId: input.assignmentId,
                title: input.title,
                start: start,
                status: input.status
            )
        }
        .filter { seen.insert($0.id).inserted }
        .sorted { $0.start < $1.start }

        let openSporadicStarts = assignments.compactMap { assignment -> Date? in
            guard assignment.scheduleKind == "sporadic",
                  !assignment.hidden,
                  !assignment.archived,
                  assignment.status != "done",
                  assignment.status != "cancelled",
                  let raw = assignment.scheduledStart else { return nil }
            return parse(raw)
        }
        .sorted()

        return WidgetAgendaSnapshot(generatedAt: now, items: items, openSporadicStarts: openSporadicStarts)
    }

    private static func parse(_ value: String) -> Date? {
        if let date = fractional.date(from: value) { return date }
        return internet.date(from: value)
    }

    private static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum WidgetAgendaStore {
    static let appGroup = "group.com.legitimateapps.command"
    /// The agenda widget's timeline kind. Declared here — the one file both the app and the
    /// extension compile — so the widget, the writer and the sign-out path can't drift onto
    /// three different strings, which fails silently as "reloads that reload nothing".
    static let agendaKind = "CommandAgenda"
    // v2: the snapshot became a window of raw occurrences (v1 held a baked "today"). A v1
    // payload no longer decodes, so it lives under new keys; the v1 keys are purged on every
    // save/clear so an old account's titles don't linger in the App Group.
    private static let key = "widget.agenda.snapshot.v2"
    private static let fingerprintKey = "widget.agenda.fingerprint.v2"
    private static let legacyKeys = ["widget.agenda.snapshot.v1", "widget.agenda.fingerprint.v1"]

    /// Persists the snapshot and reports whether the DRAWN content changed.
    ///
    /// The app writes on every planner mutation, and `WidgetCenter.reloadTimelines` is
    /// budgeted by the system — a handful of dozens of reloads a day. Reloading on every
    /// write burns that budget within minutes of normal use, after which iOS silently stops
    /// honouring reloads and the widget goes stale for the rest of the day. Callers reload
    /// only when this returns `true`; the widget recomputes time-dependent parts itself.
    @discardableResult
    static func save(_ snapshot: WidgetAgendaSnapshot) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        let fingerprint = snapshot.contentFingerprint
        let changed = defaults.string(forKey: fingerprintKey) != fingerprint
        // The payload is written either way so `generatedAt` stays honest; only the reload
        // — the metered part — is gated.
        defaults.set(data, forKey: key)
        defaults.set(fingerprint, forKey: fingerprintKey)
        legacyKeys.forEach(defaults.removeObject(forKey:))
        return changed
    }

    /// Drop the mirrored agenda. Returns whether anything was actually there to remove, so the
    /// caller only spends a timeline reload when the widget would draw something different.
    ///
    /// The widget renders from the App Group, not from the session — it is a separate process
    /// that never sees a sign-out. `AppState.tearDownSession` clears every in-app store for
    /// exactly this reason ("or the next account briefly sees the prior account's
    /// occurrences"), but that only reaches state inside the app: without this, signing out
    /// left the previous account's assignment titles and times on the home screen indefinitely,
    /// and account deletion left them there permanently.
    ///
    /// Stays pure Foundation — this file is compiled into the extension, which is
    /// `APPLICATION_EXTENSION_API_ONLY` and deliberately free of WidgetKit. The reload is the
    /// app's job, exactly as it already is for `save`.
    @discardableResult
    static func clear() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return false }
        let hadContent = defaults.data(forKey: key) != nil
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: fingerprintKey)
        legacyKeys.forEach(defaults.removeObject(forKey:))
        return hadContent
    }

    static func load(now: Date = Date()) -> WidgetAgendaSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(WidgetAgendaSnapshot.self, from: data) else {
            return .empty(at: now)
        }
        return snapshot
    }
}
