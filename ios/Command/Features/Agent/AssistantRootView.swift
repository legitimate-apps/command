//
//  AssistantRootView.swift
//  Command
//
//  The Assistant tab's entry point. It owns the access gate so AgentChatView stays
//  a pure chat surface: while the entitlement is unknown it shows a spinner; if the
//  user hasn't consented to AI use it shows the consent screen; if the server is
//  gating on a subscription and they aren't entitled it shows the paywall; otherwise
//  the live chat. The gate recomputes automatically as consent / subscription change.
//

import SwiftUI

struct AssistantRootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.navigator) private var nav
    /// The self-heal fetch failed. Without this the tab spun forever on a phone, whose only
    /// other retry (⌘R) needs a hardware keyboard.
    @State private var loadFailed = false

    var body: some View {
        content
            // ⌘⌥N / "New Chat" from the Mac/iPad menu starts a fresh conversation. `initial: true`
            // so a cross-section ⌘⌥N (show(.assistant) mounts this view fresh with the flag already
            // set) still consumes it — plain onChange skips the value present at mount.
            .onChange(of: nav?.startNewChat, initial: true) { _, want in
                if want == true { app.agent.newChat(); nav?.startNewChat = false }
            }
    }

    @ViewBuilder private var content: some View {
        switch app.assistantGateResolved {
        case .loading: loading
        case .consent: AIConsentView()
        case .paywall: PaywallView()
        case .ready:   AgentChatView()
        }
    }

    private var loading: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if loadFailed {
                ErrorBanner(message: "Couldn't reach the assistant. Check your connection and try again.") {
                    Task { await load() }
                }
                .padding(24)
            } else {
                ProgressView().controlSize(.large).tint(Palette.accent)
            }
        }
        // Self-heal if the entitlement didn't load at sign-in (e.g. a transient
        // network failure) so the tab doesn't get stuck on the spinner.
        .task { if app.entitlement == nil { await load() } }
    }

    private func load() async {
        loadFailed = false
        loadFailed = !(await app.refreshEntitlement())
    }
}
