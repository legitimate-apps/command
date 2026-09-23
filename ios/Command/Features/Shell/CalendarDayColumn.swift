//
//  CalendarDayColumn.swift
//  Command
//
//  Column 3 of the iPad/Mac split when the Calendar section is showing and nothing more specific
//  is selected: the selected day's agenda (scheduled occurrences + logged facts). Reads the shared
//  CalendarStore on AppState — the same data the month grid (content column) and the capture dock
//  drive — so picking a day in the grid updates this pane live. On iPhone the agenda stays stacked
//  under the grid (CalendarView's compact layout); this pane is the regular-width equivalent.
//

import SwiftUI

struct CalendarDayColumn: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @State private var editingActivity: Activity?

    private var cal: CalendarStore { app.cal }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // No inner date header here: the inline navigationTitle already names the day, so a
                    // second "THURSDAY, JUL 2" line directly under it was pure duplication (V2).
                    if let err = cal.errorMessage {
                        Label(err, systemImage: "wifi.exclamationmark")
                            .font(Typeface.body(12))
                            .foregroundStyle(Palette.danger)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    let occs = cal.occurrences(on: cal.selectedDay)
                    let logs = cal.activities(on: cal.selectedDay)
                    if occs.isEmpty && logs.isEmpty {
                        VStack {
                            Spacer()
                            emptyDay
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    } else {
                        ForEach(occs) { occ in
                            OccurrenceRow(occurrence: occ, assigneeName: assigneeName(occ.assigneeId))
                                .tappableRow { openOccurrence(occ) }
                                .hoverEffect()
                                .contextMenu { occurrenceMenu(occ) }
                                // Drag-to-reschedule: the month grid in the content column is a
                                // drop destination, but this column — the ONLY agenda the iPad/Mac
                                // split shell shows — never made its rows draggable, so the whole
                                // feature was dead outside the iPhone layout. Same payload the
                                // compact agenda uses (CalendarView.dragPayload).
                                .draggable(CalendarView.dragPayload(occ))
                        }
                        if !logs.isEmpty {
                            Text("LOGGED")
                                .font(Typeface.body(11, .semibold)).tracking(1.1)
                                .foregroundStyle(Palette.sage)
                                .padding(.top, occs.isEmpty ? 0 : 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(logs) { activity in
                                ActivityRow(activity: activity, style: .compact)
                                    .tappableRow { openLog(activity) }
                                    .hoverEffect()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                .padding(20)
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationTitle(dayTitle)
        .navigationBarTitleDisplayMode(.inline)
        // A hidden log opens its (censored) edit sheet rather than routing plaintext to the detail
        // column, matching the calendar's iPhone behavior.
        .sheet(item: $editingActivity, onDismiss: { Task { await cal.load(client: app.client) } }) {
            ActivityEditSheet(activity: $0).macSheet()
        }
    }

    private var emptyDay: some View {
        CommandEmptyState(
            icon: "sun.max",
            title: "Nothing scheduled or logged",
            message: ""
        )
    }

    private func openLog(_ activity: Activity) {
        if activity.hidden ?? false { editingActivity = activity }
        else { nav.select(.log(activity)) }
    }

    /// Open a scheduled occurrence's assignment in the detail column (fetches the full assignment,
    /// which the occurrence only references by id).
    private func openOccurrence(_ occ: Occurrence) {
        guard !(occ.hidden ?? false) else { return }
        Task {
            guard let assignment = try? await app.client.assignment(id: occ.assignmentId) else { return }
            nav.select(.assignment(assignment))
        }
    }

    /// Long-press / right-click one scheduled occurrence to update it in place or open its source.
    @ViewBuilder private func occurrenceMenu(_ occ: Occurrence) -> some View {
        if occ.status != "done" {
            occurrenceStatusButton(occ, status: "done", label: scopedLabel("done", occ),
                                   systemImage: "checkmark.circle")
        }
        if occ.status != "skipped" {
            occurrenceStatusButton(occ, status: "skipped", label: scopedLabel("skipped", occ),
                                   systemImage: "forward.end.circle")
        }
        if occ.status == "done" || occ.status == "skipped" {
            occurrenceStatusButton(occ, status: "todo", label: scopedLabel("pending", occ),
                                   systemImage: "circle")
        }
        // Undo a drag-reschedule. The compact agenda has always offered this; without it a moved
        // occurrence could never be put back from the iPad/Mac split shell.
        if occ.isRescheduled {
            Button {
                Haptics.light()
                Task { await cal.resetOverride(occ, client: app.client) }
            } label: {
                Label("Reset to series time", systemImage: "arrow.uturn.backward")
            }
        }
        if !(occ.hidden ?? false) {
            Button { openOccurrence(occ) } label: {
                Label(occ.scheduleKind == "routine" ? "Open series" : "Open assignment",
                      systemImage: "arrow.up.right.square")
            }
        }
    }

    private func occurrenceStatusButton(_ occ: Occurrence, status: String, label: String,
                                        systemImage: String) -> some View {
        Button {
            Haptics.light()
            Task { await cal.setOccurrenceStatus(status, for: occ, client: app.client) }
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    private func scopedLabel(_ status: String, _ occ: Occurrence) -> String {
        occ.scheduleKind == "routine" ? "Mark this occurrence \(status)" : "Mark \(status)"
    }

    private func assigneeName(_ id: Int?) -> String? {
        guard let id else { return nil }
        return app.people.delegatees.first { $0.id == id }?.name
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(cal.selectedDay) { return "Today" }
        return Self.fmt.string(from: cal.selectedDay)
    }
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f }()
}
