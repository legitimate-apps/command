//
//  MyWorkView.swift
//  Command
//
//  The deliberately small shell for invited delegatees: only work the server scoped to them.
//

import SwiftUI

struct MyWorkView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = MyWorkStore()
    @State private var selectedAssignment: Assignment?

    private var profile: MyProfile? { store.profile ?? app.myProfile }
    private var sections: MyWorkSections { MyWorkSections(store.occurrences) }
    private var unscheduled: [Assignment] {
        let represented = Set(store.occurrences.map(\.assignmentId))
        return store.assignments.filter { !represented.contains($0.id) && !MyWorkSections.isFinished($0.status) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("My Work")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await app.logout() } }.fixedSize()
                }
            }
            .sheet(item: $selectedAssignment) { assignment in
                MyWorkDetailSheet(assignment: assignment, store: store).macSheet(.page)
            }
            .task { await store.load(client: app.client) }
            .refreshable { await store.load(client: app.client) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.load(client: app.client) } }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.isLoading {
            VStack(spacing: 0) {
                header
                SkeletonList(count: 4).accessibilityLabel("Loading My Work")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header
                    if let error = store.errorMessage {
                        ErrorBanner(message: error) { Task { await store.load(client: app.client) } }
                    }
                    let sections = self.sections
                    let unscheduled = self.unscheduled
                    if sections.isEmpty && unscheduled.isEmpty, store.errorMessage == nil {
                        CommandEmptyState(icon: "checkmark.circle", title: "Nothing assigned to you yet",
                                          message: "New work will appear here when it is assigned.")
                            .frame(minHeight: 360)
                    } else {
                        occurrenceSection("Overdue", items: sections.overdue)
                        occurrenceSection("Today", items: sections.today)
                        occurrenceSection("Upcoming", items: sections.upcoming)
                        if !unscheduled.isEmpty { assignmentSection("Also assigned", items: unscheduled) }
                        occurrenceSection("Done recently", items: sections.doneRecently)
                    }
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile?.delegateeName ?? "My Work")
                .font(Typeface.display(30)).foregroundStyle(Palette.ink)
            if let operatorName = profile?.operatorDisplayName, !operatorName.isEmpty {
                Text("Working with \(operatorName)")
                    .font(Typeface.body(15)).foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func occurrenceSection(_ title: String, items: [Occurrence]) -> some View {
        if !items.isEmpty {
            sectionTitle(title)
            ForEach(items) { occurrence in
                MyOccurrenceRow(occurrence: occurrence, store: store) {
                    selectedAssignment = store.assignments.first { $0.id == occurrence.assignmentId }
                }
            }
        }
    }

    @ViewBuilder private func assignmentSection(_ title: String, items: [Assignment]) -> some View {
        sectionTitle(title)
        ForEach(items) { assignment in
            MyAssignmentRow(assignment: assignment, store: store) { selectedAssignment = assignment }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(Typeface.display(20)).foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct MyOccurrenceRow: View {
    @Environment(AppState.self) private var app
    let occurrence: Occurrence
    let store: MyWorkStore
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(PlannerFormat.statusColor(occurrence.status)).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.title).font(Typeface.body(16, .medium)).foregroundStyle(Palette.ink)
                Text(summary).font(Typeface.body(12)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            Menu {
                if occurrence.scheduleKind == "routine" {
                    occurrenceButton("Mark this occurrence done", "done", "checkmark.circle")
                    occurrenceButton("Skip this occurrence", "skipped", "forward.end.circle")
                } else {
                    assignmentStatusButtons(id: occurrence.assignmentId, current: occurrence.status, store: store, client: app.client)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(Palette.accent)
            }
            .accessibilityLabel("Actions for \(occurrence.title)")
        }
        .padding(14).cardSurface(cornerRadius: 16)
        .contentShape(Rectangle()).onTapGesture(perform: open)
        .accessibilityAction(named: "Open details") { open() }
    }

    private var summary: String {
        guard let date = PlannerFormat.parse(occurrence.occursAt) else { return PlannerFormat.statusLabel(occurrence.status) }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE, MMM d · h:mm a"
        return "\(formatter.string(from: date)) · \(PlannerFormat.statusLabel(occurrence.status))"
    }

    private func occurrenceButton(_ label: String, _ status: String, _ image: String) -> some View {
        Button {
            Haptics.light()
            Task { await store.setOccurrenceStatus(status, occurrence: occurrence, client: app.client) }
        } label: { Label(label, systemImage: image) }
    }
}

private struct MyAssignmentRow: View {
    @Environment(AppState.self) private var app
    let assignment: Assignment
    let store: MyWorkStore
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(PlannerFormat.statusColor(assignment.status)).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(assignment.title).font(Typeface.body(16, .medium)).foregroundStyle(Palette.ink)
                Text(PlannerFormat.scheduleSummary(assignment))
                    .font(Typeface.body(12)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            Menu {
                assignmentStatusButtons(id: assignment.id, current: assignment.status, store: store, client: app.client)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(Palette.accent)
            }
            .accessibilityLabel("Actions for \(assignment.title)")
        }
        .padding(14).cardSurface(cornerRadius: 16)
        .contentShape(Rectangle()).onTapGesture(perform: open)
        .accessibilityAction(named: "Open details") { open() }
    }
}

@ViewBuilder private func assignmentStatusButtons(id: Int, current: String, store: MyWorkStore,
                                                   client: APIClient) -> some View {
    ForEach([("done", "Mark done", "checkmark.circle"),
             ("in_progress", "Mark in progress", "play.circle"),
             ("blocked", "Mark blocked", "exclamationmark.octagon"),
             ("skipped", "Mark skipped", "forward.end.circle")], id: \.0) { item in
        if item.0 != current {
            Button {
                Haptics.light()
                Task { await store.setAssignmentStatus(id: id, status: item.0, client: client) }
            } label: { Label(item.1, systemImage: item.2) }
        }
    }
}

private struct MyWorkDetailSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let assignment: Assignment
    let store: MyWorkStore

    private var current: Assignment { store.assignments.first { $0.id == assignment.id } ?? assignment }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(current.title).font(Typeface.display(22)).foregroundStyle(Palette.ink)
                    if let details = current.details, !details.isEmpty { Text(details).font(Typeface.body(15)) }
                    if let notes = current.notes, !notes.isEmpty { Text(notes).font(Typeface.body(15)) }
                }
                Section("Schedule") {
                    LabeledContent("When", value: PlannerFormat.scheduleSummary(current))
                    LabeledContent("Status", value: PlannerFormat.statusLabel(current.status))
                }
                // Read-only: files the operator attached to this assignment (briefs, photos…).
                AttachmentsSection(entityKind: "assignment", entityId: current.id, delegatee: true)
                Section("Actions") {
                    Menu("Change assignment status") {
                        assignmentStatusButtons(id: current.id, current: current.status, store: store, client: app.client)
                    }
                    if current.scheduleKind == "routine" {
                        ForEach(store.occurrences.filter { $0.assignmentId == current.id && Calendar.current.isDateInToday(PlannerFormat.parse($0.occursAt) ?? .distantPast) }) { occurrence in
                            Menu("Today's occurrence") {
                                Button("Mark this occurrence done") {
                                    Haptics.light()
                                    Task { await store.setOccurrenceStatus("done", occurrence: occurrence, client: app.client) }
                                }
                                Button("Skip this occurrence") {
                                    Haptics.light()
                                    Task { await store.setOccurrenceStatus("skipped", occurrence: occurrence, client: app.client) }
                                }
                            }
                        }
                    }
                }
            }
            .brandedForm()
            .navigationTitle("Assignment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fixedSize() } }
        }
    }
}
