//
//  OnboardingComponents.swift
//  Command
//
//  The building blocks every setup screen shares — the welcome, the self-host guide, the
//  account step, "Add your AI key", "You're set" and the agent hand-off — so they read as one
//  flow: ink on paper, one accent, a top bar with Back on the leading edge and "Hand to AI" on
//  the trailing edge, a header, centred content, and one anchored action.
//

import SwiftUI
import UIKit

/// The one action style across the flow: a full-width button that is either the accent-filled
/// primary or its quiet surface-bound twin. Prominence is a state, never a gate — a muted
/// button still works (someone whose server is already running must be able to skip ahead).
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent = true
    var busy = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(prominent ? .white : Palette.ink) }
                if let systemImage, !busy {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title).font(Typeface.body(16, .semibold))
            }
            .foregroundStyle(prominent ? .white : Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)   // min, not fixed — grows with Dynamic Type instead of clipping
            .padding(.vertical, 4)
            .background(prominent ? Palette.accent : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                }
            }
            .opacity(enabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A quiet text button for the secondary choice under a primary one ("Skip", "Not now").
struct QuietButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.body(15, .semibold))
                .foregroundStyle(Palette.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BackButton: View {
    var title: String = "Back"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
                .font(Typeface.body(15, .semibold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.inkSecondary)
    }
}

/// A short value statement: semibold claim, one quiet line of detail.
struct ValueLine: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typeface.body(15, .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A copyable command. Copying matters more than it looks — the alternative is retyping a
/// `docker run` line from a phone screen onto a laptop.
struct CommandBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                // A command with no natural break point (a bare URL) truncates with an
                // ellipsis inside the HStack instead of wrapping — the user can't read what
                // they're about to copy. Claim the height the wrap needs.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = text
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Palette.sage : Palette.inkSecondary)
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline)
        )
    }
}

// MARK: - The pane container

/// The one vertical rhythm of the whole flow: header anchored top, action anchored
/// bottom, and the pane's substance centred in the space left between. Leftover space
/// splits above and below the content instead of lumping at the bottom, so a sparse
/// pane reads as composed rather than unfinished. A dense pane (the guide) fills the
/// space and is unchanged; an over-tall one (short screens, accessibility2 type)
/// scrolls rather than clipping. Every pane is built from this container — they
/// differ only in what they put in the three slots.
struct OnboardingPane<Header: View, Content: View, Action: View>: View {
    /// Where content rests in leftover space. `.center` splits it above and below.
    /// `.bottom` settles the content low, leaving the space open above — the welcome
    /// pane's deliberate window for the backdrop's rings.
    enum ContentPlacement { case center, bottom }

    let placement: ContentPlacement
    let header: Header
    let content: Content
    let action: Action

    init(placement: ContentPlacement = .center,
         @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content,
         @ViewBuilder action: () -> Action) {
        self.placement = placement
        self.header = header()
        self.content = content()
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            GeometryReader { geo in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, minHeight: geo.size.height,
                               alignment: placement == .center ? .center : .bottom)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            action
        }
    }
}

/// The top row of every setup screen: Back (when there is somewhere to go back to) on the
/// leading edge, "Hand to AI" on the trailing edge. Fixed at 44pt so panes line up.
struct OnboardingTopBar: View {
    var backTitle = "Back"
    var onBack: (() -> Void)?
    var handoff: AgentHandoff.Path?

    var body: some View {
        HStack(spacing: 12) {
            if let onBack { BackButton(title: backTitle, action: onBack) }
            Spacer(minLength: 0)
            if let handoff { HandoffButton(path: handoff) }
        }
        .frame(minHeight: 44)
    }
}

/// The anchored top of a pane: the top bar, title, and (where given) the one-line lede.
struct PaneHeader: View {
    let title: String
    var lede: String? = nil
    var backTitle = "Back"
    var onBack: (() -> Void)?
    var handoff: AgentHandoff.Path? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingTopBar(backTitle: backTitle, onBack: onBack, handoff: handoff)
            Text(title)
                .font(Typeface.display(26))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let lede {
                Text(lede)
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }
}

