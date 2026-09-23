//
//  CommandEmptyState.swift
//  Command
//
//  The shared empty-state component. Centralises the app's empty-state language:
//  a large decorative icon (hidden from VoiceOver), a serif headline, an ink-secondary
//  message, and an optional capsule accent action. Centers itself in the available space
//  and scales with Dynamic Type.
//

import SwiftUI

struct CommandEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionLabel: String? = nil
    var actionIcon: String? = "plus"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Palette.inkSecondary.opacity(0.55))
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.display(22))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionLabel, let action {
                Button(action: action) {
                    Label(actionLabel, systemImage: actionIcon ?? "plus")
                        .font(Typeface.body(15, .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    CommandEmptyState(
        icon: "tray",
        title: "Nothing jotted yet",
        message: "Capture a quick thought on the Calendar tab — typed or spoken — or start a longer one here.",
        actionLabel: "New note"
    ) {}
    .background(Palette.paper)
}
