//
//  AdaptiveRootView.swift
//  Command
//
//  The signed-in shell, adaptive to size class. On a regular-width canvas (iPad, or a wide
//  iPad multitasking split) and with the `ipadLayout` flag on, it presents a sidebar +
//  detail `NavigationSplitView`; on compact width (iPhone, Slide Over) — or whenever the flag
//  is off — it falls back to the exact `MainTabView` that ships today. Each destination keeps
//  its own `NavigationStack`, which is the intended content of a split-view detail column.
//

import SwiftUI

struct AdaptiveRootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        #if targetEnvironment(macCatalyst)
        // On the Mac the shell is ALWAYS the three-column split — a Mac window is never a
        // phone, and NavigationSplitView collapses to a single column on its own when the
        // window is narrow. Driving the choice off the size class here was a bug: during the
        // window's brief compact-width moment at launch/resize, Catalyst built `MainTabView`
        // (the iPhone tab bar), then swapped to `SplitRootView` once the window reached regular
        // width — but Catalyst doesn't tear the outgoing branch down cleanly, so the tab-bar
        // layout lingered as a faint full-width ghost layer behind the split shell. Pinning the
        // split view removes `MainTabView` from the Mac tree entirely, so no swap, no ghost.
        SplitRootView()
        #else
        if app.flags.isOn(.ipadLayout) && hSize == .regular {
            SplitRootView()
        } else {
            MainTabView()
        }
        #endif
    }
}

/// The app's destinations. The five planning sections are shared by the tab bar
/// (compact) and the sidebar (regular); `account` is reachable from both but is
/// not one of the primary sections (it opens as a sheet on iPad, Preferences on Mac).
enum AppDestination: Int, CaseIterable, Identifiable {
    case calendar, notes, assistant, tasks, people, account
    var id: Int { rawValue }

    /// The five primary sections, in sidebar/tab order. Excludes `account`.
    static var primary: [AppDestination] { [.calendar, .notes, .assistant, .tasks, .people] }

    /// Sections whose list has a search field for ⌘F to reveal.
    var hasListSearch: Bool { self == .notes || self == .tasks || self == .people }

    var title: String {
        switch self {
        case .calendar:  return "Calendar"
        case .notes:     return "Notes"
        case .assistant: return "Assistant"
        case .tasks:     return "Tasks"
        case .people:    return "People"
        case .account:   return "Account"
        }
    }
    var icon: String {
        switch self {
        case .calendar:  return "calendar"
        case .notes:     return "note.text"
        case .assistant: return "sparkles"
        case .tasks:     return "checklist"
        case .people:    return "person.2"
        case .account:   return "person.crop.circle"
        }
    }

    /// ⌘1…⌘5 for the five planning sections; nil for account.
    var shortcutNumber: Int? {
        switch self {
        case .calendar:  return 1
        case .notes:     return 2
        case .assistant: return 3
        case .tasks:     return 4
        case .people:    return 5
        case .account:   return nil
        }
    }
}

/// The regular-width (iPad / Mac) shell: a three-column NavigationSplitView —
/// sidebar (sections + Account) · content (the section's list/canvas) · detail
/// (the current selection). A single `Navigator` in the environment ties the
/// columns together and is the target of the Mac/iPad menu commands.
private struct SplitRootView: View {
    @Environment(AppState.self) private var app
    @Environment(AppCommandBus.self) private var bus
    @State private var navigator = Navigator()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showAccount = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding<AppDestination?>(
                get: { navigator.destination },
                // Account is a sheet, not a section: opening it must NOT switch `destination`,
                // else the content column flashes Calendar behind the sheet, the sidebar highlight
                // bounces, and on dismiss you lose the section you were on. Keep destination put and
                // just raise the sheet; the sidebar keeps highlighting your real section.
                set: { newValue in
                    guard let dest = newValue else { return }
                    if dest == .account { showAccount = true } else { navigator.show(dest) }
                }
            )) {
                ForEach(AppDestination.primary) { dest in
                    Label(dest.title, systemImage: dest.icon).tag(dest)
                }
                Section {
                    Label(AppDestination.account.title,
                          systemImage: AppDestination.account.icon)
                        .tag(AppDestination.account)
                }
            }
            .navigationTitle("Command")
            .tint(Palette.accent)
        } content: {
            // Give the list/canvas column a comfortable width. Without this the middle column
            // stayed ~330pt and ALL extra window width went to the (often empty) detail column —
            // so note/task/people cards truncated their titles and dates ("Sat, Jul 4…") even in a
            // wide window. A 420pt ideal lets the cards breathe while staying user-resizable.
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 360, ideal: 420, max: 640)
        } detail: {
            DetailColumn()
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Palette.accent)
        .environment(navigator)              // typed — read by the column views
        .environment(\.navigator, navigator) // optional — read by the shared list views
        .onChange(of: bus.tick) { _, _ in handle(bus.last) }
        // App Intents ("Open Command …") route through the sticky ShortcutNavigation bridge.
        .onChange(of: ShortcutNavigation.shared.tick) { _, _ in drainShortcutNavigation() }
        .onAppear { drainShortcutNavigation() }
        .sheet(isPresented: $showAccount) {
            AccountView().macSheet(.page)
        }
        #if DEBUG
        // Screenshot hook: mirror MainTabView's `-COMMAND_START_TAB` so the split
        // shell can land on a section (its NotesView/etc. then honors COMMAND_PREVIEW_SEARCH).
        .onAppear {
            if let tab = UserDefaults.standard.string(forKey: "COMMAND_START_TAB") {
                let map: [String: AppDestination] = ["calendar": .calendar, "notes": .notes,
                    "assistant": .assistant, "agent": .assistant, "tasks": .tasks, "people": .people]
                if let dest = map[tab] { navigator.show(dest) }
            }
        }
        #endif
    }

    /// Map a menu/keyboard intent onto the navigator + stores.
    private func handle(_ intent: AppCommandBus.Intent?) {
        guard let intent else { return }
        switch intent {
        case .go(.account):    showAccount = true          // ⌘, opens Settings as a sheet, not a section
        case .go(let dest):    navigator.show(dest)
        case .capture:         navigator.show(.calendar); navigator.focusCapture = true
        case .newNote:         navigator.show(.notes);     navigator.composeNote = true
        case .newAssignment:   navigator.show(.tasks);     navigator.composeAssignment = true
        case .newChat:         navigator.show(.assistant); navigator.startNewChat = true
        case .voiceConversation: navigator.show(.assistant); navigator.startVoiceConversation = true
        case .find:            navigator.showSearch()
        case .refresh:         Task { await app.reloadVisible(navigator.destination) }
        }
    }

    /// Consume any pending App Intents navigation request through `handle(_:)`.
    private func drainShortcutNavigation() {
        if let intent = ShortcutNavigation.shared.consume() { handle(intent) }
    }
}
