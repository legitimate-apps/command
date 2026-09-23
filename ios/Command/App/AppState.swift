//
//  AppState.swift
//  Command
//
//  The app-wide observable: the API client, the signed-in account, and the
//  configurable server URL. The session cookie lives in the shared
//  HTTPCookieStorage (persists across launches), so `bootstrap()` re-derives
//  sign-in state by calling /api/auth/me.
//

import Foundation
import Observation
import WidgetKit

/// How the invisible-ink veil over hidden captures behaves, app-wide. A local
/// presentation choice (not server data), chosen in the profile and persisted.
enum HiddenRevealMode: String, CaseIterable, Identifiable, Sendable {
    // Raw value kept as "swipeToReveal" so existing saved preferences still decode after
    // the user-facing rename to "Rub to reveal".
    case keepHidden, rubToReveal = "swipeToReveal", revealAll
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keepHidden:  return "Keep hidden"
        case .rubToReveal: return "Rub to reveal"
        case .revealAll:   return "Reveal all"
        }
    }
}

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case loading
        case signedOut
        case signedIn
        /// We could not reach the server to confirm the session — NOT a sign-out.
        ///
        /// Bootstrap used to collapse this into `.signedOut`, which is how a valid session
        /// turned into a login prompt every time the first request after a wake, a redeploy or
        /// a dropped network happened to fail. The session cookie is untouched here; a retry
        /// (or the next launch) picks it straight back up.
        case unreachable
        /// No server has been configured yet — a fresh install, before onboarding.
        ///
        /// Command deliberately ships with no default server: the person's notes and assistant
        /// conversations live on a machine they control, so there is nowhere for the app to
        /// point until they say where. This drives the setup flow rather than dumping someone
        /// at a sign-in form for a server that does not exist.
        case needsServer
    }
    enum SessionMode: String, Codable { case operatorAccount, delegatee }

    /// Which screen the Assistant tab shows: still resolving the entitlement, the
    /// one-time AI-disclosure consent, the subscription paywall, or the live chat.
    enum AssistantGate: Equatable { case loading, consent, paywall, ready }

    /// Pure gate decision (unit-tested). Consent (AI disclosure) gates first use
    /// regardless of billing — Apple requires it before any user data reaches a
    /// third-party model. The paywall applies only when the server is gating on a
    /// subscription and the account is neither entitled (server) nor subscribed
    /// (RevenueCat, for the moment right after a purchase before the webhook lands).
    static func resolveGate(entitlement e: AgentEntitlement?, isSubscribed: Bool) -> AssistantGate {
        guard let e else { return .loading }
        if !e.consentGiven { return .consent }
        if e.requiresSubscription && !(e.active || isSubscribed) { return .paywall }
        return .ready
    }

    var assistantGate: AssistantGate {
        Self.resolveGate(entitlement: entitlement, isSubscribed: subscription.isSubscribed)
    }

    /// The gate every Assistant surface (content column, detail column, compact tab) should read —
    /// the real gate, with the DEBUG screenshot overrides applied once here so all the panes stay
    /// coherent (forcing `.ready` for a screenshot must reveal the chat in the detail column too).
    var assistantGateResolved: AssistantGate {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "COMMAND_FORCE_PAYWALL") { return .paywall }
        if UserDefaults.standard.bool(forKey: "COMMAND_FORCE_CONSENT") { return .consent }
        if UserDefaults.standard.bool(forKey: "COMMAND_FORCE_READY") { return .ready }
        #endif
        return assistantGate
    }

    private(set) var phase: Phase = .loading
    private(set) var account: Account?
    private(set) var myProfile: MyProfile?
    private(set) var sessionMode: SessionMode?
    /// An `inv-…` token arriving via the command://invite/<token> deep link, held until the
    /// auth screen consumes it (the app may still be bootstrapping when the URL lands).
    var pendingInviteToken: String?
    /// The server's view of assistant access (consent + subscription). Drives the
    /// AI-consent gate and the paywall. Loaded on sign-in; nil while unknown.
    private(set) var entitlement: AgentEntitlement?
    private(set) var client: APIClient
    private(set) var serverURLString: String
    /// How hidden (invisible-ink) captures display, app-wide — a local presentation
    /// choice set in the profile, persisted like the server URL.
    var hiddenRevealMode: HiddenRevealMode {
        didSet { UserDefaults.standard.set(hiddenRevealMode.rawValue, forKey: Self.hiddenModeKey) }
    }
    var lastError: String?

    /// Shared notes state (capture bar + Notes list stay in sync).
    let notes = NotesStore()
    /// Shared delegatee roster (People list + assignee pickers).
    let people = PeopleStore()
    /// Shared goals + assignments.
    let tasks = TasksStore()
    /// Shared activity log (capture bar + calendar markers + Log list stay in sync).
    let log = LogStore()
    /// Month-grid state (visible month, selected day, windowed occurrences/activities).
    /// Shared so the iPad/Mac split can render the month grid in the content column and the
    /// selected day's agenda in the detail column against one source of truth.
    let cal = CalendarStore()
    /// Capture state for scheduling forward-dated assignments from the calendar.
    let schedule = ScheduleStore()
    /// The AI assistant: chat threads, transcript, streaming run, usage meter.
    let agent = AgentStore()
    /// In-app subscription (Command Pro via RevenueCat): purchase/restore + status.
    let subscription = SubscriptionStore()
    /// Voice transcription router (Parakeet v3 → SpeechTranscriber → SFSpeech).
    let transcription = TranscriptionService()
    /// In-progress features that ship dark (all default OFF — see FeatureFlags).
    let flags = FeatureFlags()
    /// Device PIN lock state machine (only consulted when the `deviceLock` flag is on).
    let lock = LockController()
    /// The reveal gate for redaction — biometric/passcode challenge before unredacting or
    /// peeking at a hidden item. Shares the device-lock PIN; works regardless of the flag.
    let privacy = PrivacyGate()
    /// APNs registration for reminder pushes (enabled after sign-in).
    let push = PushService()

    /// `nonisolated` so the App Intents layer (which runs off the main actor) can read the
    /// server config to build its own `APIClient`. Plain constants — safe to read anywhere.
    /// Deliberately empty: an open-source build must not phone home to anyone else's server.
    /// A fresh install goes through onboarding and chooses its own.
    nonisolated static let defaultServerURL = ""

    /// UserDefaults key for the configured server URL. Exposed (not private) so the
    /// App Intents layer can build its own `APIClient` against the same server the app
    /// uses — it runs in a separate launch context and can't reach this instance.
    nonisolated static let urlKey = "command.serverURL"
    private static let hiddenModeKey = "command.hiddenRevealMode"
    nonisolated static let sessionModeKey = "command.sessionMode"
    private static let myProfileKey = "command.myProfile"

    /// Keep the server an existing install was already signed in to.
    ///
    /// Builds before 2026-08-05 had a built-in server, so an install that never opened the server
    /// sheet has no `urlKey` written at all. Removing the default would read, on a routine update,
    /// as "the app logged me out and now demands a server" — the unforced-logout class the
    /// `.unreachable` phase exists to prevent.
    ///
    /// The address is recovered from the install's own session cookie rather than hard-coded:
    /// a `command_session` cookie is only ever set by the server the user signed in to, so its
    /// domain IS that server. Prior use is also required (a persisted `sessionMode`, written only
    /// after a sign-in), so a fresh install always falls through to onboarding. Idempotent: once
    /// written, the key exists and this never fires again.
    nonisolated static func migrateLegacyServerURL(_ defaults: UserDefaults,
                                                   cookies: [HTTPCookie]? = HTTPCookieStorage.shared.cookies) {
        guard defaults.string(forKey: urlKey)?.isEmpty ?? true else { return }
        guard defaults.string(forKey: sessionModeKey) != nil else { return }
        guard let session = cookies?.first(where: { $0.name == "command_session" && $0.isSecure }) else { return }
        let host = session.domain.hasPrefix(".") ? String(session.domain.dropFirst()) : session.domain
        guard !host.isEmpty else { return }
        defaults.set("https://\(host)", forKey: urlKey)
    }

    /// Whether a server has been chosen yet. Drives `.needsServer`.
    var hasServer: Bool { !serverURLString.trimmingCharacters(in: .whitespaces).isEmpty }

    init() {
        Self.migrateLegacyServerURL(UserDefaults.standard)
        let saved = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultServerURL
        serverURLString = saved
        hiddenRevealMode = UserDefaults.standard.string(forKey: Self.hiddenModeKey)
            .flatMap(HiddenRevealMode.init(rawValue:)) ?? .keepHidden
        // With no server configured the client is a placeholder that is never called — the app
        // is routed to onboarding before anything can use it.
        client = APIClient(baseURL: URL(string: saved) ?? URL(string: "https://unconfigured.invalid")!)
        sessionMode = UserDefaults.standard.string(forKey: Self.sessionModeKey)
            .flatMap(SessionMode.init(rawValue:))
        if let data = UserDefaults.standard.data(forKey: Self.myProfileKey) {
            myProfile = try? JSONDecoder().decode(MyProfile.self, from: data)
        }
        installClientHooks()
        // Check the on-disk Parakeet model and assemble the engine tier list.
        transcription.configure()
    }

    /// Wire the client's session-expiry callback back to us. Reinstalled whenever the
    /// client is rebuilt (a server-URL change), so the hook never points at a stale client.
    private func installClientHooks() {
        client.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.handleSessionExpired() }
        }
    }

    /// Did the SERVER actually reject this session, or did we merely fail to reach it?
    ///
    /// Only an explicit `auth_failed` envelope counts. Everything else — a transport error, a
    /// 5xx, an edge/WAF 401 or 403 with no envelope, a decode failure — means "we don't know",
    /// and the one thing we must not do when we don't know is throw away a working session.
    /// This is the same rule `APIClient.isSessionExpiry` applies to mid-use 401s; bootstrap was
    /// the one path that bypassed it, by using `try?` and treating every failure alike.
    static func serverRejectedTheSession(_ error: Error) -> Bool {
        guard case APIError.http(let status, let code, _) = error else { return false }
        return status == 401 && code == "auth_failed"
    }

    func bootstrap() async {
        #if DEBUG
        // Offline UI-preview hook (debug builds only): land signed-in with a stub
        // account + entitlement so gated screens render with no network. Pair with
        // `-COMMAND_UI_PREVIEW YES` plus `-COMMAND_FORCE_PAYWALL`/`-COMMAND_FORCE_CONSENT`.
        if UserDefaults.standard.bool(forKey: "COMMAND_UI_PREVIEW") {
            account = Account(id: 0, username: "preview", displayName: nil,
                              createdAt: "2026-06-19T00:00:00Z")
            myProfile = nil
            setSessionMode(.operatorAccount)
            entitlement = AgentEntitlement(
                active: false, requiresSubscription: false, productId: "command_pro_monthly",
                priceDisplay: "$19.99/mo", trialDays: 7, consentGiven: false, status: "none",
                periodType: nil, expiresAt: nil, willRenew: false)
            // A little sample content so list screens (and search) are demonstrable offline.
            if UserDefaults.standard.bool(forKey: "COMMAND_PREVIEW_SEED") {
                let stamp = "2026-06-26T09:00:00Z"
                func note(_ id: Int, _ title: String, _ body: String) -> Note {
                    Note(id: id, accountId: 0, body: body, title: title, titleStatus: "user",
                         source: "text", engine: nil, locale: nil, processedAt: nil, archivedAt: nil,
                         hidden: false, createdAt: stamp, updatedAt: stamp)
                }
                func hiddenNote(_ id: Int, _ title: String, _ body: String) -> Note {
                    Note(id: id, accountId: 0, body: body, title: title, titleStatus: "user",
                         source: "text", engine: nil, locale: nil, processedAt: nil, archivedAt: nil,
                         hidden: true, createdAt: stamp, updatedAt: stamp)
                }
                notes.notes = [
                    note(1, "Q3 budget review", "Email Dana about the Q3 budget and the vendor renewal."),
                    hiddenNote(4, "Bonus plan", "Private: comp adjustments for Q3."),
                    note(2, "Grocery run", "Milk, eggs, coffee, olive oil."),
                    note(3, "iPad/Mac launch post", "Draft the launch announcement for the new apps."),
                ]
                people.delegatees = [
                    Delegatee(id: 1, accountId: 0, slug: "dana", name: "Dana Whitlock", kind: "human",
                              leadTimeMinutes: 1440, metadata: ["note": .string("Prefers a day's notice")],
                              active: true, isSelf: false, createdAt: stamp, updatedAt: stamp),
                    Delegatee(id: 2, accountId: 0, slug: "marcus", name: "Marcus Lee", kind: "human",
                              leadTimeMinutes: 120, metadata: [:],
                              active: true, isSelf: false, createdAt: stamp, updatedAt: stamp),
                    Delegatee(id: 3, accountId: 0, slug: "opus", name: "Claude Opus 5.5", kind: "ai_model",
                              leadTimeMinutes: 0, metadata: ["model_id": .string("claude-opus-5.5")],
                              active: true, isSelf: false, createdAt: stamp, updatedAt: stamp),
                ]
                tasks.goals = [
                    Goal(id: 1, accountId: 0, title: "Ship iPad & Mac apps", description: nil,
                         status: "in_progress", targetDate: "2026-07-15", notes: nil, createdAt: stamp, updatedAt: stamp),
                    Goal(id: 2, accountId: 0, title: "Close Q3 budget", description: nil,
                         status: "open", targetDate: "2026-07-31", notes: nil, createdAt: stamp, updatedAt: stamp),
                ]
                func assignment(_ id: Int, _ title: String, goal: Int?, assignee: Int?,
                                kind: String, status: String) -> Assignment {
                    Assignment(id: id, accountId: 0, goalId: goal, title: title, details: nil,
                               assigneeId: assignee, scheduleKind: kind, rrule: kind == "routine" ? "FREQ=WEEKLY" : nil,
                               scheduledStart: kind == "sporadic" ? "2026-07-02T09:00:00Z" : nil, scheduledEnd: nil,
                               timezone: nil, leadTimeMinutes: nil, status: status, priority: 0, hidden: false, archivedAt: nil,
                               notes: nil, origin: "manual", createdAt: stamp, updatedAt: stamp)
                }
                func hiddenAssignment(_ id: Int, _ title: String) -> Assignment {
                    Assignment(id: id, accountId: 0, goalId: nil, title: title, details: nil,
                               assigneeId: nil, scheduleKind: "sporadic", rrule: nil,
                               scheduledStart: "2026-07-03T09:00:00Z", scheduledEnd: nil, timezone: nil,
                               leadTimeMinutes: nil, status: "todo", priority: 0, hidden: true, archivedAt: nil,
                               notes: nil, origin: "manual", createdAt: stamp, updatedAt: stamp)
                }
                tasks.assignments = [
                    assignment(1, "Draft launch announcement", goal: 1, assignee: 3, kind: "sporadic", status: "todo"),
                    hiddenAssignment(4, "Confidential: board prep"),
                    assignment(2, "Email Dana about vendor renewal", goal: 2, assignee: 1, kind: "sporadic", status: "scheduled"),
                    assignment(3, "Weekly grocery run", goal: nil, assignee: 2, kind: "routine", status: "todo"),
                ]
                // Calendar occurrences (the calendar reads app.cal, which a real load would fetch
                // from the server; in preview we seed it and skip the load). Includes a first-class
                // multi-day event (Jul 2–4) so the "spans a set of days" feature is demonstrable.
                func occ(_ aid: Int, _ title: String, _ at: String, dayIndex: Int? = nil, dayCount: Int? = nil) -> Occurrence {
                    Occurrence(assignmentId: aid, title: title, occursAt: at, status: "scheduled",
                               assigneeId: nil, scheduleKind: "sporadic", hidden: false,
                               dayIndex: dayIndex, dayCount: dayCount)
                }
                cal.occurrences = [
                    occ(10, "Team offsite", "2026-07-02T09:00:00Z", dayIndex: 1, dayCount: 3),
                    occ(10, "Team offsite", "2026-07-03T09:00:00Z", dayIndex: 2, dayCount: 3),
                    occ(10, "Team offsite", "2026-07-04T09:00:00Z", dayIndex: 3, dayCount: 3),
                    occ(2, "Email Dana about vendor renewal", "2026-07-02T14:00:00Z"),
                ]
                cal.selectedDay = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 2)) ?? Date()
            }
            // App Store capture: a richer, story-driven fixture composed to photograph well.
            // Separate from PREVIEW_SEED so tuning the marketing frames can't perturb the terse
            // fixture the UI-verification flows assert against. See MarketingSeed.swift.
            if UserDefaults.standard.bool(forKey: "COMMAND_MARKETING_SEED") {
                entitlement = AgentEntitlement(
                    active: true, requiresSubscription: false, productId: "command_pro_monthly",
                    priceDisplay: "$19.99/mo", trialDays: 7, consentGiven: true, status: "active",
                    periodType: "trial", expiresAt: nil, willRenew: true)
                notes.notes = MarketingSeed.notes()
                people.delegatees = MarketingSeed.delegatees()
                people.selfDelegatee = MarketingSeed.me()
                tasks.goals = MarketingSeed.goals()
                tasks.assignments = MarketingSeed.assignments()
                cal.occurrences = MarketingSeed.occurrences()
                agent.transcript = MarketingSeed.transcript()
                cal.selectedDay = Date()   // the seed is anchored on today
            }
            phase = .signedIn
            return
        }
        #endif
        // Nowhere to bootstrap against yet. A fresh install has no server, and asking for a
        // password before there is anything to sign in to is the wrong first screen.
        guard hasServer else {
            phase = .needsServer
            return
        }
        // Preserve the existing operator bootstrap exactly: /api/auth/me remains the first and
        // decisive probe. The persisted mode/profile lets RootView route immediately once the
        // cookie has been validated, without a second identity request or shell transition.
        // Both probes are attempted even when the first fails with a rejection: a delegatee
        // session is legitimately rejected by /auth/me and only recognised by /me.
        var reachedTheServer = false
        do {
            let me = try await client.me()
            account = me
            setSessionMode(.operatorAccount)
            await onSignedIn()
            lock.configure(accountId: me.id, lockNow: true)   // resumed session → require the PIN
            phase = .signedIn
            return
        } catch {
            reachedTheServer = Self.serverRejectedTheSession(error)
        }
        do {
            let profile = try await client.myProfile()
            account = nil
            myProfile = profile
            setSessionMode(.delegatee)
            push.enable(client: client, route: .delegatee)   // reminders for this delegatee's own assignments
            phase = .signedIn
            return
        } catch {
            reachedTheServer = reachedTheServer || Self.serverRejectedTheSession(error)
        }
        // Nothing said "your session is invalid" — we simply could not confirm it. Keep the
        // cookie and the persisted mode; signing out here is the false positive that made the
        // Mac app ask for a password after every blip.
        //
        // …but only when there IS a session to protect. With no cookie at all (never signed in,
        // or a server address that was wrong from the start) "Can't reach Command — you're still
        // signed in" is false, and it traps the user on a screen whose only honest exit is the
        // sign-in screen, where the server can be changed.
        if !reachedTheServer, client.hasSessionCookie() {
            phase = .unreachable
            return
        }
        #if DEBUG
        // UI-verification hook: launch with `-COMMAND_AUTOLOGIN_USER x -COMMAND_AUTOLOGIN_PASS y`
        // (parsed into UserDefaults) to land signed-in for screenshots. Debug builds only.
        let defaults = UserDefaults.standard
        if let user = defaults.string(forKey: "COMMAND_AUTOLOGIN_USER"),
           let pass = defaults.string(forKey: "COMMAND_AUTOLOGIN_PASS") {
            await login(username: user, password: pass)
            if phase == .signedIn { return }
        }
        #endif
        account = nil
        myProfile = nil
        clearPersistedSessionMode()
        phase = .signedOut
    }

    func login(username: String, password: String) async {
        await run {
            self.account = try await self.client.login(username: username, password: password)
            self.myProfile = nil
            self.setSessionMode(.operatorAccount)
            await self.onSignedIn()
            self.lock.configure(accountId: self.account?.id, lockNow: false)  // just authenticated
            self.phase = .signedIn
        }
    }

    func register(username: String, password: String, displayName: String?) async {
        await run {
            self.account = try await self.client.register(
                username: username, password: password,
                displayName: (displayName?.isEmpty == false) ? displayName : nil)
            self.myProfile = nil
            self.setSessionMode(.operatorAccount)
            await self.onSignedIn()
            self.lock.configure(accountId: self.account?.id, lockNow: false)
            self.phase = .signedIn
        }
    }

    /// Handle command://invite/<token>. Only a signed-out app acts on it: redeeming inside a
    /// live operator session would silently swap the whole app to a delegatee session. The
    /// token is parked for AuthView, which opens the redeem sheet with it.
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "command",
              url.host?.lowercased() == "invite" else { return }
        let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !token.isEmpty, phase != .signedIn else { return }
        pendingInviteToken = token
        // Invites carry the inviter's server (`?server=`). Without it, someone installing
        // Command for the first time from an invite landed in onboarding being told to host
        // their own server, with no way to learn the address the invite belongs to.
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "server" })?.value,
              let server = ServerSetupGuide.normalizedServerURL(raw),
              // Only ever fills in a MISSING server. A link must not repoint an app that already
              // has one — that would let a crafted invite put a stranger's sign-in screen, and
              // the user's password, in front of a server they never chose.
              !hasServer
        else { return }
        Task { await setServerURL(server.absoluteString) }
    }

    /// The deep link an invite shares: the token plus this server's address.
    func inviteLink(token: String) -> String {
        var comps = URLComponents()
        comps.scheme = "command"
        comps.host = "invite"
        comps.path = "/" + token
        comps.queryItems = [URLQueryItem(name: "server", value: serverURLString)]
        return comps.url?.absoluteString ?? "command://invite/\(token)"
    }

    func redeemInvite(token: String) async {
        await run {
            let profile = try await self.client.redeemInvite(token: token)
            self.account = nil
            self.myProfile = profile
            self.setSessionMode(.delegatee)
            self.push.enable(client: self.client, route: .delegatee)
            self.lock.reset()
            self.phase = .signedIn
        }
    }

    /// Post-sign-in fan-out: load the entitlement (consent + subscription state) and
    /// bind RevenueCat's identity to this account so its purchase webhook maps back.
    private func onSignedIn() async {
        await refreshEntitlement()
        // RevenueCat identity + offering load run OFF the critical path. A slow or
        // stalled StoreKit product fetch — e.g. a freshly-created sandbox product still
        // propagating into the catalog — must never block the app shell or the sign-in
        // flow (it would otherwise pin `phase` on `.loading` → a perpetual spinner).
        // The Assistant gate resolves from the server `entitlement` loaded above; RC's
        // local `isSubscribed` and the paywall package land whenever the fetch returns.
        if let id = account?.id {
            // Older servers don't send `billing_user_id`; they keyed on the bare account id.
            let appUserId = entitlement?.billingUserId ?? String(id)
            Task { [subscription] in await subscription.identify(appUserId: appUserId) }
        }
        push.enable(client: client)   // ask for notification permission + register this device for reminders
        pushTimezone()                // keep the server's account timezone in sync with this device (B2)
    }

    /// Fire-and-forget the device's current IANA timezone to the server so the agent
    /// resolves relative dates in the user's zone (B2). Idempotent server-side, so it's
    /// safe to call on every sign-in and every app foreground. Best-effort: a failure is
    /// swallowed — the next foreground/login retries, and the agent falls back to a default.
    func pushTimezone() {
        // A zone the user picked by hand in Account wins: pushing the device zone on every
        // foreground used to undo that choice within seconds of leaving the screen.
        guard UserDefaults.standard.string(forKey: Self.manualTimezoneKey) == nil else { return }
        let id = TimeZone.current.identifier
        Task { [client] in try? await client.setTimezone(id) }
    }

    static let manualTimezoneKey = "manualTimezone"

    /// The user chose a timezone in Account. Choosing the device's own zone returns to
    /// following the device; any other zone is pinned until they do.
    func chooseTimezone(_ id: String) {
        if id == TimeZone.current.identifier {
            UserDefaults.standard.removeObject(forKey: Self.manualTimezoneKey)
        } else {
            UserDefaults.standard.set(id, forKey: Self.manualTimezoneKey)
        }
        Task { [client] in try? await client.setTimezone(id) }
    }

    /// The app returned to the foreground. Refresh anything that drifts while backgrounded —
    /// currently just the account timezone (the user may have crossed zones or changed the
    /// device setting). No-op unless signed in.
    func didEnterForeground() {
        guard phase == .signedIn, sessionMode == .operatorAccount else { return }
        pushTimezone()
        // Refund the proactive-LLM send budget: opening the app IS the engagement signal the
        // churn guard resets on. Fire-and-forget — it must never block or fail a foreground.
        Task { [client] in await client.appOpened() }
        // Silent resync (spec 2026-07-19-later-bucket): another device may have changed things
        // while this one was backgrounded. Stores keep current rows while fetching and apply
        // diffs with animation, so this never blanks or flickers a visible list.
        Task {
            await cal.load(client: client)
            await notes.load(client: client)
            await tasks.load(client: client)
            await people.load(client: client)
        }
    }

    /// Reload the store backing the section currently on screen — the target of
    /// the Mac/iPad ⌘R "Refresh" command. The Calendar's own `CalendarStore` is
    /// view-local and refreshes via its `.refreshable`; here we reload the shared
    /// activity log that feeds its agenda.
    func reloadVisible(_ destination: AppDestination) async {
        switch destination {
        case .calendar:           await cal.load(client: client)   // the agenda reads cal, not log
        case .notes:              await notes.load(client: client)
        case .tasks:              await tasks.load(client: client)
        case .people:             await people.load(client: client)
        case .assistant:
            // Retry the entitlement too, not just the thread list: a transient failure at
            // sign-in leaves it nil → the gate is stuck on `.loading` (a perpetual spinner),
            // and reloading only threads never recovered it. ⌘R now un-sticks the tab.
            if entitlement == nil { await refreshEntitlement() }
            await agent.loadThreads(client: client)
        case .account:            break
        }
    }

    /// Re-read the server entitlement (consent recorded, subscription flipped, etc.).
    /// A transient failure keeps whatever we had rather than nil-ing a good value, and is
    /// recoverable via ⌘R / re-navigation (see `reloadVisible`).
    @discardableResult
    func refreshEntitlement() async -> Bool {
        guard let e = try? await client.agentEntitlement() else { return false }
        entitlement = e
        return true
    }

    /// After a purchase, wait for the server's mirror of the subscription to land.
    ///
    /// The server learns about a purchase from RevenueCat's webhook — a server-to-server call
    /// whose timing we don't control. Refreshing once the instant `purchase()` returns races
    /// that webhook and usually loses. The client gate opens anyway (`resolveGate` deliberately
    /// trusts StoreKit's `isSubscribed` so the paywall doesn't linger over a completed
    /// purchase), but the server runs its own check on the first assistant turn — so the user
    /// who just paid was told "Subscribe to Command Pro to use the assistant."
    ///
    /// Polling briefly closes that window: the mirror normally lands in about a second, and the
    /// user still has to dismiss the sheet and type before their first turn. Bounded and
    /// backing off, so a webhook that never arrives costs a few requests rather than a spin —
    /// and this is a convenience, not the guarantee. The server remains the authority, and a
    /// genuinely delayed webhook still surfaces its own error.
    ///
    /// The complete fix is server-side on-demand verification against RevenueCat when the
    /// mirror is missing; that needs an API key in the server environment and is the operator's
    /// call, so it stays flagged rather than assumed.
    func awaitEntitlementActivation(attempts: Int = 6) async {
        await Self.pollUntilActive(
            attempts: attempts,
            sleep: { try? await Task.sleep(for: .milliseconds($0)) },
            check: {
                await self.refreshEntitlement()
                return self.entitlement?.active == true
            }
        )
    }

    /// Back-off schedule for the activation poll: 0.4s, 0.8s, 1.6s, then 3.2s.
    /// About 9s across the default six attempts — comfortably inside the time it takes to
    /// dismiss the sheet and type a first message, without spinning if the webhook never lands.
    static func activationBackoffMs(attempt: Int) -> Int { min(3200, 400 << min(attempt, 3)) }

    /// Poll `check` until it reports true, backing off between attempts. Returns how many
    /// attempts were made.
    ///
    /// The effects are the caller's (this codebase keeps decision logic pure so it can be
    /// tested — see `shouldAdopt` and `resolveGate`): a real caller passes a network probe and
    /// `Task.sleep`, a test passes counters. Notably it must NOT sleep after a successful
    /// check — that would add the whole backoff to the common case, where the mirror is
    /// already there.
    @discardableResult
    static func pollUntilActive(
        attempts: Int,
        sleep: (Int) async -> Void,
        check: () async -> Bool
    ) async -> Int {
        for attempt in 0..<max(0, attempts) {
            if await check() { return attempt + 1 }
            await sleep(activationBackoffMs(attempt: attempt))
        }
        return max(0, attempts)
    }

    /// Record the user's AI-disclosure consent and refresh the entitlement. Returns
    /// whether it succeeded so the consent gate can show an error and stay put on failure.
    @discardableResult
    func recordConsent() async -> Bool {
        guard let e = try? await client.agentConsent() else { return false }
        entitlement = e
        return true
    }

    func logout() async {
        await push.disable()          // unregister (either surface) while the session is still valid
        try? await client.logout()   // best-effort server-side session revoke
        tearDownSession()
    }

    /// The account was deleted server-side; drop every trace of it locally.
    ///
    /// Distinct from `logout()`, which tries to revoke a session that still exists. Here the
    /// account is already gone, so calling the server again would only 401 — and the local PIN
    /// must go too, or the next user of this device would meet a lock screen for an account that
    /// no longer exists.
    func forgetDeletedAccount() async {
        lock.reset()
        tearDownSession()
        lastError = nil
    }

    /// The server rejected our session with 401 mid-use — the cookie expired or was
    /// revoked. Drop cleanly to the sign-in screen with a clear message instead of leaving
    /// every store call failing with a generic "HTTP 401". Idempotent: a burst of concurrent
    /// 401s (many stores in flight) collapses to a single teardown via the phase guard.
    func handleSessionExpired() {
        #if DEBUG
        // `-COMMAND_UI_PREVIEW` is an explicitly offline harness: it seeds a stub account that never
        // has a real session cookie, so the first list load 401s and would tear the seeded session
        // straight back down to the sign-in screen — making the preview hook unusable for exactly
        // the screenshot/verification job it exists for. Server auth is not the subject in preview.
        if UserDefaults.standard.bool(forKey: "COMMAND_UI_PREVIEW") { return }
        #endif
        guard phase == .signedIn else { return }
        lastError = "Your session expired — please sign in again."
        tearDownSession()
    }

    /// Clear all per-account state and return to `.signedOut`. Shared by explicit logout and
    /// session-expiry; does NOT call the server (the caller decides whether to revoke — the
    /// expiry path must not, or it would recurse on another 401).
    private func tearDownSession() {
        push.reset()
        lock.reset()
        account = nil
        myProfile = nil
        clearPersistedSessionMode()
        UserDefaults.standard.removeObject(forKey: Self.manualTimezoneKey)   // it was that account's choice
        entitlement = nil
        Task { [subscription] in await subscription.signOut() }
        notes.notes = []
        notes.draft = ""
        people.delegatees = []
        tasks.assignments = []
        tasks.goals = []
        log.activities = []
        log.actors = []
        log.summary = []
        log.draft = ""
        log.composeActorId = nil
        // CalendarStore + ScheduleStore are separate from the log store; clear them too or
        // the next account briefly sees the prior account's occurrences/agenda and a stale
        // capture-bar draft until a reload.
        cal.occurrences = []
        cal.activities = []
        schedule.draft = ""
        schedule.assigneeId = nil
        schedule.repeats = .never
        schedule.errorMessage = nil
        agent.reset()
        // Drop the credential itself, not just the state derived from it. The cookie jar is
        // process-wide (`HTTPCookieStorage.shared`) and the App Intents surface builds its own
        // client from it, so a session left in the jar means Siri and Shortcuts keep writing to
        // the account the user just signed out of. The server-side revoke can't be relied on to
        // have landed — `logout()` calls it with `try?`, and signing out offline is ordinary.
        // `.unreachable` keeps its cookie by design and only gets here when the user explicitly
        // signs out or changes server from that screen.
        client.clearSessionCookies()
        // The widget lives in another process and renders from the App Group, so it never sees
        // a sign-out — clearing the in-app stores above does nothing for it. Left alone it kept
        // the previous account's assignment titles on the home screen indefinitely (and
        // permanently, after an account deletion). Reload only if something was actually there,
        // so a sign-out on a device with no widget doesn't spend metered reload budget.
        if WidgetAgendaStore.clear() {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetAgendaStore.agendaKind)
        }
        phase = .signedOut
    }

    private func setSessionMode(_ mode: SessionMode) {
        sessionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.sessionModeKey)
        if mode == .delegatee, let myProfile, let data = try? JSONEncoder().encode(myProfile) {
            UserDefaults.standard.set(data, forKey: Self.myProfileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.myProfileKey)
        }
    }

    private func clearPersistedSessionMode() {
        sessionMode = nil
        UserDefaults.standard.removeObject(forKey: Self.sessionModeKey)
        UserDefaults.standard.removeObject(forKey: Self.myProfileKey)
    }

    /// Point the app at a different server (e.g. LAN during dev). Rebuilds the
    /// client, persists the choice, and re-derives sign-in state.
    /// What checking an address for a Command server found.
    enum ServerProbe: Equatable, Sendable {
        /// A Command server answered at this (normalised) URL.
        case found(URL)
        /// The text isn't an address we can call at all.
        case invalid
        /// Something answered, but it isn't a Command server (wrong port, a router page…).
        case notCommand(URL)
        /// iOS refused plain http to a public-style name (App Transport Security).
        case needsHTTPS(URL)
        /// The TLS handshake failed — usually https to a server that only speaks http.
        case certificate(URL)
        /// Nothing answered.
        case unreachable(URL)

        /// A sentence the setup screens can show as-is — each case says what to do next.
        var message: String? {
            switch self {
            case .found: return nil
            case .invalid:
                return "That doesn't look like a server address. Try something like command.example.com or http://192.168.1.10:9071."
            case .notCommand(let url):
                return "\(url.host ?? "That address") answered, but it isn't a Command server. Check the port and that the address points at Command."
            case .needsHTTPS(let url):
                return "iOS only allows encrypted connections to \(url.host ?? "that address"). Use its https:// address — with Tailscale, turn on HTTPS certificates for your tailnet."
            case .certificate(let url):
                return "Couldn't make a secure connection to \(url.host ?? "that address"). If the server has no certificate, enter it with http:// instead."
            case .unreachable(let url):
                return "Couldn't reach a Command server at \(url.host ?? url.absoluteString). Check the address, and that the server is running."
            }
        }
    }

    /// Check an address the user typed for a Command server, before it is committed.
    ///
    /// Probed first so a typo surfaces on the setup screen, where it can be corrected, rather
    /// than later as an unexplained failure against a host that was never a Command server.
    /// `/api/health` is unauthenticated and exists to answer exactly this; the body is checked
    /// too, since plenty of things return 200.
    ///
    /// When the scheme was left off, `https://` is assumed — but a box on the LAN has no
    /// certificate, so for a local address plain http is tried as well. Of the failures, the
    /// most specific one is reported: "something answered but it isn't Command" beats "the
    /// secure connection failed", which beats "nothing answered".
    nonisolated func probeServer(_ raw: String) async -> ServerProbe {
        guard let url = ServerSetupGuide.normalizedServerURL(raw) else { return .invalid }
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var candidates = [url]
        if !typed.hasPrefix("http://"), !typed.hasPrefix("https://"),
           ServerSetupGuide.isLocalAddress(url),
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "http"
            if let http = comps.url { candidates.append(http) }
        }
        var results: [ServerProbe] = []
        for candidate in candidates {
            let result = await Self.probe(candidate)
            if case .found = result { return result }
            results.append(result)
        }
        func rank(_ p: ServerProbe) -> Int {
            switch p {
            case .notCommand: return 0
            case .needsHTTPS, .certificate: return 1
            default: return 2
            }
        }
        return results.min { rank($0) < rank($1) } ?? .unreachable(url)
    }

    private nonisolated static func probe(_ url: URL) async -> ServerProbe {
        var request = URLRequest(url: url.appendingPathComponent("api/health"))
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["service"] as? String == "command"
            else { return .notCommand(url) }
            return .found(url)
        } catch let error as URLError {
            switch error.code {
            case .appTransportSecurityRequiresSecureConnection:
                return .needsHTTPS(url)
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return .certificate(url)
            default:
                return .unreachable(url)
            }
        } catch {
            return .unreachable(url)
        }
    }

    func setServerURL(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            lastError = "Enter a valid URL, e.g. https://command.example.tld"
            return
        }
        // Moving to a different server ends the session on the old one first. Otherwise the old
        // account's push token stays registered there (its reminders keep arriving), and its
        // stores, widget snapshot and billing identity linger until something overwrites them.
        if trimmed != serverURLString, phase == .signedIn || phase == .unreachable {
            await logout()
        }
        serverURLString = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.urlKey)
        client = APIClient(baseURL: url)
        installClientHooks()
        phase = .loading
        await bootstrap()
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        do { try await work(); lastError = nil }
        catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}
