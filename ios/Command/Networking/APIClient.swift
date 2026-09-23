//
//  APIClient.swift
//  Command
//
//  The one client for the Command server (REST). Auth is the server's httpOnly
//  `command_session` cookie, round-tripped via an HTTPCookieStorage we own
//  (deterministic in production and under test-injected URLProtocols). JSON uses
//  snake_case <-> camelCase conversion so Swift stays idiomatic. No secrets logged.
//

import Foundation

enum APIError: LocalizedError, Equatable {
    case http(status: Int, code: String?, message: String?)
    case notHTTP

    var errorDescription: String? {
        switch self {
        case .http(let status, _, let message): return message ?? "Request failed (HTTP \(status))."
        case .notHTTP: return "Unexpected non-HTTP response."
        }
    }

    /// True when the server says we're unauthenticated.
    var isUnauthorized: Bool {
        if case .http(let status, _, _) = self { return status == 401 }
        return false
    }
}

final class APIClient {
    let baseURL: URL
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage?

    /// Fired (off the main actor) when the server rejects our session with 401 on an
    /// *authenticated* request — the session cookie expired or was revoked mid-use.
    /// NOT fired for login/register/invite credential checks, whose 401 is an auth error
    /// the auth screen surfaces locally. AppState installs this to drop cleanly back
    /// to the sign-in screen instead of leaving every action failing with a generic error.
    var onUnauthorized: (@Sendable () -> Void)?

    /// Decide whether a failed response means "this session is dead" — the one signal that
    /// throws the operator back to the sign-in screen.
    ///
    /// Requires the server's own `auth_failed` envelope, not just the 401 status. A 401 can
    /// also come from something between us and the server (an edge/WAF challenge, a captive
    /// portal, a proxy), and treating those as session death signs the operator out of a
    /// session that is perfectly valid — the most annoying possible false positive. Without
    /// the envelope we surface the error and keep the session; the next successful request
    /// costs nothing, a spurious logout costs a password.
    static func isSessionExpiry(status: Int, code: String?, path: String) -> Bool {
        guard status == 401, code == "auth_failed" else { return false }
        // These endpoints 401 to reject *credentials*, not a session; the auth screen shows
        // that locally and there is no session to tear down.
        return !path.hasSuffix("/auth/login") && !path.hasSuffix("/auth/register")
            && !path.hasSuffix("/auth/invite")
    }

    private func flagUnauthorized(status: Int, code: String?, url: URL?) {
        guard Self.isSessionExpiry(status: status, code: code, path: url?.path ?? "") else { return }
        onUnauthorized?()
    }

    /// Drain every page of a cursor-paginated list into one array. The list endpoints are cursor-
    /// paginated but the stores previously read only the first page, so once a user's notes/tasks/
    /// people/log exceeded the page size the older items were silently invisible in-app. Personal-
    /// scale data (hundreds of items), so loading all pages up front keeps the stores simple.
    ///
    /// Two different things could otherwise make this loop forever, and they want different guards:
    ///
    /// * **A cursor that doesn't advance** — a server bug handing back the same cursor. That is the
    ///   real hazard, and it is detectable directly, so it stops on the second sighting. The page
    ///   count used to be the only guard, which meant spending 50 *identical* requests before
    ///   giving up on a cursor that was never going to move.
    /// * **Genuinely more data than we intend to hold in memory** — `maxDrainPages` is the backstop
    ///   for that, and it is a real ceiling: past `maxDrainPages * pageSize` items the tail is not
    ///   loaded. At 10,000 that is far beyond the personal scale this app is built for, but it is a
    ///   limit rather than "everything", and paging the UI is the fix if it is ever approached.
    static let maxDrainPages = 50

    func drainAll<Item>(pageSize: Int = 200,
                        _ fetch: (_ limit: Int, _ cursor: String?) async throws -> Page<Item>) async throws -> [Item] {
        var all: [Item] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var pages = 0
        repeat {
            let page = try await fetch(pageSize, cursor)
            all += page.items
            pages += 1
            guard let next = page.nextCursor else { return all }   // drained cleanly
            guard seenCursors.insert(next).inserted else { return all }  // cursor stopped advancing
            cursor = next
        } while pages < Self.maxDrainPages
        return all
    }

