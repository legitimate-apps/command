//
//  Models.swift
//  Command
//
//  Codable shapes mirroring the server's JSON. The APIClient decodes with
//  convertFromSnakeCase, so these use camelCase. Timestamps stay as ISO-8601
//  strings (the server's canonical form); the UI formats them on demand.
//

import Foundation

// MARK: - Arbitrary JSON (delegatee metadata is free-form)

enum JSONValue: Codable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// The underlying string when this value is a JSON string, else nil. Used to pull a
    /// clean target (title / name / query) out of a tool call's `args` without coercing
    /// numbers/bools/objects into text.
    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Human-readable one-liner for displaying metadata values in the UI.
    var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "yes" : "no"
        case .null: return "—"
        case .array(let a): return a.map(\.displayString).joined(separator: ", ")
        case .object(let o): return o.map { "\($0): \($1.displayString)" }.joined(separator: ", ")
        }
    }
}

// MARK: - Entities

struct Account: Codable, Equatable, Identifiable {
    let id: Int
    let username: String
    let displayName: String?
    let createdAt: String
    /// The account's IANA timezone (e.g. "America/New_York"), used to anchor the agent's
    /// relative-date reasoning. Optional: older servers omit it (added with B1). The app
    /// pushes `TimeZone.current` up on login/foreground and reads the resolved value back.
    var timezone: String? = nil
}

struct Note: Codable, Equatable, Identifiable {
    let id: Int
    let accountId: Int
    let body: String
    let title: String?
    let titleStatus: String?        // nil | generating | ai | user | error
    let source: String
    let engine: String?
    let locale: String?
    let processedAt: String?
    let archivedAt: String?
    let hidden: Bool?               // invisible-ink veil; nil from a pre-migration server → treated as false
    let createdAt: String
    let updatedAt: String
}

/// A point-in-time backup of a note's {title, body}, captured when the note is
/// closed. The API returns at most 5 per note, newest first.
struct NoteRevision: Codable, Equatable, Identifiable {
    let id: Int
    let noteId: Int
    let accountId: Int
    let title: String?
    let body: String
    let createdAt: String
}

