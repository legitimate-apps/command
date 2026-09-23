//
//  EntityDetailView.swift
//  Command
//
//  The shared detail page for an assignment, goal, or logged fact. Three parts: a context panel
//  (the facts around its creation), a big persistent notes field (debounced save), and a checklist
//  of user items (AI-generated sub-steps land in a later release). Reached by tapping a row when
//  the `detailPages` flag is on. Hidden items keep their existing surfaces — only
//  non-hidden items route here — so nothing leaks.
//

import SwiftUI

/// What a detail page is about — wraps the entity and exposes the bits the page needs.
enum DetailSubject: Identifiable {
    case assignment(Assignment)
    case goal(Goal)
    case log(Activity)

    var id: String {
        switch self {
        case .assignment(let a): return "a\(a.id)"
        case .goal(let g): return "g\(g.id)"
        case .log(let l): return "l\(l.id)"
        }
    }
    var parentType: String {
        switch self { case .assignment: "assignment"; case .goal: "goal"; case .log: "activity" }
    }
    var parentId: Int {
        switch self { case .assignment(let a): a.id; case .goal(let g): g.id; case .log(let l): l.id }
    }
    var title: String {
        switch self { case .assignment(let a): a.title; case .goal(let g): g.title; case .log(let l): l.title }
    }
    var notes: String {
        switch self {
        case .assignment(let a): a.notes ?? ""
        case .goal(let g): g.notes ?? ""
        case .log(let l): l.details ?? ""
        }
    }
    var kindLabel: String {
        switch self { case .assignment: "Assignment"; case .goal: "Goal"; case .log: "Log" }
    }
    /// Current status string for the status-editable subjects (goal, assignment); nil for a log.
    var statusValue: String? {
        switch self { case .assignment(let a): a.status; case .goal(let g): g.status; case .log: nil }
    }
}