    init(baseURL: URL, configuration: URLSessionConfiguration = .default) {
        self.baseURL = baseURL
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        self.cookieStorage = configuration.httpCookieStorage
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Auth + account

    @discardableResult
    func register(username: String, password: String, displayName: String?) async throws -> Account {
        try await postJSON("/api/auth/register",
                           RegisterBody(username: username, password: password, displayName: displayName)).decoded()
    }

    @discardableResult
    func login(username: String, password: String) async throws -> Account {
        try await postJSON("/api/auth/login", LoginBody(username: username, password: password)).decoded()
    }

    @discardableResult
    func redeemInvite(token: String) async throws -> MyProfile {
        try await postJSON("/api/auth/invite", InviteBody(token: token)).decoded()
    }

    func logout() async throws { _ = try await postJSON("/api/auth/logout", Empty()) }

    /// Permanently delete the signed-in account and everything in it. Requires the password even
    /// though we hold a session: a borrowed phone should not be able to erase someone's plan.
    func deleteAccount(password: String) async throws {
        _ = try await postJSON("/api/account/delete", DeleteAccountBody(password: password))
    }

    /// Register this device's APNs token so the server can push reminders. `environment` is
    /// "sandbox" for DEBUG builds, "production" for TestFlight/App Store.
    func registerPush(token: String, environment: String) async throws {
        _ = try await postJSON("/api/push/register", PushRegisterBody(token: token, environment: environment))
    }

    func unregisterPush(token: String) async throws {
        _ = try await postJSON("/api/push/unregister", PushTokenBody(token: token))
    }

    /// Delegatee-session variants: the operator push surface 404s for invited sessions, so a
    /// delegatee device registers through /api/my (the server stamps it with the delegatee id
    /// and routes only that person's reminders to it).
    func registerMyPush(token: String, environment: String) async throws {
        _ = try await postJSON("/api/my/push/register", PushRegisterBody(token: token, environment: environment))
    }

    func unregisterMyPush(token: String) async throws {
        _ = try await postJSON("/api/my/push/unregister", PushTokenBody(token: token))
    }

    func me() async throws -> Account { try await get("/api/auth/me").decoded() }

    // MARK: Delegatee session — My Work

    func myProfile() async throws -> MyProfile { try await get("/api/my/profile").decoded() }

    func myAssignments() async throws -> [Assignment] {
        try await get("/api/my/assignments").decoded()
    }

    func myCalendar(start: String, end: String) async throws -> [Occurrence] {
        try await get("/api/my/calendar", query: [
            .init(name: "start", value: start), .init(name: "end", value: end),
        ]).decoded()
    }

    @discardableResult
    func setMyAssignmentStatus(id: Int, status: String) async throws -> Assignment {
        try await postJSON("/api/my/assignments/\(id)/status", StatusBody(status: status)).decoded()
    }

    @discardableResult
    func setMyOccurrenceStatus(id: Int, date: String, status: String) async throws -> OccurrenceStatusResult {
        try await postJSON("/api/my/assignments/\(id)/occurrences/\(date)/status",
                           StatusBody(status: status)).decoded()
    }

    /// Tell the server this device's IANA timezone so the agent resolves relative dates
    /// ("tomorrow at 9pm") correctly. Idempotent; called fire-and-forget on login/foreground.
    /// Pinned contract: `PUT /api/account/timezone`, body `{"timezone":"America/New_York"}`.
    func setTimezone(_ id: String) async throws {
        _ = try await putJSON("/api/account/timezone", TimezoneBody(timezone: id))
    }

    func accessToken() async throws -> String {
        try await get("/api/access-token").decoded(AccessTokenResponse.self).accessToken
    }

    func regenerateAccessToken() async throws -> String {
        try await postJSON("/api/access-token/regenerate", Empty()).decoded(AccessTokenResponse.self).accessToken
    }

    // MARK: Server

    /// Public server description (no auth). Older servers 404 — callers treat any failure as
    /// "unknown" and fall back to the pre-Cloud behaviour.
    func serverInfo() async throws -> ServerInfo { try await get("/api/server/info").decoded() }

    /// Store the assistant's model key on a self-hosted server. Owner only; the server validates
    /// it against the provider first and answers `invalid_key`, `not_owner` or `managed_by_env`
    /// with an actionable message otherwise. The key is never returned by any endpoint.
    func setServerAIKey(_ apiKey: String) async throws {
        _ = try await putJSON("/api/server/ai-key", AIKeyBody(apiKey: apiKey))
    }

    // MARK: Calendar export

    func calendarSubscription() async throws -> CalendarSubscription {
        try await get("/api/calendar/subscription").decoded()
    }

    // MARK: Notes

    func searchNotes(query: String? = nil, unprocessed: Bool? = nil, source: String? = nil,
                     includeArchived: Bool = false, limit: Int = 50, cursor: String? = nil) async throws -> Page<Note> {
        var q: [URLQueryItem] = [.init(name: "include_archived", value: String(includeArchived)),
                                 .init(name: "limit", value: String(limit))]
        if let query { q.append(.init(name: "query", value: query)) }
        if let unprocessed { q.append(.init(name: "unprocessed", value: String(unprocessed))) }
        if let source { q.append(.init(name: "source", value: source)) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await get("/api/notes", query: q).decoded()
    }

    @discardableResult
    func createNote(body: String, source: String = "typed", engine: String? = nil,
                    locale: String? = nil, title: String? = nil, hidden: Bool = false) async throws -> Note {
        try await postJSON("/api/notes",
                           NoteCreateBody(body: body, source: source, engine: engine, locale: locale, title: title, hidden: hidden)).decoded()
    }

    func getNote(id: Int) async throws -> Note {
        try await get("/api/notes/\(id)").decoded()
    }

    /// Patch title and/or body. Omitted (nil) fields are left unchanged server-side;
    /// an explicit title is marked user-set (never auto-overwritten).
    @discardableResult
    func updateNote(id: Int, title: String? = nil, body: String? = nil) async throws -> Note {
        try await patchJSON("/api/notes/\(id)", NoteUpdateBody(title: title, body: body)).decoded()
    }

    /// The user closed the note: snapshot a backup (if changed) and kick off an AI
    /// title in the background. The returned note may carry `titleStatus == "generating"`.
    @discardableResult
    func closeNote(id: Int) async throws -> Note {
        try await post("/api/notes/\(id)/close").decoded()
    }

    func noteRevisions(id: Int) async throws -> [NoteRevision] {
        try await get("/api/notes/\(id)/revisions").decoded()
    }

    @discardableResult
    func restoreNoteRevision(noteId: Int, revisionId: Int) async throws -> Note {
        try await post("/api/notes/\(noteId)/revisions/\(revisionId)/restore").decoded()
    }

    func archiveNote(id: Int, archived: Bool = true) async throws -> Note {
        try await post("/api/notes/\(id)/archive", query: [.init(name: "archived", value: String(archived))]).decoded()
    }

    func setNoteProcessed(id: Int, processed: Bool = true) async throws -> Note {
        try await post("/api/notes/\(id)/processed", query: [.init(name: "processed", value: String(processed))]).decoded()
    }

    /// Redact (hide) or unredact (reveal) a note — flips the invisible-ink veil. A note is
    /// never deleted, only veiled, so this is a safe, reversible edit.
    @discardableResult
    func setNoteHidden(id: Int, hidden: Bool) async throws -> Note {
        try await post("/api/notes/\(id)/hidden", query: [.init(name: "hidden", value: String(hidden))]).decoded()
    }

    // MARK: Delegatees

    func listDelegatees(activeOnly: Bool = false, includeSelf: Bool = false,
                        limit: Int = 100, cursor: String? = nil) async throws -> Page<Delegatee> {
        var q: [URLQueryItem] = [.init(name: "active_only", value: String(activeOnly)),
                                 .init(name: "include_self", value: String(includeSelf)),
                                 .init(name: "limit", value: String(limit))]
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await get("/api/delegatees", query: q).decoded()
    }

    func searchDelegatees(_ text: String, limit: Int = 20) async throws -> [Delegatee] {
        try await get("/api/delegatees/search", query: [.init(name: "q", value: text), .init(name: "limit", value: String(limit))]).decoded()
    }

    @discardableResult
    func upsertDelegatee(name: String, slug: String? = nil, kind: String = "human",
                         leadTimeMinutes: Int = 0, metadata: [String: JSONValue] = [:], active: Bool = true) async throws -> UpsertDelegateeResult {
        try await postJSON("/api/delegatees", DelegateeUpsertBody(
            name: name, slug: slug, kind: kind, leadTimeMinutes: leadTimeMinutes, metadata: metadata, active: active)).decoded()
    }

    @discardableResult
    func deleteDelegatee(id: Int) async throws -> Delegatee { try await delete("/api/delegatees/\(id)").decoded() }

    /// Creates or regenerates an invite. The raw token is returned only by this response.
    func createDelegateeInvite(id: Int) async throws -> String {
        try await post("/api/delegatees/\(id)/invite")
            .decoded(DelegateeInvite.self).inviteToken
    }

    func revokeDelegateeInvite(id: Int) async throws {
        _ = try await delete("/api/delegatees/\(id)/invite")
    }

    // MARK: Goals

    func listGoals(status: String? = nil, limit: Int = 100, cursor: String? = nil) async throws -> Page<Goal> {
        var q: [URLQueryItem] = [.init(name: "limit", value: String(limit))]
        if let status { q.append(.init(name: "status", value: status)) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await get("/api/goals", query: q).decoded()
    }

    @discardableResult
    func createGoal(title: String, description: String? = nil, status: String = "open", targetDate: String? = nil) async throws -> Goal {
        try await postJSON("/api/goals", GoalCreateBody(title: title, description: description, status: status, targetDate: targetDate)).decoded()
    }

    @discardableResult
    func deleteGoal(id: Int) async throws -> Goal { try await delete("/api/goals/\(id)").decoded() }

    // MARK: Assignments

    func listAssignments(status: String? = nil, assigneeId: Int? = nil, scheduleKind: String? = nil,
                         archived: Bool = false, limit: Int = 100, cursor: String? = nil) async throws -> Page<Assignment> {
        var q: [URLQueryItem] = [.init(name: "limit", value: String(limit))]
        if archived { q.append(.init(name: "archived", value: "true")) }   // archived-ONLY view
        if let status { q.append(.init(name: "status", value: status)) }
        if let assigneeId { q.append(.init(name: "assignee_id", value: String(assigneeId))) }
        if let scheduleKind { q.append(.init(name: "schedule_kind", value: scheduleKind)) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await get("/api/assignments", query: q).decoded()
    }

    func calendar(start: String, end: String) async throws -> [Occurrence] {
        try await get("/api/assignments/calendar", query: [.init(name: "start", value: start), .init(name: "end", value: end)]).decoded()
    }

    /// Fetch a single assignment by id — used to open an assignment from a calendar occurrence,
    /// which carries only the assignmentId, and to re-read authoritative notes on the detail page.
    func assignment(id: Int) async throws -> Assignment {
        try await get("/api/assignments/\(id)").decoded()
    }

    /// Fetch a single goal by id — the detail page re-reads its authoritative notes on open.
    func goal(id: Int) async throws -> Goal {
        try await get("/api/goals/\(id)").decoded()
    }

    /// Fetch a single logged activity by id — the detail page re-reads its authoritative details on open.
    func activity(id: Int) async throws -> Activity {
        try await get("/api/activities/\(id)").decoded()
    }

    /// Set the status of ONE occurrence of a (usually recurring) assignment. `occurrenceDate` must
    /// be the server's expansion date key — `Occurrence.dateKey` (the ORIGINAL series date, which
    /// a rescheduled occurrence keeps). Marking `done` server-side also logs a completion fact.
    func setOccurrenceStatus(assignmentId: Int, occurrenceDate: String, status: String, note: String? = nil) async throws {
        _ = try await postJSON("/api/assignments/\(assignmentId)/occurrences/\(occurrenceDate)/status",
                               OccurrenceStatusBody(status: status, note: note))
    }

    /// Move ONE occurrence of a routine assignment to a new instant (the series is untouched).
    /// `occurrenceDate` is `Occurrence.dateKey`; `occursAt` an ISO-8601 instant with offset.
    func rescheduleOccurrence(assignmentId: Int, occurrenceDate: String, occursAt: String) async throws {
        _ = try await postJSON("/api/assignments/\(assignmentId)/occurrences/\(occurrenceDate)/reschedule",
                               OccurrenceRescheduleBody(occursAt: occursAt))
    }

    /// Reset a rescheduled occurrence back to its series time.
    func resetOccurrence(assignmentId: Int, occurrenceDate: String) async throws {
        _ = try await delete("/api/assignments/\(assignmentId)/occurrences/\(occurrenceDate)/reschedule")
    }

    // MARK: - Attachments

    func listAttachments(entityKind: String, entityId: Int) async throws -> [Attachment] {
        try await get("/api/attachments", query: [.init(name: "entity_kind", value: entityKind),
                                                  .init(name: "entity_id", value: String(entityId))]).decoded()
    }

    /// Upload one file as multipart/form-data. Caller supplies the bytes (already read from the
    /// picker) plus the original filename and MIME type.
    func uploadAttachment(entityKind: String, entityId: Int,
                          filename: String, mime: String, data: Data) async throws -> Attachment {
        let boundary = "command-\(UUID().uuidString)"
        var req = URLRequest(url: makeURL("/api/attachments", query: []))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("entity_kind", entityKind)
        field("entity_id", String(entityId))
        // Strip quote/newline from the filename so it can't break the multipart header.
        let safeName = filename.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        return try await send(req).decoded()
    }

    /// Fetch an attachment's bytes (for thumbnail/QuickLook). Delegatee mode reads via /api/my.
    func downloadAttachment(id: Int, delegatee: Bool = false) async throws -> Data {
        try await get(delegatee ? "/api/my/attachments/\(id)/download"
                                : "/api/attachments/\(id)/download")
    }

    func deleteAttachment(id: Int) async throws {
        _ = try await delete("/api/attachments/\(id)")
    }

    /// Read-only delegatee surface: attachments on one of MY assignments.
    func myAssignmentAttachments(assignmentId: Int) async throws -> [Attachment] {
        try await get("/api/my/assignments/\(assignmentId)/attachments").decoded()
    }

    @discardableResult
    func createAssignment(_ body: AssignmentCreateBody) async throws -> Assignment {
        try await postJSON("/api/assignments", body).decoded()
    }

    @discardableResult
    func assign(assignmentId: Int, assigneeSlug: String? = nil, assigneeId: Int? = nil) async throws -> AssignResult {
        try await postJSON("/api/assignments/\(assignmentId)/assign", AssignBody(assigneeId: assigneeId, assigneeSlug: assigneeSlug)).decoded()
    }

    @discardableResult
    func setAssignmentStatus(id: Int, status: String) async throws -> Assignment {
        try await postJSON("/api/assignments/\(id)/status", StatusBody(status: status)).decoded()
    }

    @discardableResult
    func deleteAssignment(id: Int) async throws -> Assignment { try await delete("/api/assignments/\(id)").decoded() }

    /// Archive (or restore) an assignment — it leaves/rejoins the calendar, lists, and reminders.
    func archiveAssignment(id: Int, archived: Bool = true) async throws -> Assignment {
        try await post("/api/assignments/\(id)/\(archived ? "archive" : "unarchive")").decoded()
    }

    /// Redact (hide) or unredact (reveal) an assignment — flips the invisible-ink veil.
    @discardableResult
    func setAssignmentHidden(id: Int, hidden: Bool) async throws -> Assignment {
        try await patchJSON("/api/assignments/\(id)", HiddenPatchBody(hidden: hidden)).decoded()
    }

    // MARK: Detail pages — persistent notes + checklist items

    @discardableResult
    func updateAssignmentNotes(id: Int, notes: String) async throws -> Assignment {
        try await patchJSON("/api/assignments/\(id)", NotesBody(notes: notes)).decoded()
    }

    @discardableResult
    func updateGoalNotes(id: Int, notes: String) async throws -> Goal {
        try await patchJSON("/api/goals/\(id)", NotesBody(notes: notes)).decoded()
    }

    @discardableResult
    func updateAssignmentTitle(id: Int, title: String) async throws -> Assignment {
        try await patchJSON("/api/assignments/\(id)", TitleBody(title: title)).decoded()
    }

    /// Move a SPORADIC assignment to a new instant (calendar drag). Routine assignments move
    /// per-occurrence via `rescheduleOccurrence` instead — their series time is deliberate.
    /// `scheduledEnd` (nil = leave unchanged) moves a one-off's end along with its start, so a
    /// dragged event keeps its duration instead of ending before it begins.
    @discardableResult
    func updateAssignmentSchedule(id: Int, scheduledStart: String, scheduledEnd: String? = nil) async throws -> Assignment {
        try await patchJSON("/api/assignments/\(id)",
                            SchedulePatchBody(scheduledStart: scheduledStart, scheduledEnd: scheduledEnd)).decoded()
    }

    /// Link an assignment to a goal, or pass nil to unlink it. The server reads an omitted field as
    /// "unchanged" and an explicit null as "clear", so the body writes `goal_id` either way.
    @discardableResult
    func setAssignmentGoal(id: Int, goalId: Int?) async throws -> Assignment {
        try await patchJSON("/api/assignments/\(id)", GoalLinkBody(goalId: goalId)).decoded()
    }

    /// Set how far ahead of an occurrence the assignee is reminded, or pass nil to fall back to the
    /// assignee's own notice window.
    @discardableResult
    func setAssignmentLeadTime(id: Int, minutes: Int?) async throws -> Assignment {
        try await patchJSON("/api/assignments/\(id)", LeadTimeBody(leadTimeMinutes: minutes)).decoded()
    }

    /// Take the assignee off an assignment. Use `assign(...)` to give work to someone — it also
    /// defaults the lead time and returns the lead-time warning; it requires a delegatee, so this
    /// is the only way to unassign.
    @discardableResult
    func unassign(assignmentId: Int) async throws -> Assignment {
        try await patchJSON("/api/assignments/\(assignmentId)", AssigneeBody(assigneeId: nil)).decoded()
    }

    @discardableResult
    func updateGoalTitle(id: Int, title: String) async throws -> Goal {
        try await patchJSON("/api/goals/\(id)", TitleBody(title: title)).decoded()
    }

    @discardableResult
    func updateGoalStatus(id: Int, status: String) async throws -> Goal {
        try await patchJSON("/api/goals/\(id)", StatusBody(status: status)).decoded()
    }

    func listItems(parentType: String, parentId: Int) async throws -> [TaskItem] {
        try await get("/api/items", query: [
            .init(name: "parent_type", value: parentType),
            .init(name: "parent_id", value: String(parentId)),
        ]).decoded()
    }

    @discardableResult
    func addItem(parentType: String, parentId: Int, text: String) async throws -> TaskItem {
        try await postJSON("/api/items", ItemCreateBody(parentType: parentType, parentId: parentId, text: text)).decoded()
    }

    @discardableResult
    func updateItem(id: Int, text: String? = nil, done: Bool? = nil) async throws -> TaskItem {
        try await patchJSON("/api/items/\(id)", ItemUpdateBody(text: text, done: done)).decoded()
    }

    func deleteItem(id: Int) async throws { _ = try await delete("/api/items/\(id)") }

    @discardableResult
    func reorderItems(parentType: String, parentId: Int, orderedIds: [Int]) async throws -> [TaskItem] {
        try await postJSON("/api/items/reorder",
                           ReorderBody(parentType: parentType, parentId: parentId, orderedIds: orderedIds)).decoded()
    }

    // MARK: Activities

    func listActivities(query: String? = nil, actorId: Int? = nil, category: String? = nil,
                        goalId: Int? = nil, assignmentId: Int? = nil, source: String? = nil,
                        start: String? = nil, end: String? = nil,
                        limit: Int = 100, cursor: String? = nil) async throws -> Page<Activity> {
        var q: [URLQueryItem] = [.init(name: "limit", value: String(limit))]
        if let query { q.append(.init(name: "query", value: query)) }
        if let actorId { q.append(.init(name: "actor_id", value: String(actorId))) }
        if let category { q.append(.init(name: "category", value: category)) }
        if let goalId { q.append(.init(name: "goal_id", value: String(goalId))) }
        if let assignmentId { q.append(.init(name: "assignment_id", value: String(assignmentId))) }
        if let source { q.append(.init(name: "source", value: source)) }
        if let start { q.append(.init(name: "start", value: start)) }
        if let end { q.append(.init(name: "end", value: end)) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await get("/api/activities", query: q).decoded()
    }

    @discardableResult
    func createActivity(_ body: ActivityCreateBody) async throws -> Activity {
        try await postJSON("/api/activities", body).decoded()
    }

    @discardableResult
    func updateActivity(id: Int, _ body: ActivityUpdateBody) async throws -> Activity {
        try await patchJSON("/api/activities/\(id)", body).decoded()
    }

    @discardableResult
    func deleteActivity(id: Int) async throws -> Activity { try await delete("/api/activities/\(id)").decoded() }

    /// Redact (hide) or unredact (reveal) a logged fact — flips the invisible-ink veil.
    @discardableResult
    func setActivityHidden(id: Int, hidden: Bool) async throws -> Activity {
        try await patchJSON("/api/activities/\(id)", HiddenPatchBody(hidden: hidden)).decoded()
    }

    func activitySummary(start: String? = nil, end: String? = nil, actorId: Int? = nil,
                         groupBy: [String]? = nil) async throws -> [ActivitySummaryRow] {
        var q: [URLQueryItem] = []
        if let start { q.append(.init(name: "start", value: start)) }
        if let end { q.append(.init(name: "end", value: end)) }
        if let actorId { q.append(.init(name: "actor_id", value: String(actorId))) }
        for g in groupBy ?? [] { q.append(.init(name: "group_by", value: g)) }
        return try await get("/api/activities/summary", query: q).decoded()
    }

    // MARK: Settings

    func mcpPermissions() async throws -> [String: [String: Bool]] {
        try await get("/api/settings").decoded(McpPermissionsResponse.self).mcpPermissions
    }

    func briefingPrefs() async throws -> BriefingPrefs {
        try await get("/api/settings").decoded(BriefingSettingsResponse.self).briefings
    }

    @discardableResult
    func updateBriefingPrefs(_ patch: BriefingPrefsPatch) async throws -> BriefingPrefs {
        try await putJSON("/api/settings/briefings", patch).decoded()
    }

    /// Tell the server the app came to the foreground.
    ///
    /// This is what refunds the proactive-LLM send budget — without it a user who keeps using
    /// the app would still be throttled to the churn cap. Deliberately fire-and-forget: it
    /// must never block a launch or surface an error, and the next foreground retries it.
    func appOpened() async {
        _ = try? await postJSON("/api/app/opened", EmptyBody())
    }

    // MARK: Agent

    func agentThreads(limit: Int = 50, cursor: String? = nil) async throws -> Page<AgentThread> {
        var q: [URLQueryItem] = [.init(name: "limit", value: String(limit))]
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await get("/api/agent/threads", query: q).decoded()
    }

    func agentThread(id: Int) async throws -> AgentThreadDetail {
        try await get("/api/agent/threads/\(id)").decoded()
    }

    /// Delete a thread's messages from `fromMessageId` onward (inclusive) — "Edit & resend" and
    /// "Regenerate" replace a turn, so the server's history must lose it too.
    func truncateAgentThread(id: Int, fromMessageId: Int) async throws {
        _ = try await postJSON("/api/agent/threads/\(id)/truncate", TruncateBody(fromMessageId: fromMessageId))
    }

    func agentUsage() async throws -> AgentUsage {
        try await get("/api/agent/usage").decoded()
    }

    /// The model tiers this server offers and the model each runs.
    func agentModels() async throws -> [AgentModelTier] {
        struct Response: Decodable { let tiers: [AgentModelTier] }
        let response: Response = try await get("/api/agent/models").decoded()
        return response.tiers
    }

    /// The account's assistant entitlement — drives the consent gate + paywall.
    func agentEntitlement() async throws -> AgentEntitlement {
        try await get("/api/agent/entitlement").decoded()
    }

    /// Record AI-disclosure consent (idempotent). Returns the refreshed entitlement.
    @discardableResult
    func agentConsent() async throws -> AgentEntitlement {
        try await post("/api/agent/consent").decoded()
    }

    /// Stream an agent run as Server-Sent Events. Yields `AgentEvent`s until the
    /// terminal `done` (or `error`); cancelling the consuming Task cancels the
    /// request. `threadId == nil` starts a new thread (the first `thread` event
    /// reports its id).
    func streamAgentChat(message: String, threadId: Int?, model: String? = nil, allowHidden: Bool = false, images: [ChatImage] = []) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: makeURL("/api/agent/chat", query: []))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // The 60s default is an IDLE timeout, and a turn that thinks, searches and
                    // calls tools can be silent longer than that — the client gave up while the
                    // server finished (and billed) the run. The server now sends an SSE comment
                    // every ~15s during a run; this allows for a few missed ones on a bad link.
                    req.timeoutInterval = 180
                    req.httpBody = try Self.encoder.encode(AgentChatBody(message: message, threadId: threadId, model: model, allowHidden: allowHidden, images: images))
                    attachCookies(to: &req)
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
                    storeCookies(from: http, for: req.url!)
                    guard (200..<300).contains(http.statusCode) else {
                        // Drain the (small) error envelope rather than discarding it: the code is
                        // what distinguishes a dead session from an edge 401, and the message is
                        // the only thing the chat can show the operator beyond "HTTP 401".
                        let parsed = try? Self.decoder.decode(
                            ServerError.self, from: await Self.errorBody(from: bytes)
                        )
                        flagUnauthorized(status: http.statusCode, code: parsed?.error.code, url: req.url)
                        throw APIError.http(status: http.statusCode,
                                            code: parsed?.error.code, message: parsed?.error.message)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }   // SSE: ignore comments/blank lines
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, let data = payload.data(using: .utf8),
                              let event = try? Self.decoder.decode(AgentEvent.self, from: data) else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Peers

    func listPeers() async throws -> [Peer] { try await get("/api/peers").decoded() }

    func addPeer(cardURL: String, token: String?) async throws -> Peer {
        struct Body: Encodable { let card_url: String; let token: String? }
        return try await postJSON("/api/peers", Body(card_url: cardURL, token: token)).decoded()
    }

    /// Replace or clear a peer's bearer token. Pass `nil` to remove the saved token.
    @discardableResult
    func setPeerToken(name: String, token: String?) async throws -> Peer {
        try await patchJSON("/api/peers/\(name)", PeerTokenBody(token: token)).decoded()
    }

    @discardableResult
    func setPeerEnabled(name: String, enabled: Bool) async throws -> Peer {
        try await patchJSON("/api/peers/\(name)", PeerEnabledBody(enabled: enabled)).decoded()
    }

    func deletePeer(name: String) async throws { _ = try await delete("/api/peers/\(name)") }

    @discardableResult
    func refreshPeer(name: String) async throws -> Peer {
        try await postJSON("/api/peers/\(name)/refresh", Empty()).decoded()
    }

    func peerInboundInfo() async throws -> PeerInboundInfo { try await get("/api/peers/inbound-info").decoded() }

    // MARK: - Request bodies

    private struct Empty: Encodable {}
    private struct PushRegisterBody: Encodable { let token: String; let environment: String }
    private struct PushTokenBody: Encodable { let token: String }
    private struct RegisterBody: Encodable { let username: String; let password: String; let displayName: String? }
    private struct TimezoneBody: Encodable { let timezone: String }
    private struct AIKeyBody: Encodable { let apiKey: String }
    private struct LoginBody: Encodable { let username: String; let password: String }
    private struct InviteBody: Encodable { let token: String }
    private struct NoteCreateBody: Encodable { let body: String; let source: String; let engine: String?; let locale: String?; let title: String?; let hidden: Bool }
    private struct NoteUpdateBody: Encodable { let title: String?; let body: String? }
    private struct DelegateeUpsertBody: Encodable {
        let name: String; let slug: String?; let kind: String
        let leadTimeMinutes: Int; let metadata: [String: JSONValue]; let active: Bool
    }
    private struct GoalCreateBody: Encodable { let title: String; let description: String?; let status: String; let targetDate: String? }
    private struct AssignBody: Encodable { let assigneeId: Int?; let assigneeSlug: String? }
    private struct StatusBody: Encodable { let status: String }
    private struct TruncateBody: Encodable { let fromMessageId: Int }
    private struct OccurrenceStatusBody: Encodable { let status: String; let note: String? }
    private struct OccurrenceRescheduleBody: Encodable { let occursAt: String }
    /// A nil `scheduledEnd` is OMITTED (synthesized Encodable uses encodeIfPresent), which the
    /// server reads as "unchanged" — never as a clear.
    private struct SchedulePatchBody: Encodable { let scheduledStart: String; let scheduledEnd: String? }
    private struct TitleBody: Encodable { let title: String }
    private struct DeleteAccountBody: Encodable { let password: String }
    /// PATCH bodies for the two nullable fields the app can turn *off*. These encode the key even
    /// when the value is nil (`encode`, not the synthesized `encodeIfPresent`): the server reads an
    /// omitted key as "leave unchanged" and an explicit null as "clear", and Swift's synthesized
    /// Codable drops nil Optionals entirely — which would make "unlink" / "reset" unsendable.
    private struct GoalLinkBody: Encodable {
        let goalId: Int?
        enum CodingKeys: String, CodingKey { case goalId }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(goalId, forKey: .goalId)
        }
    }
    private struct LeadTimeBody: Encodable {
        let leadTimeMinutes: Int?
        enum CodingKeys: String, CodingKey { case leadTimeMinutes }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(leadTimeMinutes, forKey: .leadTimeMinutes)
        }
    }
    private struct AssigneeBody: Encodable {
        let assigneeId: Int?
        enum CodingKeys: String, CodingKey { case assigneeId }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(assigneeId, forKey: .assigneeId)
        }
    }
    /// One image attachment for a chat turn: a media type plus base64-encoded bytes,
    /// sent inline in the chat body and forwarded natively to a vision-capable model.
    struct ChatImage: Encodable, Equatable, Sendable { let mediaType: String; let data: String }
    private struct AgentChatBody: Encodable {
        let message: String; let threadId: Int?; let model: String?; let allowHidden: Bool
        let images: [ChatImage]
    }
    /// Peer token PATCH body. Encodes the key even when nil because the server reads an omitted key
    /// as "unchanged" and an explicit null as "clear".
    private struct PeerTokenBody: Encodable {
        let token: String?
        enum CodingKeys: String, CodingKey { case token }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(token, forKey: .token)
        }
    }
    private struct PeerEnabledBody: Encodable { let enabled: Bool }
    private struct ServerError: Decodable { struct Inner: Decodable { let code: String; let message: String; let hint: String? }; let error: Inner }

