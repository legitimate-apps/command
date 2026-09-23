//
//  ShortcutNavigation.swift
//  Command
//
//  The one channel an "open the app" App Intent uses to steer the running shell, and
//  the hook a background capture uses to live-update the UI when the app happens to be
//  running. It mirrors `AppCommandBus` (the menu/keyboard channel) but is reachable from
//  the App Intents launch context, which can't see the scene-scoped bus directly.
//
//  Routing is *sticky*: an intent that cold-launches the app sets `pending` before the
//  shell exists, and the shell drains it on first appearance (as well as on change). The
//  two shells (`MainTabView`, `SplitRootView`) already share a `handle(AppCommandBus.Intent)`
//  router, so a drained request flows through the exact same path as ⌘-shortcuts.
//

import Foundation
import Observation

@MainActor
@Observable
final class ShortcutNavigation {
    static let shared = ShortcutNavigation()
    private init() {}

    /// The live app state, set once the scene is up. Weak so an App Intent that runs
    /// while the app is *not* in memory simply finds `nil` and skips the live refresh —
    /// the server write already happened; the UI catches up on next load.
    weak var appState: AppState?

    /// Bumped whenever a new request is routed, so the active shell's `onChange` fires
    /// even for the same destination twice in a row.
    private(set) var tick = 0
    private var pending: AppCommandBus.Intent?

    /// Queue a navigation request. The active shell consumes it on its next `onChange`
    /// (already running) or `onAppear` (just launched).
    func route(_ intent: AppCommandBus.Intent) {
        pending = intent
        tick &+= 1
    }

    /// Take and clear the pending request. Only ONE shell is ever in the tree at a time
    /// (tab shell OR split shell), so there's no double-consume.
    func consume() -> AppCommandBus.Intent? {
        defer { pending = nil }
        return pending
    }

    // MARK: - Live refresh (best-effort; no-op when the app isn't running)

    /// A background-captured note, surfaced at the top of the running Notes list.
    func noteCreated(_ note: Note) {
        guard let store = appState?.notes, !store.notes.contains(where: { $0.id == note.id }) else { return }
        store.notes.insert(note, at: 0)
    }

    func activityCreated(_ activity: Activity) {
        guard let store = appState?.log, !store.activities.contains(where: { $0.id == activity.id }) else { return }
        store.activities.insert(activity, at: 0)
    }

    func assignmentCreated(_ assignment: Assignment) {
        guard let store = appState?.tasks, !store.assignments.contains(where: { $0.id == assignment.id }) else { return }
        store.assignments.insert(assignment, at: 0)
    }

    func goalCreated(_ goal: Goal) {
        guard let store = appState?.tasks, !store.goals.contains(where: { $0.id == goal.id }) else { return }
        store.goals.insert(goal, at: 0)
    }
}
