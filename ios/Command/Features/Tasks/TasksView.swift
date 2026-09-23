//
//  TasksView.swift
//  Command
//

import SwiftUI

struct TasksView: View {
    @Environment(AppState.self) private var app
    @Environment(\.navigator) private var nav
    @State private var tab = 0
    @State private var showCreateAssignment = false
    @State private var showNewGoal = false
    @State private var detail: DetailSubject?
    @State private var searchText = ""
    @State private var searchActive = false   // hidden until the 🔍 button reveals it
    @State private var pendingDelete: Assignment?   // reminder awaiting delete confirmation
    @State private var showArchived = false         // Assignments tab: archived-only view

    /// In the iPad/Mac shell (Navigator present) → the shared detail column;
    /// on iPhone (no Navigator) → the existing sheet, gated by the detailPages
    /// kill-switch. Navigator presence — not size class — is the right signal: a
    /// split-view column reports its own (often compact) width, not the window's.
    private func open(_ subject: DetailSubject) {
        if let nav, nav.hasDetailColumn { nav.select(subject) }
        else if app.flags.isOn(.detailPages) { detail = subject }
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Client-side filters over the loaded data (`localizedStandardContains` =
    /// case/diacritic-insensitive). Hidden assignments are never surfaced by search
    /// (they'd leak hidden content). Search covers Assignments + Goals; the Log tab
    /// keeps its own list.
    private var filteredAssignments: [Assignment] {
        let source = showArchived ? app.tasks.archivedAssignments : app.tasks.assignments
        guard !query.isEmpty else { return source }
        return source.filter { !($0.hidden ?? false) && $0.title.localizedStandardContains(query) }
    }
    private var filteredGoals: [Goal] {
        guard !query.isEmpty else { return app.tasks.goals }
        return app.tasks.goals.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(spacing: 0) {
                    if searchActive && tab != 2 {
                        InlineSearchBar(text: $searchText,
                                        prompt: tab == 1 ? "Search goals" : "Search assignments") {
                            withAnimation(.easeOut(duration: 0.2)) { searchActive = false }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let error = app.tasks.errorMessage {
                        ErrorBanner(message: error) {
                            Task { await app.tasks.load(client: app.client) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Picker("View", selection: $tab) {
                        Text("Assignments").tag(0)
                        Text("Goals").tag(1)
                        Text("Log").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(16)

                    switch tab {
                    case 0: assignmentsList
                    case 1: goalsList
                    default: LogView()
                    }
                }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { searchActive = true } } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                    }
                    .tint(Palette.accent)
                    .accessibilityLabel("Search tasks")
                    .disabled(tab == 2)   // the Log tab keeps its own list
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showCreateAssignment = true } label: { Label("New assignment", systemImage: "checklist") }
                        Button { showNewGoal = true } label: { Label("New goal", systemImage: "target") }
                        if tab == 0 {
                            Divider()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showArchived.toggle() }
                                if showArchived { Task { await app.tasks.loadArchived(client: app.client) } }
                            } label: {
                                if showArchived {
                                    Label("Hide Archived", systemImage: "checkmark")
                                } else {
                                    Label("Show Archived", systemImage: "archivebox")
                                }
                            }
                        }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New task")
                }
            }
            .sheet(isPresented: $showCreateAssignment) { CreateAssignmentSheet().macSheet() }
            .sheet(item: $detail) { subject in NavigationStack { EntityDetailView(subject: subject) }.macSheet(.page) }
            // Delete confirmation shared by the swipe action and the row menu's Delete.
            // A hidden reminder must not surface its title here (it'd leak the veiled content).
            .confirmationDialog(
                "Delete this reminder?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { assignment in
                Button("Delete", role: .destructive) {
                    Haptics.delete()
                    Task {
                        if await app.tasks.delete(id: assignment.id, calendar: app.cal, client: app.client) {
                            nav?.assignmentRemoved(id: assignment.id)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { assignment in
                if assignment.hidden == true {
                    Text("This reminder will be permanently deleted. This can't be undone.")
                } else {
                    Text("“\(assignment.title)” will be permanently deleted. This can't be undone.")
                }
            }
            // ⌘⇧N / "New Assignment" from the Mac/iPad menu opens the create sheet. `initial: true`
            // so a cross-section ⌘⇧N (show(.tasks) mounts this view fresh with the flag already
            // set) still consumes it — plain onChange skips the value present at mount.
            .onChange(of: nav?.composeAssignment, initial: true) { _, want in
                if want == true { showCreateAssignment = true; nav?.composeAssignment = false }
            }
            // ⌘F / "Find" reveals the hidden search field (Assignments/Goals tabs). Always reset the
            // one-shot flag when consumed — even on the Log tab (tab == 2), where search doesn't open —
            // else it latches true and every later ⌘F app-wide becomes a silent no-op.
            .onChange(of: nav?.focusSearch) { _, want in
                if want == true {
                    if tab != 2 { withAnimation(.easeOut(duration: 0.2)) { searchActive = true } }
                    nav?.focusSearch = false
                }
            }
            #if DEBUG
            // Screenshot hook: `-COMMAND_PREVIEW_SEARCH <query>` opens search pre-filled (Assignments/Goals).
            // `-COMMAND_PREVIEW_NEW_GOAL YES` opens the goal composer — the "New" menu is a SwiftUI
            // `Menu`, whose popover never appears in the accessibility tree, so the sheet is otherwise
            // unreachable by VoiceOver-style automation. Mirrors AuthView's server-sheet hook.
            .onAppear {
                if tab != 2, let q = UserDefaults.standard.string(forKey: "COMMAND_PREVIEW_SEARCH"), !q.isEmpty {
                    searchText = q; searchActive = true
                }
                if UserDefaults.standard.bool(forKey: "COMMAND_PREVIEW_NEW_GOAL") { showNewGoal = true }
            }
            #endif
            .sheet(isPresented: $showNewGoal) { CreateGoalSheet().macSheet() }
            .task {
                await app.tasks.load(client: app.client)
                if app.people.delegatees.isEmpty { await app.people.load(client: app.client) }
            }
            .refreshable { await app.tasks.load(client: app.client) }
        }
    }

    /// Header strip shown while the Assignments tab displays the archive, with the way back.
    private var archivedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
            Text("Archived").font(Typeface.body(14, .semibold))
            Spacer()
            Button("Show current") {
                withAnimation(.easeInOut(duration: 0.2)) { showArchived = false }
            }
            .font(Typeface.body(13, .medium))
            .tint(Palette.accent)
        }
        .foregroundStyle(Palette.inkSecondary)
        .padding(.vertical, 6)
    }

    private func toggleArchive(_ assignment: Assignment) {
        Haptics.light()
        let archiving = !assignment.isArchived
        Task {
            if await app.tasks.setArchived(id: assignment.id, archived: archiving,
                                           calendar: app.cal, client: app.client), archiving {
                nav?.assignmentRemoved(id: assignment.id)
            }
        }
    }

    @ViewBuilder
    private var assignmentsList: some View {
        if showArchived && app.tasks.archivedAssignments.isEmpty {
            VStack(spacing: 0) {
                archivedBanner.padding(.horizontal, 16).padding(.top, 4)
                emptyState(icon: "archivebox", title: "Nothing archived",
                           message: "Archive a reminder to move it off your calendar and lists without deleting it.")
            }
        } else if !showArchived && app.tasks.assignments.isEmpty {
            if app.tasks.isLoading {
                SkeletonList(count: 4)
                    .accessibilityLabel("Loading assignments")
            } else if app.tasks.errorMessage != nil {
                EmptyView()
            } else {
                emptyState(icon: "checklist", title: "No assignments yet",
                           message: "Capture a thought, then turn it into scheduled, delegated work — here or with Claude Code.")
            }
        } else {
            let items = filteredAssignments
            if items.isEmpty {
                noResults
            } else {
                // A List (not the old ScrollView+LazyVStack) so each reminder gets a
                // native trailing swipe-to-delete. Styled to keep the card look: clear
                // rows on the paper background, no separators, insets matched to the
                // former spacing:10 / padding:16.
                List {
                    if showArchived {
                        archivedBanner
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))
                    }
                    ForEach(items) { assignment in
                        AssignmentRow(assignment: assignment,
                                      onRequestDelete: { pendingDelete = assignment },
                                      onToggleArchive: { toggleArchive(assignment) })
                            .rowOpenAction {
                                if !(assignment.hidden ?? false) { open(.assignment(assignment)) }
                            }
                            .hoverEffect()
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = assignment } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(Palette.danger)
                                Button { toggleArchive(assignment) } label: {
                                    Label(assignment.isArchived ? "Unarchive" : "Archive",
                                          systemImage: assignment.isArchived ? "tray.and.arrow.up" : "archivebox")
                                }
                                .tint(Palette.accent)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    @ViewBuilder
    private var goalsList: some View {
        if app.tasks.goals.isEmpty {
            if app.tasks.isLoading {
                SkeletonList(count: 3)
                    .accessibilityLabel("Loading goals")
            } else if app.tasks.errorMessage != nil {
                EmptyView()
            } else {
                emptyState(icon: "target", title: "No goals yet",
                           message: "Goals gather the assignments that move them forward.")
            }
        } else {
            let items = filteredGoals
            if items.isEmpty {
                noResults
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { goal in
                            GoalRow(goal: goal)
                                .tappableRow { open(.goal(goal)) }
                                .hoverEffect()
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36)).foregroundStyle(Palette.inkSecondary.opacity(0.5))
                .accessibilityHidden(true)
            Text("No matches").font(Typeface.display(20)).foregroundStyle(Palette.ink)
            Text("Nothing matches “\(searchText)”.")
                .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        CommandEmptyState(icon: icon, title: title, message: message)
    }
}

struct AssignmentRow: View {
    @Environment(AppState.self) private var app
    let assignment: Assignment
    /// Ask the parent to confirm deletion — the actual delete runs after the dialog.
    var onRequestDelete: () -> Void = {}
    /// Archive/unarchive (reversible, so no confirmation) — the parent owns the store call.
    var onToggleArchive: () -> Void = {}
    @State private var confirmHide = false

    private var assigneeName: String? {
        guard let id = assignment.assigneeId else { return nil }
        return app.people.delegatees.first { $0.id == id }?.name
    }
    private var struck: Bool { assignment.status == "done" || assignment.status == "cancelled" }

    private var isOverdue: Bool { PlannerFormat.isOverdue(assignment) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggleDone) {
                Image(systemName: assignment.status == "done" ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(assignment.status == "done" ? Palette.sage : Palette.inkSecondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark done")
            .accessibilityValue(assignment.status == "done" ? "Done" : "Not done")
            .accessibilityAddTraits(assignment.status == "done" ? .isSelected : [])

            VStack(alignment: .leading, spacing: 5) {
                Text(assignment.title)
                    .font(Typeface.body(16, .medium))
                    .foregroundStyle(Palette.ink)
                    .strikethrough(struck, color: Palette.inkSecondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: isOverdue ? "exclamationmark.triangle.fill"
                          : (assignment.scheduleKind == "routine" ? "repeat" : "calendar"))
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text(isOverdue ? "Overdue · \(PlannerFormat.scheduleSummary(assignment))"
                         : PlannerFormat.scheduleSummary(assignment))
                    if let name = assigneeName { Text("· \(name)") }
                }
                .font(Typeface.body(12))
                .foregroundStyle(isOverdue ? Palette.danger : Palette.inkSecondary)
                .lineLimit(1)
            }
            .hiddenVeil(hidden: assignment.hidden ?? false)   // a hidden reminder must not show its title
            Spacer(minLength: 0)

            Menu {
                ForEach(PlannerFormat.statuses, id: \.self) { status in
                    Button {
                        Haptics.light()
                        Task { await app.tasks.setStatus(id: assignment.id, status: status, client: app.client) }
                    } label: {
                        if status == assignment.status {
                            Label(PlannerFormat.statusLabel(status), systemImage: "checkmark")
                        } else {
                            Text(PlannerFormat.statusLabel(status))
                        }
                    }
                }
                Divider()
                HideMenuItems(isHidden: assignment.hidden ?? false, reason: "Reveal this reminder",
                                setHidden: { hide in
                    await app.tasks.setHidden(id: assignment.id, hidden: hide, client: app.client)
                }, requestHide: { confirmHide = true })
                Divider()
                Button {
                    onToggleArchive()
                } label: {
                    Label(assignment.isArchived ? "Unarchive" : "Archive",
                          systemImage: assignment.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
                Button(role: .destructive) {
                    onRequestDelete()
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                statusChip
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        // Right-click / long-press mirrors the status chip's menu. It used to offer only
        // hide/reveal, so a Mac user who right-clicked a reminder — the reflex on that platform —
        // got neither the archive nor the delete that the trailing swipe offers on touch.
        .contextMenu {
            HideMenuItems(isHidden: assignment.hidden ?? false, reason: "Reveal this reminder",
                            setHidden: { hide in
                await app.tasks.setHidden(id: assignment.id, hidden: hide, client: app.client)
            }, requestHide: { confirmHide = true })
            Divider()
            Button {
                onToggleArchive()
            } label: {
                Label(assignment.isArchived ? "Unarchive" : "Archive",
                      systemImage: assignment.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            Button(role: .destructive) {
                onRequestDelete()
            } label: { Label("Delete", systemImage: "trash") }
        }
        .hideConfirmation(isPresented: $confirmHide, what: "reminder") {
            Task { await app.tasks.setHidden(id: assignment.id, hidden: true, client: app.client) }
        }
    }

    private var statusChip: some View {
        Text(PlannerFormat.statusLabel(assignment.status))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(PlannerFormat.statusColor(assignment.status))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(PlannerFormat.statusColor(assignment.status).opacity(0.14), in: Capsule())
    }

    private func toggleDone() {
        let next = assignment.status == "done" ? "todo" : "done"
        Haptics.light()
        Task { await app.tasks.setStatus(id: assignment.id, status: next, client: app.client) }
    }
}

struct GoalRow: View {
    let goal: Goal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "target").font(.system(size: 17)).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.title).font(Typeface.body(16, .medium)).foregroundStyle(Palette.ink)
                Text(goal.targetDate.map { "by \(PlannerFormat.dayLabel($0))" } ?? PlannerFormat.statusLabel(goal.status))
                    .font(Typeface.body(12)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }
}