struct EntityDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigator) private var nav
    @Environment(\.scenePhase) private var scenePhase
    let subject: DetailSubject
    /// True when hosted at the root of the iPad/Mac detail column (where `dismiss()` is a no-op);
    /// false when presented as an iPhone sheet. Drives how the view closes itself.
    var inDetailColumn = false

    @State private var store: DetailStore
    @State private var newItem = ""
    @State private var assigneeName: String?
    /// Optimistic view of the current assignee (the `subject` snapshot doesn't refresh in place).
    @State private var currentAssigneeId: Int?
    @State private var showReassign = false
    @State private var reassignPick: Delegatee?
    @State private var showGoalPicker = false
    @State private var goalPick: Goal?
    /// Optimistic local view of the goal link (the `subject` is a snapshot handed to this view and
    /// doesn't update in place). `goalWasCleared` distinguishes "unlinked just now" from "untouched".
    @State private var linkedGoalId: Int?
    @State private var goalWasCleared = false
    /// Optimistic per-assignment reminder offset. `leadEdited` distinguishes "not touched" from
    /// "set to inherit (nil)" — the same distinction the server draws between UNSET and null.
    @State private var leadEdited = false
    @State private var leadValue: Int?
    @State private var confirmHide = false
    @FocusState private var newItemFocused: Bool
    @FocusState private var editing: EditField?

    private enum EditField: Hashable { case title, notes }

    init(subject: DetailSubject, inDetailColumn: Bool = false) {
        self.subject = subject
        self.inDetailColumn = inDetailColumn
        _store = State(initialValue: DetailStore(
            parentType: subject.parentType, parentId: subject.parentId,
            title: subject.title, notes: subject.notes, status: subject.statusValue ?? ""))
    }

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section {
                    ErrorBanner(message: error) {
                        Task { await store.load(client: app.client) }
                    }
                }
                .listRowBackground(Color.clear)
            }
            contextSection
            advancingWorkSection
            notesSection
            checklistSection
            // Assignments carry attachments (spec 2026-07-19-later-bucket); goals/logs don't.
            if case .assignment(let a) = subject {
                AttachmentsSection(entityKind: "assignment", entityId: a.id)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.paper.ignoresSafeArea())
        .navigationTitle(subject.kindLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing != nil {
                // While a text field is focused, the trailing action is "Done" — it just unfocuses
                // (edits auto-save as you type). No modal "edit mode" to enter for the title/notes.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { editing = nil }.fontWeight(.semibold).tint(Palette.accent)
                }
            } else {
                // A clear way out when presented as a sheet (iPhone). Without this the detail could
                // trap the user — swipe-to-dismiss isn't discoverable and tabs don't clear it.
                if !inDetailColumn {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.fontWeight(.semibold).tint(Palette.accent)
                    }
                }
                // Not typing: EditButton manages the checklist (reorder/delete); the menu redacts.
                ToolbarItem { EditButton() }
                if hideableId != nil {
                    ToolbarItem {
                        Menu {
                            Button { askAssistant() } label: {
                                Label("Ask the assistant", systemImage: "sparkles")
                            }
                            Button { confirmHide = true } label: { Label("Hide…", systemImage: "eye.slash") }
                        } label: {
                            Image(systemName: "ellipsis.circle").tint(Palette.accent)
                                .accessibilityLabel("More options")
                        }
                    }
                }
            }
        }
        .task {
            await store.load(client: app.client)
            if case .assignment(let a) = subject {
                if app.people.delegatees.isEmpty { await app.people.load(client: app.client) }
                currentAssigneeId = a.assigneeId
                assigneeName = a.assigneeId.flatMap { id in app.people.delegatees.first { $0.id == id }?.name }
            }
        }
        // Presentation modifiers live at the body root rather than on the row Buttons that trigger
        // them — a lazily-built List row is not a stable presentation anchor. (The 2026-07-15
        // "picker doesn't open on iPad" bug was NOT about presentation at all: the rows' plain-style
        // Button labels had an unhittable Spacer dead zone mid-row — see the contentShape fix on
        // assigneeControl/goalControl.)
        .sheet(isPresented: $showReassign, onDismiss: { withAssignment(applyAssigneePick) }) {
            AssigneePickerSheet(selection: $reassignPick).macSheet()
        }
        .sheet(isPresented: $showGoalPicker, onDismiss: { withAssignment(applyGoalPick) }) {
            GoalPickerSheet(selection: $goalPick).macSheet()
        }
        .hideConfirmation(isPresented: $confirmHide, what: subject.kindLabel.lowercased(), confirm: hide)
        // Every save's server copy flows back into the shared lists (sheet on iPhone, detail
        // column on iPad/Mac alike), so the Tasks list shows an edited title/notes at once.
        .onAppear {
            let tasks = app.tasks
            store.onAssignmentSaved = { tasks.apply($0) }
            store.onGoalSaved = { tasks.apply($0) }
        }
        .onDisappear { Task { await store.flushAll(client: app.client) } }
        // Persist immediately when the app is backgrounded/killed, so pending title+notes survive an
        // app restart mid-edit (the debounce Task doesn't survive suspension).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await store.flushAll(client: app.client) } }
        }
    }

    // MARK: Context

    private var contextSection: some View {
        Section {
            // Tap the title to edit it directly — no Edit button to press. Auto-saves as you type.
            TextField("Title", text: Binding(
                get: { store.title },
                set: { store.title = $0; store.titleChanged(client: app.client) }
            ), axis: .vertical)
                .font(Typeface.display(20)).foregroundStyle(Palette.ink)
                .lineLimit(1...3)
                .focused($editing, equals: .title)
                .submitLabel(.done)
                .onSubmit { editing = nil }
                .frame(maxWidth: .infinity, alignment: .leading)
            statusControl
            assigneeControl
            goalControl
            reminderControl
            ForEach(contextRows, id: \.label) { row in
                LabeledContent(row.label) {
                    Text(row.value).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.trailing)
                }
            }
        }
        .listRowBackground(Palette.surface)
    }

    /// The status options a person may set for this subject; nil for a log (no status).
    private var statusOptions: [String]? {
        switch subject {
        case .goal:       return ["open", "in_progress", "done", "dropped"]
        case .assignment: return ["todo", "scheduled", "in_progress", "done", "blocked", "cancelled"]
        case .log:        return nil
        }
    }

    /// Interactive Status row — a line of tappable chips that persist the chosen status.
    /// Replaces the old read-only Status text so a goal/assignment can actually be moved to
    /// done/dropped/etc. Plain buttons (not a `Menu`) so the control is reliably reachable by
    /// VoiceOver and UI automation, and readable at large text sizes.
    @ViewBuilder private var statusControl: some View {
        if let options = statusOptions {
            let current = store.status.isEmpty ? (subject.statusValue ?? "") : store.status
            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(Typeface.body(13)).foregroundStyle(Palette.inkSecondary)
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(options, id: \.self) { s in
                        let selected = (current == s)
                        Button {
                            Haptics.light()
                            Task {
                                await store.updateStatus(s, client: app.client)
                                // Refresh the shared lists so the goal/assignment list and any
                                // re-opened detail reflect the new status (not a stale "open").
                                await app.tasks.load(client: app.client)
                            }
                        } label: {
                            Text(PlannerFormat.statusLabel(s))
                                .font(Typeface.body(15, selected ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(selected ? Palette.accent.opacity(0.18) : Palette.ink.opacity(0.06))
                                .foregroundStyle(selected ? Palette.accent : Palette.ink)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Status \(PlannerFormat.statusLabel(s))")
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: current)
            }
        }
    }

    /// Interactive Assignee row (assignments only) — tap to reassign to another delegatee. Without
    /// this an assignment stayed stuck with whoever it was created for, even after they left.
    @ViewBuilder private var assigneeControl: some View {
        if case .assignment = subject {
            Button {
                // Seed the picker with the current assignee so onDismiss can tell an actual change
                // (including a clear) from "opened and closed it".
                reassignPick = app.people.delegatees.first { $0.id == currentAssigneeId }
                showReassign = true
            } label: {
                HStack {
                    Text("Assignee").foregroundStyle(Palette.ink)
                    Spacer()
                    Text(assigneeName ?? "Unassigned")
                        .foregroundStyle(assigneeName == nil ? Palette.inkSecondary : Palette.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                        .accessibilityHidden(true)
                }
                // The whole row must be hittable: with `.plain`, only the label's visible
                // content takes taps, so the Spacer between "Assignee" and the value was a
                // dead zone — taps landing mid-row (fingers and automation alike) hit nothing.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Applies the assignee picker's result — including "Clear assignee".
    ///
    /// This used to be an `onChange(of: reassignPick?.id)` guarded by `if let`, which cannot tell
    /// "picker dismissed without choosing" from "user chose to unassign", so Clear silently did
    /// nothing. It could not have worked anyway: `POST /assign` requires a delegatee, and `update`
    /// had no assignee_id — nothing in the system could take an assignee back off.
    /// Hand this item to the assistant with the context already written.
    ///
    /// Seeds the composer rather than sending: the user sees the question, can reword it, and
    /// chooses to spend the turn. An action that silently fired a paid request from a menu tap
    /// would be a bad trade for one saved tap.
    private func askAssistant() {
        nav?.assistantSeed = Self.assistantPrompt(for: subject)
        nav?.detail = nil
        nav?.startNewChat = true
        nav?.show(.assistant)
    }

    /// The opening question, phrased so the assistant knows which record is meant. The id is
    /// included because titles are not unique — "Call Dana" may exist three times.
    static func assistantPrompt(for subject: DetailSubject) -> String {
        switch subject {
        case .assignment(let a):
            return "About my assignment “\(a.title)” (id \(a.id)): "
        case .goal(let g):
            return "About my goal “\(g.title)” (id \(g.id)): "
        case .log(let l):
            return "About this log entry “\(l.title)” (id \(l.id)): "
        }
    }

    private func applyAssigneePick(for a: Assignment) {
        guard reassignPick?.id != currentAssigneeId else { return }   // dismissed without changing
        currentAssigneeId = reassignPick?.id
        assigneeName = reassignPick?.name
        let picked = reassignPick
        Task {
            if let picked {
                _ = try? await app.client.assign(assignmentId: a.id, assigneeSlug: picked.slug)
            } else {
                _ = try? await app.client.unassign(assignmentId: a.id)
            }
            await app.tasks.load(client: app.client)
        }
    }

    // MARK: Reminder offset

    /// Interactive Reminder row (assignments only): how far ahead of the occurrence the assignee is
    /// nudged, plus *when that actually lands*.
    ///
    /// The reminder engine was never the problem — it fires correctly across DST and volume. The gap
    /// was that advance notice could only be set via the *delegatee's* notice window, which applies
    /// to everything you give that person, and the detail then showed a bare "Lead time 0" that
    /// explained nothing (a self-assigned item reads 0 and looks broken). This makes the offset a
    /// per-assignment control and states the resulting reminder time in words.
    @ViewBuilder private var reminderControl: some View {
        if case .assignment(let a) = subject {
            let override = leadEdited ? leadValue : a.leadTimeMinutes
            let inherited = inheritedLead(a)
            let effective = override ?? inherited ?? 0
            VStack(alignment: .leading, spacing: 8) {
                Text("Reminder").font(Typeface.body(13)).foregroundStyle(Palette.inkSecondary)
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    // Only offer "inherit" when there's something to inherit.
                    if let inherited, let name = assigneeName {
                        leadChip(label: "\(name)'s default", selected: override == nil, minutes: nil,
                                 hint: LeadTime.label(inherited), assignment: a)
                    }
                    ForEach(LeadTime.presets, id: \.minutes) { preset in
                        leadChip(label: preset.label, selected: override == preset.minutes,
                                 minutes: preset.minutes, hint: nil, assignment: a)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: override)
                Text(reminderExplanation(a, effective: effective, isInherited: override == nil && inherited != nil))
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityLabel("Reminder timing. \(reminderExplanation(a, effective: effective, isInherited: override == nil && inherited != nil))")
            }
        }
    }

    private func leadChip(label: String, selected: Bool, minutes: Int?, hint: String?,
                          assignment a: Assignment) -> some View {
        Button {
            leadEdited = true
            leadValue = minutes
            Task {
                _ = try? await app.client.setAssignmentLeadTime(id: a.id, minutes: minutes)
                await app.tasks.load(client: app.client)
            }
        } label: {
            Text(hint.map { "\(label) · \($0)" } ?? label)
                .font(Typeface.body(15, selected ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Palette.accent.opacity(0.18) : Palette.ink.opacity(0.06))
                .foregroundStyle(selected ? Palette.accent : Palette.ink)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remind \(label)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func inheritedLead(_ a: Assignment) -> Int? {
        a.assigneeId.flatMap { id in app.people.delegatees.first { $0.id == id }?.leadTimeMinutes }
    }

    private func reminderExplanation(_ a: Assignment, effective: Int, isInherited: Bool) -> String {
        PlannerFormat.reminderSummary(
            scheduleKind: a.scheduleKind, scheduledStart: a.scheduledStart, status: a.status,
            effectiveLead: effective,
            sourceName: isInherited ? (assigneeName ?? "the assignee") : nil)
    }

    // MARK: The work advancing a goal

    /// A goal's assignments (goals only). The other half of the link: a goal that can't show the
    /// work moving it forward is just a title — testers ended up encoding progress into the title
    /// itself. Hidden (redacted) assignments are excluded; they must not leak here.
    @ViewBuilder private var advancingWorkSection: some View {
        if case .goal(let g) = subject {
            let work = app.tasks.assignments
                .filter { $0.goalId == g.id && !($0.hidden ?? false) }
                .sorted { lhs, rhs in
                    // Live work first, then by soonest scheduled, then newest.
                    let lDone = lhs.status == "done" || lhs.status == "cancelled"
                    let rDone = rhs.status == "done" || rhs.status == "cancelled"
                    if lDone != rDone { return !lDone }
                    switch (lhs.scheduledStart, rhs.scheduledStart) {
                    case let (l?, r?): return l < r
                    case (nil, _?): return false
                    case (_?, nil): return true
                    default: return lhs.id > rhs.id
                    }
                }
            Section {
                if work.isEmpty {
                    Text("No assignments yet. Create one and link it to this goal, and it'll show up here.")
                        .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                } else {
                    ForEach(work) { a in
                        NavigationLink {
                            EntityDetailView(subject: .assignment(a), inDetailColumn: inDetailColumn)
                        } label: {
                            HStack(spacing: 10) {
                                Circle().fill(PlannerFormat.statusColor(a.status)).frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.title)
                                        .font(Typeface.body(16))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(1)
                                    Text(PlannerFormat.scheduleSummary(a))
                                        .font(Typeface.body(12))
                                        .foregroundStyle(Palette.inkSecondary)
                                }
                                Spacer(minLength: 0)
                                Text(PlannerFormat.statusLabel(a.status))
                                    .font(Typeface.body(12))
                                    .foregroundStyle(PlannerFormat.statusColor(a.status))
                            }
                        }
                        .accessibilityLabel("\(a.title), \(PlannerFormat.statusLabel(a.status))")
                    }
                }
            } header: {
                HStack {
                    Text("Advanced by")
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !work.isEmpty {
                        let done = work.filter { $0.status == "done" }.count
                        Text("\(done) of \(work.count) done")
                            .font(Typeface.body(12))
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
            .listRowBackground(Palette.surface)
        }
    }

    /// Interactive Goal row (assignments only) — link this work to the goal it advances, or unlink
    /// it. This was a read-only row that could only ever *display* a link the app had no way to
    /// create: `assignments.goal_id` has existed since the first migration, but nothing on device
    /// could set it, so goals stayed decorative and every on-device assignment was goal_id: null.
    ///
    /// Uses `onDismiss` rather than `onChange(of: pick?.id)` so that *clearing* registers: an
    /// onChange guarded by `if let` can't tell "user chose nothing" from "user chose to unlink".
    @ViewBuilder private var goalControl: some View {
        if case .assignment(let a) = subject {
            Button {
                goalPick = app.tasks.goals.first { $0.id == (linkedGoalId ?? a.goalId) }
                showGoalPicker = true
            } label: {
                HStack {
                    Text("Goal").foregroundStyle(Palette.ink)
                    Spacer()
                    Text(linkedGoalTitle(a) ?? "Not linked")
                        .foregroundStyle(linkedGoalTitle(a) == nil ? Palette.inkSecondary : Palette.accent)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                        .accessibilityHidden(true)
                }
                // Same dead-zone fix as the Assignee row: make the Spacer region hittable.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Goal, \(linkedGoalTitle(a) ?? "not linked")")
        }
    }

    /// The currently-linked goal's title, preferring the optimistic local edit over the subject
    /// value this view was handed (the subject is a snapshot and doesn't refresh in place).
    private func linkedGoalTitle(_ a: Assignment) -> String? {
        if let edited = linkedGoalId { return app.tasks.goals.first { $0.id == edited }?.title }
        if goalWasCleared { return nil }
        return a.goalId.flatMap { id in app.tasks.goals.first { $0.id == id }?.title }
    }

    private func applyGoalPick(for a: Assignment) {
        let currentId = linkedGoalId ?? (goalWasCleared ? nil : a.goalId)
        let pickedId = goalPick?.id
        guard pickedId != currentId else { return }
        linkedGoalId = pickedId
        goalWasCleared = (pickedId == nil)
        Task {
            _ = try? await app.client.setAssignmentGoal(id: a.id, goalId: pickedId)
            await app.tasks.load(client: app.client)
        }
    }

    /// Runs `body` with the subject when it's an assignment — the root-level sheet callbacks don't
    /// have the `if case` binding the controls do.
    private func withAssignment(_ body: (Assignment) -> Void) {
        if case .assignment(let a) = subject { body(a) }
    }

    private struct Row { let label: String; let value: String }

    private var contextRows: [Row] {
        switch subject {
        case .assignment(let a):
            // Status is rendered by the interactive `statusControl`, not as a read-only row.
            var rows = [Row(label: "Schedule", value: a.scheduleKind == "routine" ? "Routine" : "One-off")]
            if let start = a.scheduledStart, let d = PlannerFormat.parse(start) {
                rows.append(Row(label: "Due", value: Self.dateTime.string(from: d)))
            }
            // Lead time is rendered by the interactive `reminderControl`, which also says when the
            // reminder actually fires — a bare "Lead time 0" row explained nothing.
            // Assignee is rendered by `assigneeControl`, and Goal by `goalControl` — not read-only rows.
            if let origin = a.origin, origin != "manual" { rows.append(Row(label: "Created by", value: origin)) }
            rows.append(Row(label: "Created", value: created(a.createdAt)))
            return rows
        case .goal(let g):
            // Status is rendered by the interactive `statusControl`, not as a read-only row.
            var rows: [Row] = []
            if let t = g.targetDate, !t.isEmpty {
                rows.append(Row(label: "Target", value: PlannerFormat.dayLabel(t)))
            }
            rows.append(Row(label: "Created", value: created(g.createdAt)))
            return rows
        case .log(let l):
            var rows = [Row(label: "Logged", value: created(l.occurredAt))]
            rows.append(Row(label: "By", value: l.actorName ?? "Me"))
            if let cat = l.category, !cat.isEmpty { rows.append(Row(label: "Category", value: cat)) }
            if let m = l.durationMinutes { rows.append(Row(label: "Minutes", value: "\(m)")) }
            if l.isCompletion { rows.append(Row(label: "Source", value: "Completed a task")) }
            return rows
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if store.notes.isEmpty {
                    Text("Notes, context, anything to keep track of…")
                        .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                        .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { store.notes },
                    set: { store.notes = $0; store.notesChanged(client: app.client) }))
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .font(Typeface.body(16))
                    .focused($editing, equals: .notes)
            }
        } header: {
            HStack {
                Text("Notes")
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if store.savingNotes {
                    Text("Saving…").font(.caption).foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: Checklist

    private var checklistSection: some View {
        Section {
            if store.items.isEmpty {
                Text("No checklist items yet.")
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.inkSecondary)
            }
            ForEach(store.items) { item in
                ChecklistRow(item: item) {
                    Haptics.light()
                    Task { await store.toggle(item, client: app.client) }
                }
            }
            .onDelete { offsets in Task { await store.delete(at: offsets, client: app.client) } }
            .onMove { src, dst in Task { await store.move(from: src, to: dst, client: app.client) } }

            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                TextField("Add an item…", text: $newItem)
                    .focused($newItemFocused)
                    .onSubmit(addItem)
                    .accessibilityLabel("Add checklist item")
            }
        } header: {
            Text("Checklist")
                .accessibilityAddTraits(.isHeader)
        }
        .listRowBackground(Palette.surface)
    }

    private func addItem() {
        let t = newItem
        newItem = ""
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await store.add(t, client: app.client); newItemFocused = true }
    }

    // MARK: Hiding

    /// The hideable entity's id (assignments + logs); nil for goals, which have no hidden state.
    /// Detail pages only ever open for non-hidden items, so hide is the only action here —
    /// revealing a hidden item happens from its list/editor, gated by the passcode.
    private var hideableId: Int? {
        switch subject {
        case .assignment(let a): return a.id
        case .log(let l):        return l.id
        case .goal:              return nil
        }
    }

    /// Hide the entity and close — its plaintext no longer belongs on an open page. Closing must
    /// clear the detail-column selection on iPad/Mac (where `dismiss()` is inert); otherwise the
    /// now-hidden item would keep showing its plaintext in the column — a leak.
    private func hide() {
        switch subject {
        case .assignment(let a):
            Task { await app.tasks.setHidden(id: a.id, hidden: true, client: app.client); close() }
        case .log(let l):
            Task { await app.log.setHidden(id: l.id, hidden: true, client: app.client); close() }
        case .goal:
            break
        }
    }

    /// Dismiss the sheet (iPhone) or clear the detail-column selection (iPad/Mac).
    private func close() {
        if inDetailColumn { nav?.detail = nil } else { dismiss() }
    }

    // MARK: Format helpers

    private func created(_ iso: String) -> String {
        PlannerFormat.parse(iso).map { Self.dateTime.string(from: $0) } ?? iso
    }
    private static let dateTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy · h:mm a"; return f }()
}

private struct ChecklistRow: View {
    let item: TaskItem
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Palette.sage : Palette.inkSecondary.opacity(0.6))
                    .accessibilityHidden(true)
                Text(item.text)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Palette.inkSecondary : Palette.ink)
                Spacer(minLength: 0)
                if item.source == "ai" {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.text), \(item.done ? "completed" : "not completed")")
        .animation(.easeInOut(duration: 0.15), value: item.done)
    }
}