    // MARK: - Plumbing

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()

    private func makeURL(_ path: String, query: [URLQueryItem]) -> URL {
        Self.requestURL(base: baseURL, path: path, query: query)
    }

    /// `base` + an absolute API `path` ("/api/notes"), keeping any path the base carries.
    ///
    /// A server published under a prefix (`https://host/command`) must get
    /// `https://host/command/api/notes`. `URL(string:relativeTo:)` resolves a leading-slash
    /// path against the HOST and silently drops the prefix — while the onboarding probe, which
    /// appends a component, kept it. So setup said "Server found" and every real call 404'd.
    static func requestURL(base: URL, path: String, query: [URLQueryItem]) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: true)!
        let prefix = comps.percentEncodedPath.hasSuffix("/")
            ? String(comps.percentEncodedPath.dropLast()) : comps.percentEncodedPath
        // Encode the API path here: a peer named "home lab" used to make `URL(string:)` nil
        // and crash on the force-unwrap. No caller passes a pre-encoded path.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        comps.percentEncodedPath = prefix + encoded
        comps.queryItems = nil
        comps.fragment = nil
        if !query.isEmpty {
            comps.queryItems = query
            // URLComponents leaves a literal '+' unescaped in query values, but many servers
            // (Starlette/WSGI form parsing) decode '+' as a space — so searching "C++" or "a+b"
            // would silently query the wrong string. '+' is never a structural delimiter here
            // (queryItems uses '&'/'='), so any '+' is value data: percent-encode it.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return comps.url!
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await send(URLRequest(url: makeURL(path, query: query)))
    }

    private func post(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var req = URLRequest(url: makeURL(path, query: query)); req.httpMethod = "POST"
        return try await send(req)
    }

    private func delete(_ path: String) async throws -> Data {
        var req = URLRequest(url: makeURL(path, query: [])); req.httpMethod = "DELETE"
        return try await send(req)
    }

    private func postJSON(_ path: String, _ body: some Encodable) async throws -> Data {
        var req = URLRequest(url: makeURL(path, query: []))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(body)
        return try await send(req)
    }

    private func patchJSON(_ path: String, _ body: some Encodable) async throws -> Data {
        var req = URLRequest(url: makeURL(path, query: []))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(body)
        return try await send(req)
    }

    private func putJSON(_ path: String, _ body: some Encodable) async throws -> Data {
        var req = URLRequest(url: makeURL(path, query: []))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(body)
        return try await send(req)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        attachCookies(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
        storeCookies(from: http, for: request.url!)
        guard (200..<300).contains(http.statusCode) else {
            let parsed = try? Self.decoder.decode(ServerError.self, from: data)
            flagUnauthorized(status: http.statusCode, code: parsed?.error.code, url: request.url)
            throw APIError.http(status: http.statusCode, code: parsed?.error.code, message: parsed?.error.message)
        }
        return data
    }

    /// Collect an error response body from a byte stream, capped so a misbehaving server
    /// can't stream unbounded data into memory on what should be a small JSON envelope.
    private static func errorBody(from bytes: URLSession.AsyncBytes, limit: Int = 64 * 1024) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // A truncated error body is still worth parsing; fall through with what we have.
        }
        return data
    }

    /// Drop the persisted session cookie. Call on sign-out, after any server-side revoke.
    ///
    /// Signing out cleared every in-app store but left the credential itself in the jar — and
    /// the jar is `HTTPCookieStorage.shared`, which `IntentAPI.makeClient()` builds its own
    /// client from. Since the server-side revoke is best-effort (`try? await client.logout()`,
    /// and signing out while offline is the ordinary case), the session could still be live:
    /// Siri and Shortcuts would go on capturing notes into the account the user just left.
    ///
    /// Only cookies scoped to `baseURL` are removed, so this never disturbs unrelated hosts
    /// sharing the process-wide jar.
    /// Whether a session cookie for this server is on the device at all. Without one there is
    /// no session to be "unable to confirm", so a failed launch check is plainly signed-out.
    func hasSessionCookie() -> Bool {
        !(cookieStorage?.cookies(for: baseURL) ?? []).isEmpty
    }

    func clearSessionCookies() {
        guard let storage = cookieStorage, let cookies = storage.cookies(for: baseURL) else { return }
        for cookie in cookies { storage.deleteCookie(cookie) }
    }

    private func storeCookies(from http: HTTPURLResponse, for url: URL) {
        guard let fields = http.allHeaderFields as? [String: String], let storage = cookieStorage else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return }
        storage.setCookies(cookies, for: url, mainDocumentURL: url)
    }

    private func attachCookies(to request: inout URLRequest) {
        guard let storage = cookieStorage, let url = request.url, let cookies = storage.cookies(for: url), !cookies.isEmpty else { return }
        for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
    }
}

