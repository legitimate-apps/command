//
//  MarketingSeed.swift
//  Command
//
//  DEBUG-only. Story-driven sample data for App Store screenshot capture, launched with
//  `-COMMAND_UI_PREVIEW YES -COMMAND_MARKETING_SEED YES`.
//
//  Distinct from `COMMAND_PREVIEW_SEED` (the terse fixture used for UI verification): this one
//  is composed to photograph well and to tell one coherent story across the five store screens —
//  capture → plan → delegate → the roster → the assistant.
//
//  Ground rules, because these frames go on a public product page:
//    * Everything here must be something the app ACTUALLY does. No aspirational fiction.
//    * Names and content are invented and generic on purpose — never the operator's real life.
//    * Dates are relative to the real today (see below), so a set shot at any time looks current
//      and the simulator's own status bar never contradicts the app.
//

#if DEBUG
import Foundation

enum MarketingSeed {
    /// Every date is an offset in days from the *real* today, resolved at launch.
    ///
    /// The obvious alternative — hard-code "2026-08-17" and freeze the app's clock with
    /// `sim-faketime` — was tried first and abandoned. libfaketime moves the app's clock but not
    /// the simulator's status bar, and `simctl status_bar --time` rejects an ISO date on this
    /// runtime (only a bare "9:41" is accepted), so the iPad status bar kept showing the real date
    /// beside an app showing a fabricated one. Anchoring to the real today makes them agree for
    /// free, drops the faketime dependency, and means a set regenerated next year doesn't show
    /// last year's dates.
    static let zone = TimeZone.current.identifier

    private static let cal = Calendar(identifier: .gregorian)

