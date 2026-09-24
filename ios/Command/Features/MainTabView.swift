//
//  MainTabView.swift
//  Command
//

import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @Environment(AppCommandBus.self) private var bus
    // A compose-only Navigator (no detail column): it carries the one-shot ⌘N/⌘F/⌘⇧C
    // intents so a hardware keyboard drives the tab shell too (B8), while entity taps
    // still open sheets. Section views branch on `nav.hasDetailColumn`, so injecting this
    // does NOT reroute their taps — the compact path renders exactly as it always has.
    @State private var navigator = Navigator(hasDetailColumn: false)
    @State private var showAccount = false

    var body: some View {
        // Five tabs (iPhone's sweet spot). The flagship Assistant takes the center
        // slot; Account is reached from the profile button on the Calendar screen (and
        // ⌘, when a keyboard is attached). Selection is driven through the Navigator so
        // the ⌘1…⌘5 "Go" commands switch tabs.
        TabView(selection: Binding(
            get: { navigator.destination },
            set: { navigator.destination = $0 }
        )) {
            CalendarView().tag(AppDestination.calendar)
                .tabItem { Label("Calendar", systemImage: "calendar") }
            NotesView().tag(AppDestination.notes)
                .tabItem { Label("Notes", systemImage: "note.text") }
            AssistantRootView().tag(AppDestination.assistant)
                .tabItem { Label("Assistant", systemImage: "sparkles") }
            TasksView().tag(AppDestination.tasks)
                .tabItem { Label("Tasks", systemImage: "checklist") }
            PeopleView().tag(AppDestination.people)
                .tabItem { Label("People", systemImage: "person.2") }
        }
        .tint(Palette.accent)   // selected tab + default controls use the amber accent
        .environment(\.navigator, navigator)              // section views consume the compose intents
        .onChange(of: bus.tick) { _, _ in handle(bus.last) }
        // App Intents ("Open Command …") route through the sticky ShortcutNavigation bridge;
        // drain it on change (app already running) and on appear (just cold-launched by a Shortcut).
        .onChange(of: ShortcutNavigation.shared.tick) { _, _ in drainShortcutNavigation() }
        .sheet(isPresented: $showAccount) { AccountView().macSheet(.page) }
        .onAppear {
            drainShortcutNavigation()
            #if DEBUG
            // Screenshot hook: launch with `-COMMAND_START_TAB assistant` to land on a tab.
            if let tab = UserDefaults.standard.string(forKey: "COMMAND_START_TAB") {
                let map: [String: AppDestination] = [
                    "calendar": .calendar, "notes": .notes, "assistant": .assistant,
                    "agent": .assistant, "tasks": .tasks, "people": .people,
                ]
                if let dest = map[tab] { navigator.destination = dest }
            }
            // Verification hook (B8): `-COMMAND_FIRE_INTENT newNote` fires a real bus intent
            // shortly after launch, exercising the exact ⌘-shortcut path a hardware keyboard
            // would (bus → this shell's onChange → handle → Navigator → the section view's
            // compose sheet) — since the sim can't deliver a Cmd chord for automation.
            if let name = UserDefaults.standard.string(forKey: "COMMAND_FIRE_INTENT") {
                let map: [String: AppCommandBus.Intent] = [
                    "newNote": .newNote, "newAssignment": .newAssignment, "newChat": .newChat,
                    "capture": .capture, "find": .find, "account": .go(.account),
                ]
                if let intent = map[name] {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        bus.send(intent)
                    }
                }
            }
            #endif
        }
    }

    /// Map a menu/keyboard intent onto the tab selection + the section views' one-shot
    /// flags — the SAME channel the iPad/Mac split shell uses (see SplitRootView.handle),
    /// so ⌘N/⌘⇧N/⌘⌥N/⌘⇧C/⌘F/⌘R/⌘1…5 behave identically in both shells. `.go(.account)`
    /// and ⌘, raise Account as a sheet (the tab shell has no sidebar slot for it).
    private func handle(_ intent: AppCommandBus.Intent?) {
        guard let intent else { return }
        switch intent {
        case .go(.account):    showAccount = true
        case .go(let dest):    navigator.show(dest)
        case .capture:         navigator.show(.calendar);  navigator.focusCapture = true
        case .newNote:         navigator.show(.notes);      navigator.composeNote = true
        case .newAssignment:   navigator.show(.tasks);      navigator.composeAssignment = true
        case .newChat:         navigator.show(.assistant);  navigator.startNewChat = true
        case .voiceConversation: navigator.show(.assistant); navigator.startVoiceConversation = true
        case .find:            navigator.showSearch()
        case .refresh:         Task { await app.reloadVisible(navigator.destination) }
        }
    }

    /// Consume any pending App Intents navigation request through the same `handle(_:)`
    /// path the menu/keyboard commands use.
    private func drainShortcutNavigation() {
        if let intent = ShortcutNavigation.shared.consume() { handle(intent) }
    }
}