/// Assignment create body — its own type because callers build it field-by-field.
struct AssignmentCreateBody: Encodable {
    var title: String
    var details: String? = nil
    var goalId: Int? = nil
    var assigneeId: Int? = nil
    var scheduleKind: String = "sporadic"
    var rrule: String? = nil
    var scheduledStart: String? = nil
    var scheduledEnd: String? = nil
    /// The device's IANA timezone (e.g. "America/New_York"). Sent so the server anchors recurrence
    /// expansion to local wall-clock — a "Daily 9 AM" stays 9 AM across a DST transition.
    var timezone: String? = nil
    var leadTimeMinutes: Int? = nil
    var status: String = "todo"
    var priority: Int = 0
    var hidden: Bool = false
}

/// Detail-page bodies: persistent notes + checklist items.
struct NotesBody: Encodable { var notes: String }
/// Redact/unredact PATCH body — flips only the invisible-ink veil, leaving all else untouched.
struct HiddenPatchBody: Encodable { var hidden: Bool }
struct ItemCreateBody: Encodable { var parentType: String; var parentId: Int; var text: String }
struct ItemUpdateBody: Encodable { var text: String? = nil; var done: Bool? = nil }
struct ReorderBody: Encodable { var parentType: String; var parentId: Int; var orderedIds: [Int] }

/// Activity log/create body. Nil optionals are omitted (synthesized `encodeIfPresent`),
/// so the server applies its defaults: actor → "Me", occurredAt → now.
struct ActivityCreateBody: Encodable {
    var title: String
    var actorId: Int? = nil
    var actorSlug: String? = nil
    var details: String? = nil
    var category: String? = nil
    var occurredAt: String? = nil
    var durationMinutes: Int? = nil
    var goalId: Int? = nil
    var assignmentId: Int? = nil
    var hidden: Bool = false
}

/// Activity update body. Omitted (nil) fields are left unchanged server-side.
struct ActivityUpdateBody: Encodable {
    var title: String? = nil
    var actorId: Int? = nil
    var actorSlug: String? = nil
    var details: String? = nil
    var category: String? = nil
    var occurredAt: String? = nil
    var durationMinutes: Int? = nil
    var goalId: Int? = nil
}

private extension Data {
    func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(T.self, from: self)
    }
}
