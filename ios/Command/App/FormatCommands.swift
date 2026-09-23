//
//  FormatCommands.swift
//  Command
//
//  The Mac menu bar's Format menu for the Markdown note editor.
//
//  The editor already answers ⌘B/⌘I/⌘E/⌘K/⇧⌘X/⇧⌘T through `MarkdownUITextView.keyCommands`, and
//  the on-screen formatting bar exposes the same actions — but neither puts them in the menu bar,
//  which is where a Mac user looks for (and discovers) text formatting. This publishes the focused
//  editor's controller as a scene focused-value so the menu can drive it: items enable only while a
//  note editor actually has focus, and dispatch to exactly the same controller methods the toolbar
//  buttons and key commands use — one implementation, three entry points.
//
//  Focused values (rather than a responder-chain `UIMenuBuilder` override) keep this in SwiftUI and
//  keep the menu correctly greyed out when no editor is focused, so the shortcuts still fall
//  through to the text view when the menu is inactive.
//
//  Empirical note (macOS 26, found by bisecting probe menus): this content must live in the app's
//  existing `CommandMenus` and be shaped like its working Go menu. A *second* `Commands` struct
//  carrying it compiled and linked but SwiftUI silently dropped its menu from the Catalyst menu bar
//  — a trivial one-button menu from that same struct DID appear, so the second `Commands` value
//  installs fine and the content is what got dropped. `FormatAction` is likewise a plain,
//  non-`@MainActor` type, exactly like the `AppDestination` the Go menu iterates; only the action
//  closure is main-actor isolated, because the editor controller is.
//

import SwiftUI

private struct MarkdownControllerFocusKey: FocusedValueKey {
    typealias Value = MarkdownEditorController
}

extension FocusedValues {
    /// The Markdown editor controller of the note editor that currently has focus, if any.
    var markdownEditor: MarkdownEditorController? {
        get { self[MarkdownControllerFocusKey.self] }
        set { self[MarkdownControllerFocusKey.self] = newValue }
    }
}

/// One Format-menu entry: a title, an optional shortcut, and what it does to the editor.
struct FormatAction: Identifiable {
    let id: String
    let title: String
    let key: KeyEquivalent?
    let modifiers: EventModifiers
    let run: @MainActor (MarkdownEditorController) -> Void

    init(_ id: String, _ title: String, key: KeyEquivalent? = nil,
         modifiers: EventModifiers = .command,
         run: @escaping @MainActor (MarkdownEditorController) -> Void) {
        self.id = id
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.run = run
    }

    /// Character-level marks — the ones with the classic ⌘ shortcuts.
    static let inline: [FormatAction] = [
        FormatAction("bold", "Bold", key: "b") { $0.toggleWrap("**") },
        FormatAction("italic", "Italic", key: "i") { $0.toggleWrap("*") },
        FormatAction("strike", "Strikethrough", key: "x", modifiers: [.command, .shift]) { $0.toggleWrap("~~") },
        // No menu shortcut for Code. ⌘E is macOS's standard Edit ▸ Find ▸ "Use Selection for Find",
        // and a CommandMenu item that collides with a system shortcut makes Catalyst silently drop
        // the ENTIRE menu (bisected on macOS 26: removing just this one item brought Format back).
        // The editor still answers ⌘E — that binding lives on the text view's `keyCommands`, which
        // is a responder-chain command and unaffected by the menu.
        FormatAction("code", "Code") { $0.toggleWrap("`") },
        FormatAction("link", "Link…", key: "k") { $0.insertLink() },
    ]

    /// Line- and block-level structure.
    static let blocks: [FormatAction] = [
        FormatAction("h1", "Heading 1") { $0.setHeading(1) },
        FormatAction("h2", "Heading 2") { $0.setHeading(2) },
        FormatAction("h3", "Heading 3") { $0.setHeading(3) },
        FormatAction("body", "Body Text") { $0.setHeading(0) },
        FormatAction("task", "Task", key: "t", modifiers: [.command, .shift]) { $0.toggleTask() },
        FormatAction("bullet", "Bulleted List") { $0.toggleLinePrefix("- ") },
        FormatAction("number", "Numbered List") { $0.toggleLinePrefix("1. ") },
        FormatAction("quote", "Block Quote") { $0.toggleLinePrefix("> ") },
        FormatAction("codeblock", "Code Block") { $0.insertCodeBlock() },
        FormatAction("table", "Table") { $0.insertTable() },
    ]

    static let indentation: [FormatAction] = [
        FormatAction("indent", "Indent", key: "]") { $0.indent(by: 1) },
        FormatAction("outdent", "Outdent", key: "[") { $0.indent(by: -1) },
    ]
}
