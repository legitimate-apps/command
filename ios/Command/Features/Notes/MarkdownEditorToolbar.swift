//
//  MarkdownEditorToolbar.swift
//  Command
//
//  The note editor's formatting chrome. Implements §3 of
//  docs/design/2026-07-21-markdown-editor-design.md.
//
//  One bar, three form factors — the item set and order are identical everywhere so muscle memory
//  transfers between a phone and the Mac; only density and presentation change:
//   - iPhone: horizontally scrollable strip, 44pt touch targets, with a pinned dismiss-keyboard
//     button that never scrolls out of thumb reach.
//   - iPad: the same items, non-scrolling and centred (there's room), plus the indent pair.
//   - Mac Catalyst: pointer-scaled (28pt targets, 15pt icons), always visible — there is no
//     software keyboard to ride above, so the bar is simply part of the editor.
//
//  It is hosted in a `safeAreaInset(edge: .bottom)` rather than `ToolbarItemGroup(.keyboard)`:
//  the keyboard placement doesn't exist on Mac Catalyst, and one host for all three platforms
//  beats three divergent code paths for chrome this simple.
//

import SwiftUI

struct MarkdownEditorToolbar: View {
    let controller: MarkdownEditorController
    /// True while the editor has focus. On iPhone/iPad the bar rides above the keyboard and the
    /// dismiss button is meaningful; on Mac it's shown regardless.
    let isFocused: Bool
    var onDismissKeyboard: () -> Void

    @Environment(\.horizontalSizeClass) private var hSize

    /// Pointer-driven platforms get denser, smaller controls; touch keeps 44pt targets.
    private var isPointerScaled: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private var target: CGFloat { isPointerScaled ? 28 : 44 }
    private var iconSize: CGFloat { isPointerScaled ? 15 : 17 }

    var body: some View {
        HStack(spacing: 0) {
            if isPointerScaled || hSize == .regular {
                // Room to show everything at once — centre it as one group.
                HStack(spacing: isPointerScaled ? 4 : 8) { groups }
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) { groups }
                        .padding(.horizontal, 4)
                }
            }

            if !isPointerScaled {
                Divider().frame(height: 24)
                button("keyboard.chevron.compact.down",
                       label: "Dismiss keyboard",
                       hint: nil,
                       tinted: true) { onDismissKeyboard() }
            }
        }
        .padding(.horizontal, isPointerScaled ? 10 : 2)
        .frame(height: target + (isPointerScaled ? 8 : 0))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
    }

    /// The item order from the design spec: lists first (quick capture is tasks and bullets),
    /// then emphasis, then block structure, then insertions.
    @ViewBuilder
    private var groups: some View {
        button("checklist", label: "Task", hint: "Inserts or toggles a checkbox line") {
            controller.toggleLinePrefix("- [ ] ")
        }
        button("list.bullet", label: "Bulleted list", hint: "Formats the line as a bullet") {
            controller.toggleLinePrefix("- ")
        }
        button("list.number", label: "Numbered list", hint: "Formats the line as a numbered item") {
            controller.toggleLinePrefix("1. ")
        }
        if isPointerScaled || hSize == .regular {
            button("increase.indent", label: "Indent", hint: "Increases the list nesting level") {
                controller.indent(by: 1)
            }
            button("decrease.indent", label: "Outdent", hint: "Decreases the list nesting level") {
                controller.indent(by: -1)
            }
        }

        separator

        button("bold", label: "Bold", hint: "Toggles bold on the selection") {
            controller.toggleWrap("**")
        }
        button("italic", label: "Italic", hint: "Toggles italic on the selection") {
            controller.toggleWrap("*")
        }
        button("strikethrough", label: "Strikethrough", hint: "Toggles strikethrough on the selection") {
            controller.toggleWrap("~~")
        }

        separator

        headingMenu
        button("quote.opening", label: "Quote", hint: "Formats the line as a block quote") {
            controller.toggleLinePrefix("> ")
        }
        button("chevron.left.forwardslash.chevron.right",
               label: "Code", hint: "Toggles inline code on the selection") {
            controller.toggleWrap("`")
        }

        separator

        button("link", label: "Insert link", hint: "Adds a link to the selection") {
            controller.insertLink()
        }
        if isPointerScaled {
            button("tablecells", label: "Insert table", hint: "Adds a three-by-three table") {
                controller.insertTable()
            }
        }
    }

    private var separator: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, isPointerScaled ? 4 : 6)
    }

    /// Heading levels live in a menu rather than three buttons: a notes app uses H1–H3 rarely
    /// enough that three permanent slots would crowd out the list and emphasis controls people
    /// press constantly.
    private var headingMenu: some View {
        Menu {
            Button("Heading 1") { controller.setHeading(1) }
            Button("Heading 2") { controller.setHeading(2) }
            Button("Heading 3") { controller.setHeading(3) }
            Divider()
            Button("Body") { controller.setHeading(0) }
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: target, height: target)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Heading")
        .accessibilityHint("Opens heading level options")
    }

    private func button(_ symbol: String,
                        label: String,
                        hint: String?,
                        tinted: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(tinted ? Palette.accent : Palette.inkSecondary)
                .frame(width: target, height: target)
                .contentShape(Rectangle())
        }
        .buttonStyle(MarkdownToolbarButtonStyle(cornerRadius: isPointerScaled ? 6 : 8))
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

/// Pressed state per the spec: an `accentSoft` fill flashes under the icon. Kept as a style so
/// hover (Mac/iPad pointer) and press share one visual language.
private struct MarkdownToolbarButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.accentSoft)
                    .opacity(configuration.isPressed ? 1 : (hovering ? 0.6 : 0))
            )
            .animation(.easeOut(duration: 0.06), value: hovering)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