/// The app mark shared by the welcome, sign-in and "You're set" screens.
struct BrandMark: View {
    var size: CGFloat = 80

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(Palette.accentSoft)
                .frame(width: size, height: size)
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: size * 0.475, weight: .medium))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
        }
    }
}

/// A tappable choice: icon, title, detail, optional badge and trade-off line, chevron.
struct ChoiceCard: View {
    let systemImage: String
    let title: String
    let detail: String
    var badge: String? = nil
    var footnote: String? = nil
    var emphasized = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 30)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    // Title and badge share a line when they fit; at large Dynamic Type the
                    // badge drops below rather than truncating either.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            titleText.fixedSize()
                            badgeView
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            titleText.fixedSize(horizontal: false, vertical: true)
                            badgeView
                        }
                    }
                    Text(detail)
                        .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let footnote {
                        // The trade-off rides on the card so it is read before the choice,
                        // not discovered after it.
                        Text(footnote)
                            .font(Typeface.body(13)).foregroundStyle(Palette.inkSecondary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Flat: inside a ScrollView an elevated card's shadow is clipped into a grey band.
            // The recommended choice is marked by its accent border instead.
            .cardSurface(cornerRadius: 16, elevated: false)
            .overlay {
                if emphasized {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var titleText: some View {
        Text(title).font(Typeface.body(16, .semibold)).foregroundStyle(Palette.ink)
    }

    @ViewBuilder private var badgeView: some View {
        if let badge {
            Text(badge)
                .font(Typeface.body(11, .semibold))
                .foregroundStyle(Palette.accent)
                .fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Palette.accentSoft, in: Capsule())
        }
    }
}

// MARK: - Hand to your AI agent

extension EnvironmentValues {
    /// The server address hand-off briefs should use beneath this view; nil = the app's current
    /// server. Onboarding sets "" — someone choosing a server isn't describing the current one.
    @Entry var handoffServerURL: String? = nil
}

/// The top-bar button on every setup screen (and in Account → Server). Opens the hand-off sheet.
struct HandoffButton: View {
    let path: AgentHandoff.Path
    /// Overrides the server address in the brief (nil = the environment's, else the app's).
    var serverURL: String? = nil
    @Environment(\.handoffServerURL) private var environmentServerURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 13, weight: .semibold))
                // At accessibility sizes the label would crowd the top bar; the icon stays,
                // and VoiceOver still reads the full label below.
                if !typeSize.isAccessibilitySize {
                    Text("Hand to AI")
                        .font(Typeface.body(13, .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Palette.accentSoft, in: Capsule())
            .frame(minHeight: 44)          // full-size hit target around the compact chip
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Hand setup to your AI agent")
        .accessibilityHint("Shows setup instructions you can copy into Claude, ChatGPT or another AI agent")
        .sheet(isPresented: $showing) {
            AgentHandoffSheet(path: path, serverURL: serverURL ?? environmentServerURL).macSheet(.page)
        }
    }
}

/// What the hand-off does, a preview of the text, and one CTA: copy it (share as the second).
struct AgentHandoffSheet: View {
    let path: AgentHandoff.Path
    var serverURL: String? = nil

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    private var text: String {
        AgentHandoff.instructions(path: path, serverURL: serverURL ?? app.serverURLString)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Copies complete setup instructions you can paste into Claude, ChatGPT, or another AI agent — it can walk you through or do the setup for you.")
                        .font(Typeface.body(15))
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
                    .accessibilityLabel("Instructions preview")

                    VStack(spacing: 10) {
                        PrimaryButton(title: copied ? "Copied" : "Copy instructions",
                                      systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = text
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copied = true }
                            UIAccessibility.post(notification: .announcement, argument: "Instructions copied")
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copied = false }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        ShareLink(item: text, subject: Text("Set up Command"),
                                  message: Text("Setup instructions for Command")) {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 15, weight: .semibold))
                                    .accessibilityHidden(true)
                                Text("Share").font(Typeface.body(16, .semibold))
                            }
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .padding(.vertical, 4)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(maxWidth: 620)
            }
            .navigationTitle("Hand to your AI agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).fixedSize()
                }
            }
            .tint(Palette.accent)
        }
    }
}
