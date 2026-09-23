//
//  AIConsentView.swift
//  Command
//
//  The one-time AI-disclosure consent gate shown before the assistant's first use.
//  Apple requires disclosing AI use and getting consent before a user's data is sent
//  to a third-party model; the assistant reads the user's notes/people/tasks, so this
//  must precede any run. Tapping "I Agree" records consent server-side (idempotent);
//  the Assistant tab's gate then reveals the chat. Same paper-and-ink language as the
//  rest of the app.
//

import SwiftUI

struct AIConsentView: View {
    @Environment(AppState.self) private var app
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    mark
                    VStack(spacing: 8) {
                        Text("Before we begin")
                            .font(Typeface.display(28))
                            .foregroundStyle(Palette.ink)
                        Text("Command's planning assistant is powered by AI.")
                            .font(Typeface.body(16))
                            .foregroundStyle(Palette.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    disclosures
                    legal
                }
                .padding(.horizontal, 22)
                .padding(.top, 36)
                .padding(.bottom, 24)
                // Cap + center on a wide iPad/Mac canvas instead of stretching edge to edge.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) { agreeBar }
        }
    }

    private var mark: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(Palette.accent)
            .accessibilityHidden(true)
            .frame(width: 76, height: 76)
            .background(Palette.accentSoft, in: Circle())
            .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var disclosures: some View {
        VStack(spacing: 0) {
            DisclosureRow(
                icon: "lock.rotation",
                title: "Your data helps it answer you",
                detail: "When you chat with the assistant, the notes, people, and tasks it needs are sent through OpenRouter to the model you pick — from Anthropic, OpenAI, Z.ai, or Moonshot AI."
            )
            Divider().overlay(Palette.hairline).padding(.leading, 52)
            DisclosureRow(
                icon: "textformat.abc",
                title: "It also titles your notes",
                detail: "Leave a note untitled and the opening lines go the same way, to a small model from Alibaba, for a two- or three-word title. Decline and notes keep their first line instead."
            )
            Divider().overlay(Palette.hairline).padding(.leading, 52)
            DisclosureRow(
                icon: "hand.raised.slash",
                title: "Never sold, not used for training",
                detail: "Your data is processed only to answer you. It isn't sold, and we route only to providers whose terms say they don't train on what's submitted."
            )
            Divider().overlay(Palette.hairline).padding(.leading, 52)
            DisclosureRow(
                icon: "checkmark.shield",
                title: "You're in control",
                detail: "You can decline and keep using the rest of Command. Responses are AI-generated, so double-check anything important."
            )
        }
        .padding(.vertical, 4)
        .cardSurface(cornerRadius: 18)
    }

    private var legal: some View {
        VStack(spacing: 6) {
            Text("By continuing you agree to our")
                .font(Typeface.body(13))
                .foregroundStyle(Palette.inkSecondary)
            HStack(spacing: 4) {
                Link("Terms", destination: BillingConfig.termsURL)
                Text("and").foregroundStyle(Palette.inkSecondary)
                Link("Privacy Policy", destination: BillingConfig.privacyURL)
            }
            .font(Typeface.body(13, .medium))
            .tint(Palette.accent)
        }
        .padding(.top, 2)
    }

    private var agreeBar: some View {
        VStack(spacing: 10) {
            if let error {
                Text(error)
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
            }
            Button(action: agree) {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small).tint(.white) }
                    Text(working ? "Saving…" : "I Agree & Continue")
                        .font(Typeface.body(17, .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(working)
            Text("You can use the rest of Command without the assistant.")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Palette.paper)
    }

    private func agree() {
        working = true
        error = nil
        Task {
            let ok = await app.recordConsent()
            working = false
            if !ok { error = "Couldn't save your consent. Check your connection and try again." }
            // On success the entitlement updates and the tab's gate reveals the chat.
        }
    }
}

/// One labeled disclosure line (icon + title + explanation).
private struct DisclosureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typeface.body(15, .semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(Typeface.body(13.5))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}
