//
//  AccountView.swift
//  Command
//

import SwiftUI
import UIKit

struct AccountView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var token: String?
    @State private var loadingToken = false
    @State private var sheet: ActiveSheet?
    @State private var showSetPin = false
    @State private var tzSelection = TimeZone.current.identifier
    /// Set while the picker is being filled from the account, so that load isn't mistaken for
    /// the user choosing a zone.
    @State private var loadingTimezone = false
    @State private var confirmDelete = false
    @State private var deletePassword = ""
    @State private var deleteError: String?
    @State private var deleting = false
    @State private var calendarSubscription: CalendarSubscription?
    @State private var loadingCalendarSubscription = false
    @State private var calendarSubscriptionError: String?
    @State private var copiedCalendarLink = false
    @State private var copiedToken = false
    @State private var confirmRegenerate = false
    @State private var briefings: BriefingPrefs?
    @State private var briefingsError: String?

    private enum ActiveSheet: Int, Identifiable { case switchServer, handoff, paywall; var id: Int { rawValue } }

    /// All IANA zones, with the device zone surfaced first so the common case is one tap.
    static let zoneOptions: [String] = {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        let device = TimeZone.current.identifier
        return [device] + all.filter { $0 != device }
    }()

    var body: some View {
        // Presented as a sheet, so reveals asked for in here need their own challenge host.
        sheetContent.privacyChallenge()
    }

    private var sheetContent: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Username", value: app.account?.username ?? "—")
                    if let name = app.account?.displayName, !name.isEmpty {
                        LabeledContent("Name", value: name)
                    }
                } header: {
                    Text("Account")
                        .accessibilityAddTraits(.isHeader)
                }

                Section {
                    Picker("Timezone", selection: $tzSelection) {
                        ForEach(Self.zoneOptions, id: \.self) { z in Text(z).tag(z) }
                    }
                    .pickerStyle(.navigationLink)
                    if tzSelection != TimeZone.current.identifier {
                        Button("Use this device's timezone (\(TimeZone.current.identifier))") {
                            tzSelection = TimeZone.current.identifier
                        }
                    }
                } header: {
                    Text("Timezone")
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("The timezone your reminders and scheduled times are anchored to. New assignments use this zone.")
                }
                .onChange(of: tzSelection) { _, new in
                    if loadingTimezone { loadingTimezone = false; return }
                    app.chooseTimezone(new)
                }

                // Only a server that gates the assistant on a subscription sells one. A self-hosted
                // server runs the assistant on its owner's own model key, so offering Pro there
                // charged $19.99/month for nothing (and its webhook never reaches that server).
                // Existing subscribers still see it, to manage or restore.
                if isPro || app.entitlement?.requiresSubscription == true {
                    proSection
                }

                Section {
                    if let token {
                        Text(token)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text(loadingToken ? "Loading…" : "Hidden")
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    // Once shown, the one thing left to do with it is paste it into an agent's
                    // config, and a long monospaced string is fiddly to select by hand.
                    if let token {
                        Button {
                            UIPasteboard.general.string = token
                            withAnimation(.easeInOut(duration: 0.2)) { copiedToken = true }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(.easeInOut(duration: 0.2)) { copiedToken = false }
                            }
                        } label: {
                            HStack {
                                Image(systemName: copiedToken ? "checkmark" : "doc.on.doc")
                                    .accessibilityHidden(true)
                                Text(copiedToken ? "Copied" : "Copy token")
                            }
                            .font(Typeface.body(15, .medium))
                        }
                        .tint(Palette.accent)
                        .accessibilityLabel(copiedToken ? "Access token copied" : "Copy access token")
                    } else {
                        Button("Reveal token") { Task { await loadToken() } }
                    }
                    Button("Regenerate", role: .destructive) { confirmRegenerate = true }
                } header: {
                    Text("MCP access token")
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Paste this into Claude Code's MCP config to let it read your notes and help you plan. Regenerating invalidates the old one.")
                }

                Section {
                    NavigationLink {
                        ConnectedAgentsView()
                    } label: {
                        Text("Connected agents")
                    }
                } footer: {
                    Text("Other apps' AI agents your assistant can talk to — and how they reach yours.")
                }

                calendarSubscriptionSection

                Section {
                    NavigationLink {
                        TranscriptionSettingsView()
                    } label: {
                        LabeledContent("Voice & models", value: app.transcription.activeEngineName)
                    }
                } header: {
                    Text("Voice")
                        .accessibilityAddTraits(.isHeader)
                }

                Section {
                    Menu {
                        Button("Keep hidden") { app.hiddenRevealMode = .keepHidden }
                        Button("Rub to reveal") { app.hiddenRevealMode = .rubToReveal }
                        // Lifting the veil everywhere is the app-wide unredact — gate it.
                        Button("Reveal all", role: .destructive) {
                            Task {
                                if await app.privacy.authenticate(reason: "Reveal all hidden items") {
                                    app.hiddenRevealMode = .revealAll
                                }
                            }
                        }
                    } label: {
                        LabeledContent("Hidden items", value: app.hiddenRevealMode.label)
                    }
                } header: {
                    Text("Privacy")
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("How hidden captures display. “Rub to reveal” lets you rub a hidden item — in a list or its detail view — to peek at it; “Reveal all” shows hidden items everywhere. Hidden items stay hidden from the AI assistant either way.")
                }

                briefingsSection

                if app.flags.isOn(.deviceLock) { lockSection }

                #if DEBUG
                flagsSection   // DEBUG-only: never expose dev/security toggles in a Release build
                #endif

                serverSection

                Section {
                    Link("Privacy Policy", destination: BillingConfig.privacyURL)
                    Link("Terms of Use", destination: BillingConfig.termsURL)
                    Link("Support", destination: BillingConfig.supportURL)
                } header: {
                    Text("About")
                        .accessibilityAddTraits(.isHeader)
                }

                Section {
                    Button("Sign out", role: .destructive) { Task { await app.logout() } }
                }

                // App Review 5.1.1(v): an app that creates accounts must let you delete yours from
                // inside it. Not buried behind a support email — right here, next to Sign out.
                Section {
                    Button("Delete account", role: .destructive) {
                        deletePassword = ""
                        deleteError = nil
                        confirmDelete = true
                    }
                } footer: {
                    Text("Deletes your account and everything in it — notes, goals, assignments, "
                         + "people, and your conversations with the assistant. This cannot be undone.")
                }
            }
            .navigationTitle("Account")
            .brandedForm()
            // Password re-entry rather than a bare "are you sure?": this is irreversible, and a
            // borrowed or snatched phone already has a valid session.
            .alert("Delete account?", isPresented: $confirmDelete) {
                SecureField("Your password", text: $deletePassword)
                Button("Cancel", role: .cancel) {}
                Button(deleting ? "Deleting…" : "Delete forever", role: .destructive, action: deleteAccount)
                    .disabled(deletePassword.isEmpty || deleting)
            } message: {
                Text("This permanently deletes your account and all of its data. It cannot be undone. "
                     + "Enter your password to confirm.")
            }
            // Regenerating cuts off every agent using the current token at once, so ask first.
            .alert("Regenerate access token?", isPresented: $confirmRegenerate) {
                Button("Cancel", role: .cancel) {}
                Button("Regenerate", role: .destructive) { Task { await regenerate() } }
            } message: {
                Text("Agents using the current token, like Claude Code, lose access until you give them the new one.")
            }
            .alert("Could not delete account", isPresented: Binding(
                get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(deleteError ?? "") }
            .onAppear {
                if let tz = app.account?.timezone, tz != tzSelection {
                    loadingTimezone = true
                    tzSelection = tz
                }
            }
            .task { await loadCalendarSubscription() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).tint(Palette.accent).fixedSize()
                }
            }
            .task { await app.refreshServerInfo() }
            .sheet(item: $sheet) { which in
                switch which {
                // The onboarding choice screen; committing a different server signs out first
                // (AppState.setServerURL), which takes this sheet down with the session.
                case .switchServer:
                    OnboardingView(start: .switchServer, onCancel: { sheet = nil }).macSheet(.page)
                case .handoff:
                    AgentHandoffSheet(path: handoffPath).macSheet(.page)
                case .paywall: PaywallView(onClose: { sheet = nil }).macSheet(.page)
                }
            }
            .sheet(isPresented: $showSetPin) {
                if let id = app.account?.id { SetPinView(accountId: id).macSheet() }
            }
        }
    }

    // MARK: Server

    private var handoffPath: AgentHandoff.Path {
        SetupFlow.handoffPath(info: app.serverInfo, serverURL: app.serverURLString, chosen: app.chosenHosting)
    }

    /// Cloud vs self-hosted, the address, and everything setup-shaped: the assistant key (own
    /// server), the tutorial again, the agent hand-off, and switching servers.
    @ViewBuilder private var serverSection: some View {
        let info = app.serverInfo
        Section {
            LabeledContent("Hosting", value: SetupFlow.serverKindLabel(info: info, serverURL: app.serverURLString))
            LabeledContent("Address") {
                Text(app.serverURLString)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let info, info.isSelfHosted, info.aiKeySettable {
                Button(info.aiConfigured ? "Replace assistant AI key" : "Add assistant AI key") {
                    dismiss()
                    app.reopenSetup(.aiKey)
                }
            }
            Button("Setup & tutorial") {
                dismiss()
                app.reopenSetup(.ready)
            }
            Button {
                sheet = .handoff
            } label: {
                Label("Hand setup to your AI agent", systemImage: "sparkles.rectangle.stack")
            }
            Button("Switch server") { sheet = .switchServer }
        } header: {
            Text("Server")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            if SetupFlow.isCloud(info: info, serverURL: app.serverURLString) {
                Text("Command Cloud is run by Legitimate LLC. Switching servers signs you out here; your data stays where it is.")
            } else {
                Text("Your own Command server. Switching servers signs you out here; your data stays where it is.")
            }
        }
    }

    // MARK: Calendar subscription

    @ViewBuilder
    private var calendarSubscriptionSection: some View {
        Section {
            if loadingCalendarSubscription && calendarSubscription == nil {
                HStack {
                    Spacer()
                    ProgressView("Loading…")
                    Spacer()
                }
            } else if let calendarSubscriptionError {
                ErrorBanner(message: calendarSubscriptionError) {
                    Task { await loadCalendarSubscription() }
                }
            } else if let subscription = calendarSubscription,
                      subscription.enabled == "true",
                      let link = subscription.url {
                Text(link)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Button {
                    UIPasteboard.general.string = link
                    withAnimation(.easeInOut(duration: 0.2)) { copiedCalendarLink = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.easeInOut(duration: 0.2)) { copiedCalendarLink = false }
                    }
                } label: {
                    HStack {
                        Image(systemName: copiedCalendarLink ? "checkmark" : "doc.on.doc")
                            .accessibilityHidden(true)
                        Text(copiedCalendarLink ? "Copied" : "Copy link")
                    }
                    .font(Typeface.body(15, .medium))
                }
                .tint(Palette.accent)
                .accessibilityLabel(copiedCalendarLink ? "Calendar link copied" : "Copy calendar link")

                Button {
                    openCalendarSubscription(link)
                } label: {
                    HStack {
                        Image(systemName: "calendar.badge.plus")
                            .accessibilityHidden(true)
                        Text("Subscribe in Calendar")
                            .font(Typeface.body(15, .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .accessibilityLabel("Subscribe in Calendar")
            }
        } header: {
            Text("Calendar subscription")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            if calendarSubscription?.enabled == "true", calendarSubscription?.url != nil {
                Text("Adds your scheduled reminders to Apple or Google Calendar. The calendar is read-only and updates automatically.")
            } else if !loadingCalendarSubscription && calendarSubscriptionError == nil {
                Text("Calendar subscription isn't enabled on this server.")
            }
        }
    }

    private func loadCalendarSubscription() async {
        loadingCalendarSubscription = true
        calendarSubscriptionError = nil
        defer { loadingCalendarSubscription = false }
        do {
            calendarSubscription = try await app.client.calendarSubscription()
        } catch {
            calendarSubscriptionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func openCalendarSubscription(_ link: String) {
        guard var components = URLComponents(string: link) else { return }
        components.scheme = "webcal"
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Command Pro

    @ViewBuilder
    private var proSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: isPro ? "sparkles" : "wand.and.stars")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 48, height: 48)
                        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Command Pro")
                            .font(Typeface.display(20, .semibold))
                            .foregroundStyle(Palette.ink)
                        Text(proSummaryLine)
                            .font(Typeface.body(13))
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }

                if isPro {
                    HStack {
                        Label(proRenewalCallout, systemImage: "calendar.badge.clock")
                            .font(Typeface.body(15, .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Button {
                        sheet = .paywall
                    } label: {
                        Text("Start free trial")
                            .font(Typeface.body(15, .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                }

                HStack(spacing: 18) {
                    Button(app.subscription.restoring ? "Restoring…" : "Restore purchases") {
                        Task { _ = await app.subscription.restore(); await app.refreshEntitlement() }
                    }
                    .disabled(app.subscription.restoring)

                    if isPro {
                        Link("Manage subscription", destination: BillingConfig.manageSubscriptionsURL)
                    }
                }
                .font(Typeface.body(13, .medium))
                .frame(minHeight: 44)
            }
            .padding(18)
            .cardSurface()
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    private var proSummaryLine: String {
        if isPro { return proStatusText }
        let price = app.subscription.localizedPrice.map { "\($0)/month" }
            ?? app.entitlement?.priceDisplay ?? "Monthly subscription"
        // Same rule as the paywall: promise a trial only when StoreKit confirms eligibility.
        if let days = app.subscription.eligibleTrialDays, days > 0 {
            return "\(days)-day free trial · \(price) after"
        }
        return price
    }

    private var proRenewalCallout: String {
        guard let iso = app.entitlement?.expiresAt, let when = Self.formattedDate(iso) else {
            return "Subscription active"
        }
        return app.entitlement?.willRenew == true ? "Renews \(when)" : "Expires \(when)"
    }

    /// Pro per either the server entitlement or RevenueCat's local view (post-purchase).
    private var isPro: Bool {
        (app.entitlement?.active ?? false) || app.subscription.isSubscribed
    }

    private var proStatusText: String {
        guard let e = app.entitlement else { return app.subscription.isSubscribed ? "Active" : "—" }
        switch e.status {
        case "comp": return "Complimentary"
        case "active": return e.periodType == "trial" ? "Free trial" : "Active"
        case "grace": return "Active · update billing"
        case "expired": return "Expired"
        default: return app.subscription.isSubscribed ? "Active" : "Not subscribed"
        }
    }

    private static func formattedDate(_ iso: String) -> String? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return date?.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Device lock

    @ViewBuilder private var lockSection: some View {
        let hasPin = app.account.map { app.lock.hasPin(account: $0.id) } ?? false
        Section {
            Button(hasPin ? "Change Passcode" : "Set Passcode") { showSetPin = true }
            if hasPin {
                if app.lock.biometricAvailable {
                    Toggle("\(Biometrics.label) unlock", isOn: Binding(
                        get: { app.lock.biometricEnabled },
                        set: { app.lock.setBiometric($0) }))
                }
                Button("Turn Off Passcode", role: .destructive) {
                    if let id = app.account?.id { app.lock.removePin(account: id) }
                }
            }
        } header: {
            Text("Device lock")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("A passcode locks Command on this device whenever you leave the app. It's stored only on this device — never sent to the server.")
        }
    }

    /// Proactive briefings. Off until the user turns them on — the sub-options only appear
    /// once they have, so the section stays a single switch for anyone who doesn't want it.
    @ViewBuilder private var briefingsSection: some View {
        Section {
            Toggle("Daily briefing", isOn: Binding(
                get: { briefings?.enabled ?? false },
                set: { value in updateBriefings { $0.enabled = value } }))
            .disabled(briefings == nil)

            if briefings?.enabled == true {
                Picker("Days", selection: Binding(
                    get: { briefings?.cadence ?? "daily" },
                    set: { value in updateBriefings { $0.cadence = value } })) {
                        Text("Every day").tag("daily")
                        Text("Weekdays only").tag("weekdays")
                    }

                Picker("Time", selection: Binding(
                    get: { briefings?.hourLocal ?? 8 },
                    set: { value in updateBriefings { $0.hourLocal = value } })) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(Self.hourLabel(hour)).tag(hour)
                        }
                    }

                ForEach(BriefingPrefs.kindOrder, id: \.self) { kind in
                    Toggle(BriefingPrefs.label(for: kind), isOn: Binding(
                        get: { briefings?.kinds[kind] ?? true },
                        set: { value in updateBriefings { $0.kinds[kind] = value } }))
                }
            }

            if let briefingsError {
                Text(briefingsError).font(Typeface.body(13)).foregroundStyle(.red)
            }
        } header: {
            Text("Briefings").accessibilityAddTraits(.isHeader)
        } footer: {
            // The last sentence is not decoration: the server bounds delivery to a few hours
            // after the chosen time, so a briefing that misses its window is skipped rather
            // than arriving that night. Promising only "at the time you choose" would make
            // the skipped day look like a bug.
            Text("A short summary of what's on, what's overdue, who's blocked, and what's waiting to be triaged — at the time you choose, in your own timezone. Nothing is sent on a day with nothing to say, and nothing arrives hours late: if it misses that window, it waits for the next one.")
        }
        .task {
            guard briefings == nil else { return }
            briefings = try? await app.client.briefingPrefs()
        }
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Apply a preference change optimistically, then persist it — rolling back if the server
    /// refuses, so a switch never sits in a state the server doesn't actually hold.
    private func updateBriefings(_ mutate: (inout BriefingPrefs) -> Void) {
        guard var next = briefings else { return }
        let previous = next
        mutate(&next)
        briefings = next
        briefingsError = nil
        Task { [next] in
            do {
                briefings = try await app.client.updateBriefingPrefs(
                    BriefingPrefsPatch(
                        enabled: next.enabled, cadence: next.cadence,
                        hourLocal: next.hourLocal, kinds: next.kinds
                    )
                )
            } catch {
                briefings = previous
                briefingsError = "Couldn't save that — please try again."
            }
        }
    }

    #if DEBUG
    @ViewBuilder private var flagsSection: some View {
        Section {
            ForEach(FeatureFlag.allCases) { flag in
                Toggle(flag.label, isOn: Binding(
                    get: { app.flags.isOn(flag) },
                    set: { app.flags.set(flag, $0) }))
            }
        } header: {
            Text("Feature flags (debug)")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("In-progress features, off by default.")
        }
    }
    #endif

    // MARK: Token

    private func loadToken() async {
        loadingToken = true
        defer { loadingToken = false }
        token = try? await app.client.accessToken()
    }

    private func regenerate() async {
        token = try? await app.client.regenerateAccessToken()
    }

    // MARK: Account deletion

    /// The server verifies the password, deletes everything, and clears the session cookie. Only
    /// tear the local session down once it has actually succeeded — dropping to the sign-in screen
    /// on a failed attempt would look like it worked when it didn't.
    private func deleteAccount() {
        let password = deletePassword
        Task {
            deleting = true
            defer { deleting = false; deletePassword = "" }
            do {
                try await app.client.deleteAccount(password: password)
                await app.forgetDeletedAccount()
            } catch {
                deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
