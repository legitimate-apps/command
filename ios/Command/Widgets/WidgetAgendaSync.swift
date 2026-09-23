//
//  WidgetAgendaSync.swift
//  Command
//
//  Mirrors the signed-in app's planner state into the App Group. The widget never owns
//  credentials and never calls the server; it renders the last safe app snapshot.
//
//  The mirror is a fixed window — today plus the next few days (`WidgetAgendaBuilder.window`) —
//  NOT whatever the in-app calendar has loaded. The calendar loads the visible month's grid, so
//  mirroring it directly meant browsing to another month (or reaching the grid's last week)
//  emptied the widget's "today". When the loaded grid covers the window it's used as-is (no
//  network, and it reflects local edits instantly); otherwise the window is fetched on its own.
//

import SwiftUI
import WidgetKit

@available(iOS 26.0, *)
struct WidgetAgendaSync: ViewModifier {
    let app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear { schedule() }
            .onChange(of: app.cal.occurrences) { _, _ in schedule() }
            .onChange(of: app.tasks.assignments) { _, _ in schedule() }
            // Returning to the app (possibly on a new day) re-anchors the window on today.
            .onChange(of: scenePhase) { _, phase in if phase == .active { schedule() } }
    }

    /// Coalesce bursts (a refresh re-assigns both arrays back to back) into one write.
    private func schedule() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await write()
        }
    }

    private func write() async {
        let now = Date()
        guard let occurrences = await windowOccurrences(now: now), !Task.isCancelled else { return }
        let inputs = occurrences.map {
            AgendaOccurrenceInput(
                assignmentId: $0.assignmentId, title: $0.title, occursAt: $0.occursAt,
                status: $0.status, scheduleKind: $0.scheduleKind, hidden: $0.hidden ?? false
            )
        }
        let assignments = app.tasks.assignments.map {
            AgendaAssignmentInput(
                id: $0.id, title: $0.title, scheduledStart: $0.scheduledStart,
                status: $0.status, scheduleKind: $0.scheduleKind, hidden: $0.hidden ?? false,
                archived: $0.archivedAt != nil
            )
        }
        // `onChange` fires on every planner mutation and every refresh that re-assigns the
        // arrays, so this runs far more often than the content actually changes. Timeline
        // reloads are metered by the system — spend one only when the widget would draw
        // something different. See `WidgetAgendaStore.save`.
        let contentChanged = WidgetAgendaStore.save(WidgetAgendaBuilder.make(
            occurrences: inputs, assignments: assignments, now: now
        ))
        if contentChanged {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetAgendaStore.agendaKind)
        }
    }

    /// The occurrences for the widget window: the calendar's loaded rows when its grid covers the
    /// window, else a direct fetch of just that window. nil (keep the last good snapshot) when the
    /// fetch fails or there's no operator session to fetch with.
    private func windowOccurrences(now: Date) async -> [Occurrence]? {
        let window = WidgetAgendaBuilder.window(now: now)
        let grid = app.cal.gridDays
        if let first = grid.first, let last = grid.last,
           let gridEnd = Calendar.current.date(byAdding: .day, value: 1, to: last),
           first <= window.start, gridEnd >= window.end {
            return app.cal.occurrences
        }
        // Only an operator session has /api/assignments/calendar; a delegatee or signed-out app
        // must not fire a request that would 401 (and trip the session-expiry handler).
        guard app.phase == .signedIn, app.sessionMode == .operatorAccount else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let fetched = try? await app.client.calendar(start: f.string(from: window.start), end: f.string(from: window.end))
        // A sign-out while the request was in flight has already cleared the widget; writing this
        // account's rows now would put them back.
        guard app.phase == .signedIn, app.sessionMode == .operatorAccount else { return nil }
        return fetched
    }
}
