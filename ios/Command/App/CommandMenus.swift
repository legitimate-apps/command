//
//  CommandMenus.swift
//  Command
//
//  The Mac menu bar (and the iPad hardware-keyboard ⌘-HUD) for Command. Each
//  item posts an intent on the AppCommandBus; the shell turns intents into
//  navigation + actions. On the compact iPhone path these commands are simply
//  never surfaced (no menu bar / external keyboard menu), so behavior there is
//  unchanged.
//

import SwiftUI

struct CommandMenus: Commands {
    let bus: AppCommandBus
    /// The note editor that currently has focus, published by NoteDetailView. Nil elsewhere, which
    /// is exactly what greys the Format menu out.
    @FocusedValue(\.markdownEditor) private var editor

    var body: some Commands {
        // File ▸ New … + Quick Capture
        CommandGroup(replacing: .newItem) {
            Button("New Note") { bus.send(.newNote) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Assignment") { bus.send(.newAssignment) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Chat") { bus.send(.newChat) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Quick Capture") { bus.send(.capture) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        // A dedicated "Go" menu: ⌘1…⌘5 to the five sections + Refresh.
        CommandMenu("Go") {
            ForEach(AppDestination.primary) { dest in
                Button(dest.title) { bus.send(.go(dest)) }
                    .keyboardShortcut(dest.keyEquivalent, modifiers: .command)
            }
            Divider()
            Button("Refresh") { bus.send(.refresh) }
                .keyboardShortcut("r", modifiers: .command)
        }

        // Format ▸ … drives the focused Markdown note editor. The same actions back the on-screen
        // formatting bar and the text view's own ⌘-key commands, so all three call one implementation.
        CommandMenu("Format") {
            ForEach(FormatAction.inline) { formatItem($0) }
            Divider()
            ForEach(FormatAction.blocks) { formatItem($0) }
            Divider()
            ForEach(FormatAction.indentation) { formatItem($0) }
        }

        // Edit ▸ Find, Spelling and Grammar, Substitutions, Transformations, Speech. SwiftUI adds
        // these only when asked. Find ▸ Find… is ⌘F, handled by `CommandAppDelegate.find(_:)`; a
        // "Find" command of our own with the same shortcut conflicts with it and UIKit drops it.
        TextEditingCommands()

        // The standard App ▸ Settings… slot (⌘,). Opens Account, which is the app's
        // settings surface; the split shell presents it as a sheet.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { bus.send(.go(.account)) }
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    @ViewBuilder
    private func formatItem(_ action: FormatAction) -> some View {
        let button = Button(action.title) { if let editor { action.run(editor) } }
            .disabled(editor == nil)
        if let key = action.key {
            button.keyboardShortcut(key, modifiers: action.modifiers)
        } else {
            button
        }
    }
}

extension AppDestination {
    /// The ⌘-key for this section (⌘1…⌘5); falls back to "0" for `account`,
    /// which never appears in the Go menu.
    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character("\(shortcutNumber ?? 0)"))
    }
}