extension Note {
    /// The note's display name: its title, else the first non-empty line of the body — with
    /// markdown punctuation stripped so a row reads "Plan" rather than "## Plan". Storage keeps the
    /// raw markdown; this is presentation only, matching the live editor.
    var displayTitle: String {
        let raw: String
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            raw = t
        } else {
            raw = Note.firstLine(of: body)
        }
        let plain = MarkdownSyntax.plainText(raw, singleLine: true)
        return plain.isEmpty ? raw : plain
    }
    /// True while the backend is generating an AI title.
    var isTitlePending: Bool { titleStatus == "generating" }
    /// Whether a real (non-empty) title exists.
    var hasTitle: Bool {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !t.isEmpty
    }
    static func firstLine(of body: String) -> String {
        for line in body.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Body text for a list row: the whole body when a real title exists, otherwise
    /// the body with its first (title-serving) line removed so it isn't shown twice. Markdown
    /// punctuation is stripped so the two-line preview reads as prose, not source.
    var listPreview: String {
        let lines = body.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        let firstLine = lines[idx].trimmingCharacters(in: .whitespaces)
        let titleTrim = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // In the one-field editor the title IS the first body line, so the preview is the remainder
        // (skip the title line, don't repeat it). A legacy note with a distinct title shows the body.
        let raw: String
        if titleTrim.isEmpty || titleTrim == firstLine {
            raw = lines[(idx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            raw = body
        }
        return MarkdownSyntax.plainText(raw)
    }
}

struct Delegatee: Codable, Equatable, Identifiable {
    let id: Int
    let accountId: Int
    let slug: String
    let name: String
    let kind: String                // "human" | "ai_model"
    let leadTimeMinutes: Int
    let metadata: [String: JSONValue]
    let active: Bool
    let isSelf: Bool                 // the hidden "Me" actor — hidden from the delegate-to-others roster
    let createdAt: String
    let updatedAt: String
}

/// The narrow identity returned for an invited delegatee. Delegatee sessions do not expose an
/// `Account`; this is the complete identity needed by the dedicated My Work shell.
struct MyProfile: Codable, Equatable {
    let delegateeId: Int
    let delegateeName: String
    let operatorDisplayName: String?
}

struct DelegateeInvite: Codable, Equatable {
    let inviteToken: String
}

struct OccurrenceStatusResult: Codable, Equatable {
    let updated: Bool
}

/// A file attached to a note or an assignment. Bytes live on the server (fetched on demand
/// for preview); this is the metadata row.
struct Attachment: Codable, Equatable, Identifiable {
    let id: Int
    let accountId: Int
    let entityKind: String          // note | assignment
    let entityId: Int
    let filename: String
    let mime: String
    let sizeBytes: Int
    let sha256: String
    let createdAt: String

    var isImage: Bool { mime.hasPrefix("image/") }
}

struct Goal: Codable, Equatable, Identifiable {
    let id: Int
    let accountId: Int
    let title: String
    let description: String?
    let status: String              // open | in_progress | done | dropped
    let targetDate: String?
    let notes: String?              // persistent free-text working area (detail page)
    let createdAt: String
    let updatedAt: String
}

struct Assignment: Codable, Equatable, Identifiable {
    let id: Int
    let accountId: Int
    let goalId: Int?
    let title: String
    let details: String?
    let assigneeId: Int?
    let scheduleKind: String        // routine | sporadic
    let rrule: String?
    let scheduledStart: String?
    let scheduledEnd: String?
    let timezone: String?           // IANA zone anchoring recurrence expansion (DST-correct)
    let leadTimeMinutes: Int?
    let status: String              // todo | scheduled | in_progress | done | blocked | cancelled
    let priority: Int
    let hidden: Bool?
    let archivedAt: String?         // set = archived (off calendar/lists/reminders; restorable)
    let notes: String?              // persistent free-text working area (detail page)
    let origin: String?             // provenance: manual | agent | note:<id>
    let createdAt: String
    let updatedAt: String
}

extension Assignment {
    var isArchived: Bool { archivedAt != nil }
}

/// A detail-page checklist item (assignment / goal / activity). `source` distinguishes
/// user-added items from AI-generated ones (the latter arrives in a later release).
struct TaskItem: Codable, Equatable, Identifiable {
    let id: Int
    let parentType: String          // assignment | goal | activity
    let parentId: Int
    let text: String
    let done: Bool
    let source: String              // user | ai
    let position: Int
    let createdAt: String
    let updatedAt: String
}

struct Occurrence: Codable, Equatable, Identifiable {
    let assignmentId: Int
    let title: String
    let occursAt: String
    let status: String
    let assigneeId: Int?
    let scheduleKind: String
    let hidden: Bool?
    // Multi-day span context (a first-class multi-day event expands to one occurrence per day).
    // 1-based `dayIndex` of `dayCount`; both nil for single-day / recurring occurrences.
    var dayIndex: Int? = nil
    var dayCount: Int? = nil
    // The occurrence's identity key — the ORIGINAL expansion date the server keys status and
    // reschedule overrides on. With an override in play this differs from occursAt's date, so
    // always key API calls on `dateKey`, never on a date re-derived from occursAt.
    var occurrenceDate: String? = nil
    // True when this occurrence was dragged off its series time (an occurrence_override exists).
    var rescheduled: Bool? = nil

    // Occurrences are identified by (assignment, instant) within a calendar window.
    var id: String { "\(assignmentId)@\(occursAt)" }

    /// The server's identity key for this occurrence (falls back to occursAt's date portion
    /// for responses from servers predating the `occurrence_date` field).
    var dateKey: String { occurrenceDate ?? String(occursAt.prefix(10)) }

    var isRescheduled: Bool { rescheduled ?? false }

    /// "Day 2 of 5" for a multi-day event, else nil.
    var spanLabel: String? {
        guard let i = dayIndex, let n = dayCount, n > 1 else { return nil }
        return "Day \(i) of \(n)"
    }

    func withStatus(_ status: String) -> Occurrence {
        Occurrence(assignmentId: assignmentId, title: title, occursAt: occursAt, status: status,
                   assigneeId: assigneeId, scheduleKind: scheduleKind, hidden: hidden,
                   dayIndex: dayIndex, dayCount: dayCount,
                   occurrenceDate: occurrenceDate, rescheduled: rescheduled)
    }
}

/// A logged fact — "X did Y at time T". The backward-looking counterpart to an
/// Assignment (the plan). `actorName`/`actorSlug` are denormalized by the server.
struct Activity: Codable, Equatable, Identifiable {
    let id: Int
    let accountId: Int
    let actorId: Int?
    let actorSlug: String?
    let actorName: String?
    let title: String
    let details: String?
    let category: String?
    let occurredAt: String
    let durationMinutes: Int?
    let goalId: Int?
    let assignmentId: Int?
    let occurrenceDate: String?
    let source: String              // manual | mcp | assignment_completion
    let hidden: Bool?
    let createdAt: String
    let updatedAt: String

    /// A completion auto-logged from marking a plan done (vs a spontaneous log).
    var isCompletion: Bool { source == "assignment_completion" }
}

/// One audit bucket from the activity summary: a count (+ total minutes) for an
/// actor and/or category.
struct ActivitySummaryRow: Codable, Equatable, Identifiable {
    let actorId: Int?
    let actorSlug: String?
    let actorName: String?
    let category: String?
    let count: Int
    let totalMinutes: Int

    var id: String { "\(actorSlug ?? "all")-\(category ?? "all")" }
}

// MARK: - Envelopes

struct Page<Item: Codable & Equatable>: Codable, Equatable {
    let items: [Item]
    let nextCursor: String?
}

struct AccessTokenResponse: Codable, Equatable {
    let accessToken: String
}

struct CalendarSubscription: Codable, Equatable {
    let enabled: String
    let url: String?
}

struct UpsertDelegateeResult: Codable, Equatable {
    let delegatee: Delegatee
    let created: Bool
}

struct AssignResult: Codable, Equatable {
    let assignment: Assignment
    let leadTimeWarning: String?
}

struct McpPermissionsResponse: Codable, Equatable {
    let mcpPermissions: [String: [String: Bool]]
}

/// Proactive-briefing preferences. Server-owned and OFF by default — nobody gets an
/// unsolicited push because a release shipped.
struct BriefingPrefs: Codable, Equatable {
    var enabled: Bool = false
    /// "daily" | "weekdays"
    var cadence: String = "daily"
    /// Hour of the day in the USER'S timezone, 0-23. The server interprets it locally, so
    /// 8 means their morning rather than 08:00 UTC.
    var hourLocal: Int = 8
    /// Per-content switches: due_today, overdue, blocked, unprocessed_notes.
    var kinds: [String: Bool] = [:]

    static let kindOrder = ["due_today", "overdue", "blocked", "unprocessed_notes"]

    static func label(for kind: String) -> String {
        switch kind {
        case "due_today":         return "On today"
        case "overdue":           return "Overdue"
        case "blocked":           return "Blocked"
        case "unprocessed_notes": return "Notes to triage"
        default:                  return kind
        }
    }
}

struct BriefingSettingsResponse: Codable, Equatable {
    let briefings: BriefingPrefs
}

/// A partial update — omitted fields keep their server-side value.
struct BriefingPrefsPatch: Codable, Equatable {
    var enabled: Bool? = nil
    var cadence: String? = nil
    var hourLocal: Int? = nil
    var kinds: [String: Bool]? = nil
}

/// For POSTs whose body carries nothing — the encoder still needs a value.
struct EmptyBody: Codable, Equatable {}

// MARK: - Agent

struct AgentThread: Codable, Equatable, Identifiable {
    let id: Int
    let accountId: Int
    let title: String?
    let createdAt: String
    let updatedAt: String

    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return "New chat"
    }
}

struct AgentMessage: Codable, Equatable, Identifiable {
    let id: Int
    let threadId: Int
    let accountId: Int
    let role: String              // user | assistant
    let content: String
    let model: String?
    let costUsd: Double?
    let createdAt: String
}

struct AgentThreadDetail: Codable, Equatable {
    let thread: AgentThread
    let messages: [AgentMessage]
}

struct AgentUsage: Codable, Equatable {
    let period: String
    let costUsd: Double
    let capUsd: Double            // governing total: the per-period budget when credits govern, else the flat cap
    let remainingUsd: Double      // governing remaining (real backend USD)
    let runs: Int
    let inputTokens: Int
    let outputTokens: Int
    // Optional (older servers omit them): the USD-budget monetization state.
    var creditsEnabled: Bool? = nil
    var budgetGoverned: Bool? = nil   // true ⇒ show the credit figure (remaining × multiplier) with a $

    /// Credits are a display multiple of the real backend USD budget: the user sees
    /// `real_usd × creditMultiplier` with a `$` (decision 2026-07-06). Backend is always USD.
    static let creditMultiplier: Double = 3

    /// The dollar figure to show the user. A budget-governed subscriber sees credits
    /// (remaining × 3); dev / comp / flat-cap accounts see the raw remaining dollars.
    var displayRemaining: Double {
        remainingUsd * ((budgetGoverned == true) ? Self.creditMultiplier : 1)
    }
}

/// The server's view of an account's access to the assistant. The app reads this
/// to decide whether to show the AI-disclosure consent gate and/or the paywall.
/// `requiresSubscription` mirrors the server flag (ships OFF), so the paywall stays
/// dormant until billing goes live, while `consentGiven` gates first use regardless.
struct AgentEntitlement: Codable, Equatable {
    let active: Bool                  // entitled to use the assistant right now
    let requiresSubscription: Bool    // whether the server is gating on a subscription
    let productId: String
    let priceDisplay: String          // e.g. "$19.99/mo" — server-driven paywall copy
    let trialDays: Int
    let consentGiven: Bool            // AI-disclosure consent recorded
    let status: String                // none | active | grace | expired | comp
    let periodType: String?           // trial | normal | intro | …
    let expiresAt: String?
    let willRenew: Bool
    // Optional (older servers omit them): the USD-budget monetization state. The client
    // shows `budgetUsdRemaining × AgentUsage.creditMultiplier` with a `$` when live.
    var creditsEnabled: Bool? = nil
    var budgetUsdRemaining: Double? = nil
    /// RevenueCat app_user_id for this account, unique across self-hosted servers
    /// ("<instance>:<account>"). Older servers omit it; the client then falls back to the
    /// bare account id they used to key on.
    var billingUserId: String? = nil
}

/// A compact reference to an entity a write tool just touched, carried on `tool_done`
/// so a completed tool chip can deep-link into that entity's detail. Back-compat: the
/// whole field is optional, so a pre-entity server simply omits it.
struct AgentEntityRef: Decodable, Equatable, Hashable {
    let kind: String              // assignment | note | goal | person
    let id: Int
    let label: String
}

/// One Server-Sent Event from `POST /api/agent/chat`. Heterogeneous by `type`;
/// only the fields relevant to that event are present (the rest decode to nil).
struct AgentEvent: Decodable {
    let type: String              // thread | start | tool | tool_done | text | done | error
    var threadId: Int?
    var userMessageId: Int?       // persisted id of the user turn just sent (thread)
    var model: String?
    var name: String?             // tool name (tool / tool_done)
    var args: [String: JSONValue]?  // tool-call arguments (tool) — e.g. {"title":"Make saffron milk"}
    var entity: AgentEntityRef?     // touched entity (tool_done) — for a tappable, deep-linkable chip
    var delta: String?            // assistant text delta (text)
    var output: String?           // final assistant text (done)
    var costUsd: Double?
    var remainingUsd: Double?
    var searches: Int?
    var error: String?
    var code: String?             // e.g. "cap_reached"
}

// MARK: - Peers

/// A connected A2A peer — another app's AI agent this assistant can talk to.
// The client decoder converts snake_case globally — no explicit CodingKeys here
// (they'd receive already-converted keys and fail with keyNotFound).
struct Peer: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let cardUrl: String
    let url: String
    let card: PeerCard
    let cardFetchedAt: String
    let hasToken: Bool
    let enabled: Bool
}

/// The subset of an A2A agent card the UI shows. Unknown keys ignored.
struct PeerCard: Codable, Hashable {
    let name: String
    let description: String?
    let version: String?
}

/// Where other apps reach this account's agent card and A2A endpoint.
struct PeerInboundInfo: Codable {
    let cardUrl: String
    let a2aUrl: String
}
