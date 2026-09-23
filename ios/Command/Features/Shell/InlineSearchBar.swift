//
//  InlineSearchBar.swift
//  Command
//
//  A search field that is HIDDEN until revealed — the list shows a 🔍 toolbar
//  button, and only when tapped (or ⌘F) does this bar slide in. Unlike SwiftUI's
//  `.searchable`, the field is never persistently visible. Cancel hides it again
//  and clears the query. Autofocuses on appear.
//

import SwiftUI

struct InlineSearchBar: View {
    @Binding var text: String
    var prompt: String
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .accessibilityLabel(prompt)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.inkSecondary.opacity(0.55))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .cardSurface(cornerRadius: 12, elevated: false)   // fill + hairline edge, no heavy shadow — reads as a crisp native field

            Button("Cancel") {
                text = ""
                onCancel()
            }
            .font(Typeface.body(15))
            .tint(Palette.accent)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .keyboardShortcut(.cancelAction)   // Esc dismisses (Mac / hardware keyboard)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear { focused = true }
    }
}
