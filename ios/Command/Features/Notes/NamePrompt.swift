//
//  NamePrompt.swift
//  Command
//
//  A small custom naming dialog (not a system alert) used when duplicating a note.
//  A dimmed backdrop + a paper card with an inline text field that has an xmark to
//  clear it in one tap, and Cancel / Create actions.
//

import SwiftUI

struct NamePrompt: View {
    let prompt: String
    let defaultName: String
    let confirmTitle: String
    @Binding var isPresented: Bool
    let onCreate: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    init(prompt: String, defaultName: String, confirmTitle: String = "Create",
         isPresented: Binding<Bool>, onCreate: @escaping (String) -> Void) {
        self.prompt = prompt
        self.defaultName = defaultName
        self.confirmTitle = confirmTitle
        self._isPresented = isPresented
        self.onCreate = onCreate
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 16) {
                Text(prompt)
                    .font(Typeface.display(20))
                    .foregroundStyle(Palette.ink)

                HStack(spacing: 8) {
                    TextField("Name", text: $text)
                        .font(Typeface.body(16))
                        .foregroundStyle(Palette.ink)
                        .focused($focused)
                        .submitLabel(.done)
                        .autocorrectionDisabled(false)
                        .onSubmit(create)
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Palette.inkSecondary.opacity(0.55))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(focused ? Palette.accent.opacity(0.6) : Palette.hairline, lineWidth: 1)
                )

                HStack(spacing: 12) {
                    Button { close() } label: {
                        Text("Cancel")
                            .font(Typeface.body(16, .medium))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)
                            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Palette.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: create) {
                        Text(confirmTitle)
                            .font(Typeface.body(16, .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)
                            .background(Palette.accent.opacity(trimmed.isEmpty ? 0.4 : 1),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmed.isEmpty)
                }
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 32, x: 0, y: 14)
            .padding(28)
        }
        .onAppear {
            text = defaultName
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true }
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        close()
    }

    private func close() {
        focused = false
        isPresented = false
    }
}