    /// `days` from today at `h:m` local, as an ISO-8601 instant with the device's real UTC offset.
    /// Stamping in UTC instead would render every time shifted by the offset — a 7am run seeded as
    /// "07:00Z" reads "3:00 AM" on an America/New_York device.
    private static func at(_ days: Int, _ h: Int = 9, _ m: Int = 0) -> String {
        let base = cal.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let day = cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: day)
    }

    /// `days` from today as a plain calendar date ("2026-09-01") — the shape `target_date` takes.
    private static func day(_ days: Int) -> String {
        let d = cal.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: People — the roster. The whole point of the app: humans AND AI models, side by side,
    // each with the notice window they actually need.
    static func delegatees() -> [Delegatee] {
        let ts = at(-46)
        return [
            Delegatee(id: 1, accountId: 0, slug: "dana", name: "Dana Whitlock", kind: "human",
                      leadTimeMinutes: 1440,
                      metadata: ["note": .string("Contractor. Needs a day's notice.")],
                      active: true, isSelf: false, createdAt: ts, updatedAt: ts),
            Delegatee(id: 2, accountId: 0, slug: "opus", name: "Claude Opus", kind: "ai_model",
                      leadTimeMinutes: 0,
                      metadata: ["model_id": .string("claude-opus-5.5")],
                      active: true, isSelf: false, createdAt: ts, updatedAt: ts),
            Delegatee(id: 3, accountId: 0, slug: "marcus", name: "Marcus Lee", kind: "human",
                      leadTimeMinutes: 120,
                      metadata: ["note": .string("Photographer.")],
                      active: true, isSelf: false, createdAt: ts, updatedAt: ts),
            Delegatee(id: 4, accountId: 0, slug: "priya", name: "Priya Raman", kind: "human",
                      leadTimeMinutes: 10080,
                      metadata: ["note": .string("Books up a week out.")],
                      active: true, isSelf: false, createdAt: ts, updatedAt: ts),
            Delegatee(id: 6, accountId: 0, slug: "haiku", name: "Claude Haiku", kind: "ai_model",
                      leadTimeMinutes: 0,
                      metadata: ["model_id": .string("claude-haiku-4.5")],
                      active: true, isSelf: false, createdAt: ts, updatedAt: ts),
            Delegatee(id: 7, accountId: 0, slug: "jonah", name: "Jonah Reyes", kind: "human",
                      leadTimeMinutes: 2880,
                      metadata: ["note": .string("Bookkeeper. Two days, always.")],
                      active: true, isSelf: false, createdAt: ts, updatedAt: ts),
            Delegatee(id: 8, accountId: 0, slug: "sofia", name: "Sofia Marchetti", kind: "human",
                      leadTimeMinutes: 240,
                      metadata: ["note": .string("Runs the Saturday market stall.")],
                      active: true, isSelf: false, createdAt: ts, updatedAt: ts),
        ]
    }

    static func me() -> Delegatee {
        let ts = at(-46)
        return Delegatee(id: 5, accountId: 0, slug: "me", name: "Me", kind: "human",
                         leadTimeMinutes: 0, metadata: [:], active: true, isSelf: true,
                         createdAt: ts, updatedAt: ts)
    }

    // MARK: Notes — fast capture, typed and spoken. One shows the on-device voice engine.
    static func notes() -> [Note] {
        func note(_ id: Int, _ title: String, _ body: String, day: Int,
                  source: String = "text", engine: String? = nil) -> Note {
            Note(id: id, accountId: 0, body: body, title: title, titleStatus: "user",
                 source: source, engine: engine, locale: engine == nil ? nil : "en-US",
                 processedAt: nil, archivedAt: nil, hidden: false,
                 createdAt: at(day, 8, 12), updatedAt: at(day, 8, 12))
        }
        return [
            note(1, "The corner unit is the one",
                 "The corner unit is the one. Better light, and the loading door means we stop carrying kilns up the stairs. Landlord wants an answer by Friday.",
                 day: 0, source: "voice", engine: "parakeet-v3"),
            note(2, "Opening night",
                 "Opening night: keep it small. Cardamom coffee, the good cups, no speeches.",
                 day: -1),
            note(3, "Glaze test — copper red",
                 "Copper red went muddy at cone 6. Try a slower cool, or move it to cone 10.",
                 day: -2),
            note(4, "Ask Priya about the kiln",
                 "Priya knows someone who reconditions kilns. Worth asking before we buy new.",
                 day: -3),
        ]
    }

    // MARK: Goals — real objects now: a target date, and the work that advances them.
    static func goals() -> [Goal] {
        [
            Goal(id: 1, accountId: 0, title: "Open the studio",
                 description: "Corner unit on Wren St. Doors open before the autumn market.",
                 status: "in_progress", targetDate: day(15), notes: nil,
                 createdAt: at(-38), updatedAt: at(-1)),
            Goal(id: 2, accountId: 0, title: "Run the half marathon",
                 description: nil, status: "open", targetDate: day(56), notes: nil,
                 createdAt: at(-28), updatedAt: at(-16)),
        ]
    }

    // MARK: Assignments — the work, delegated. Note the mix of human and AI assignees, the
    // goal links, and the per-assignment lead times.
    static func assignments() -> [Assignment] {
        func a(_ id: Int, _ title: String, goal: Int?, assignee: Int?, status: String,
               day: Int?, h: Int = 9, m: Int = 0, lead: Int?, kind: String = "sporadic",
               rrule: String? = nil, details: String? = nil, priority: Int = 0) -> Assignment {
            Assignment(id: id, accountId: 0, goalId: goal, title: title, details: details,
                       assigneeId: assignee, scheduleKind: kind, rrule: rrule,
                       scheduledStart: day.map { at($0, h, m) }, scheduledEnd: nil,
                       timezone: zone, leadTimeMinutes: lead, status: status,
                       priority: priority, hidden: false, archivedAt: nil, notes: nil, origin: "manual",
                       createdAt: at(-38), updatedAt: at(-1))
        }
        return [
            a(1, "Sign the lease", goal: 1, assignee: 5, status: "done",
              day: -3, lead: 0),
            a(2, "Meet the contractor at the unit", goal: 1, assignee: 1, status: "scheduled",
              day: 0, h: 10, m: 30, lead: 1440,
              details: "Walk the space, talk shelving and the kiln vent."),
            a(3, "Photograph the empty space", goal: 1, assignee: 3, status: "scheduled",
              day: 0, h: 15, lead: 120),
            a(4, "Draft the opening announcement", goal: 1, assignee: 2, status: "in_progress",
              day: 1, lead: 0,
              details: "Warm, short, no hard sell. Mention the Saturday hours."),
            a(5, "Order the shelving", goal: 1, assignee: 5, status: "todo",
              day: 4, lead: 0),
            a(6, "Ask about the reconditioned kiln", goal: 1, assignee: 4, status: "todo",
              day: 9, lead: 10080),
            a(7, "Long run", goal: 2, assignee: 5, status: "todo",
              day: 0, h: 7, lead: 0, kind: "routine",
              rrule: "FREQ=WEEKLY"),
        ]
    }

    // MARK: The day, on the calendar.
    static func occurrences() -> [Occurrence] {
        func o(_ aid: Int, _ title: String, _ h: Int, _ m: Int, _ status: String,
               assignee: Int?, kind: String = "sporadic") -> Occurrence {
            Occurrence(assignmentId: aid, title: title, occursAt: at(0, h, m),
                       status: status, assigneeId: assignee, scheduleKind: kind, hidden: false,
                       dayIndex: nil, dayCount: nil)
        }
        return [
            o(7, "Long run", 7, 0, "todo", assignee: 5, kind: "routine"),
            o(2, "Meet the contractor at the unit", 10, 30, "scheduled", assignee: 1),
            o(3, "Photograph the empty space", 15, 0, "scheduled", assignee: 3),
        ]
    }

    // MARK: The assistant, mid-conversation — a captured note becoming a scheduled, delegated
    // plan. Every tool named here is a tool the agent really has.
    static func transcript() -> [ChatMessage] {
        [
            ChatMessage(role: "user",
                        text: "I decided on the corner unit. Turn this week's note into a plan and get Dana out there — she needs a day's notice."),
            ChatMessage(
                role: "assistant",
                text: """
                Done. I read the note from this morning and set it up under **Open the studio**:

                - **Meet the contractor at the unit** — Dana, tomorrow 10:30. That clears her \
                one-day notice with an hour to spare.
                - **Photograph the empty space** — Marcus, 3:00, after the walkthrough.
                - **Draft the opening announcement** — me, once the photos land.

                The landlord wants an answer by Friday, so I left **Sign the lease** where it was.
                """,
                model: "claude-opus-5.5",
                tools: [
                    ChatToolEvent(name: "search_notes", done: true, detail: "corner unit"),
                    ChatToolEvent(name: "create_assignment", done: true,
                                  detail: "Meet the contractor at the unit",
                                  entity: AgentEntityRef(kind: "assignment", id: 2,
                                                         label: "Meet the contractor at the unit")),
                    ChatToolEvent(name: "create_assignment", done: true,
                                  detail: "Photograph the empty space",
                                  entity: AgentEntityRef(kind: "assignment", id: 3,
                                                         label: "Photograph the empty space")),
                ]),
        ]
    }
}
#endif
