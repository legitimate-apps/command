//
//  SetupContinuationView.swift
//  Command
//
//  The setup steps that come after a sign-in: "Add your AI key" (a self-hosted owner whose
//  server has no model key and can take one from the app) and the one-time "You're set"
//  tutorial. RootView shows this in place of the app while `AppState.setupStage` is set;
//  Account → Server can bring either back. Decisions live in `SetupFlow`.
//

import SwiftUI

struct SetupContinuationView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            Group {
                switch app.setupStage {
                case .aiKey: AIKeyPane()
                case .ready, nil: ReadyPane()
                }
            }
            .id(app.setupStage)
            .transition(reduceMotion ? .identity : .asymmetric(
                insertion: .offset(x: 44).combined(with: .opacity),
                removal: .offset(x: -44).combined(with: .opacity)))
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: app.setupStage)
    }
}

private extension AppState {
    var handoffPathForSetup: AgentHandoff.Path {
        SetupFlow.handoffPath(info: serverInfo, serverURL: serverURLString, chosen: chosenHosting)
    }
}

// MARK: - Add your AI key

private struct AIKeyPane: View {
    @Environment(AppState.self) private var app
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        OnboardingPane {
            PaneHeader(title: "Add your AI key",
                       lede: "The assistant runs on your own OpenRouter key.",
                       handoff: app.handoffPathForSetup)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    FieldCard(icon: "key", isActive: focused) {
                        SecureField("sk-or-…", text: $key)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit { Task { await save() } }
                            .accessibilityLabel("OpenRouter key")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { key = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .tint(Palette.accent)
                    .accessibilityLabel("Paste key")
                }

                Link(destination: ServerSetupGuide.openRouterKeysURL) {
                    Label("Get a key at openrouter.ai", systemImage: "arrow.up.right.square")
                        .font(Typeface.body(14, .semibold))
                }
                .tint(Palette.accent)

                Text("OpenRouter bills you for what the assistant uses. The key stays on your server — the app never keeps it.")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error {
                    ErrorBanner(message: error, retry: nil)
                }
            }
            .padding(.vertical, 16)
        } action: {
            VStack(spacing: 4) {
                PrimaryButton(title: saving ? "Checking key…" : "Save key", busy: saving,
                              enabled: !trimmed.isEmpty && !saving) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                QuietButton(title: "Skip for now") { app.skipAIKey() }
                    .disabled(saving)
            }
            .padding(.top, 12)
        }
    }

    private func save() async {
        guard !trimmed.isEmpty, !saving else { return }
        focused = false
        saving = true
        error = nil
        let result = await app.saveAIKey(trimmed)
        saving = false
        switch result {
        case .saved, .notApplicable:
            key = ""
            app.advanceSetup(from: .aiKey)
        case .failed(let message):
            error = message
        }
    }
}

// MARK: - You're set

private struct ReadyPane: View {
    @Environment(AppState.self) private var app

    private var cards: [TutorialCard] {
        let info = app.serverInfo
        let requiresSub = app.entitlement?.requiresSubscription ?? info?.assistantRequiresSubscription ?? false
        let unlocked = !requiresSub || (app.entitlement?.active ?? false) || app.subscription.isSubscribed
        return SetupFlow.tutorialCards(
            isCloud: SetupFlow.isCloud(info: info, serverURL: app.serverURLString),
            assistantUnlocked: unlocked,
            // Unknown (an older server) ⇒ assume it's configured, as the app always did.
            aiConfigured: info?.aiConfigured ?? true)
    }

    var body: some View {
        OnboardingPane {
            PaneHeader(title: "You're set",
                       lede: "Three things to try. Each one opens the right place.",
                       handoff: app.handoffPathForSetup)
        } content: {
            VStack(spacing: 12) {
                ForEach(cards) { card in
                    TutorialCardView(card: card) { app.finishSetup(then: card.action) }
                }
            }
            .padding(.vertical, 16)
        } action: {
            PrimaryButton(title: "Start using Command") { app.finishSetup() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 12)
        }
    }
}

private struct TutorialCardView: View {
    let card: TutorialCard
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: card.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 40, height: 40)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(Typeface.body(16, .semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(card.detail)
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(card.actionTitle)
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                    .font(Typeface.body(14, .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16, elevated: false)
    }
}
