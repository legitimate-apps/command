//
//  FieldCard.swift
//  Command
//
//  The app's standard bordered input row — surface fill, hairline border, an
//  optional leading icon, and an amber focus highlight. This is the chrome the
//  platform's `.textFieldStyle(.roundedBorder)` fails to draw legibly on macOS
//  Catalyst (where bare fields read as floating placeholder text). Wrap any
//  TextField / SecureField; drive `isActive` from the caller's `@FocusState`.
//

import SwiftUI

struct FieldCard<Content: View>: View {
    var icon: String? = nil
    var isActive: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 11) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isActive ? Palette.accent : Palette.inkSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            content
                .textFieldStyle(.plain)
                .font(Typeface.body(15))
                .foregroundStyle(Palette.ink)
                .tint(Palette.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? Palette.accent.opacity(0.85) : Palette.hairline,
                              lineWidth: isActive ? 1.6 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}
